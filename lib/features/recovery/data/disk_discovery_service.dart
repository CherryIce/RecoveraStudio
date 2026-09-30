import 'dart:convert';
import 'dart:io';

import '../domain/storage_device.dart';
import 'apple_property_list.dart';

abstract interface class DiskDiscoveryService {
  Future<List<StorageDevice>> discover();
}

class PlatformDiskDiscoveryService implements DiskDiscoveryService {
  const PlatformDiskDiscoveryService();

  @override
  Future<List<StorageDevice>> discover() {
    if (Platform.isMacOS) {
      return _discoverMacOS();
    }
    if (Platform.isWindows) {
      return _discoverWindows();
    }
    throw UnsupportedError('当前平台暂不支持物理磁盘枚举');
  }

  Future<List<StorageDevice>> _discoverMacOS() async {
    final startupDiskIds = await _discoverMacOSStartupDiskIds();
    final listResult = await Process.run('/usr/sbin/diskutil', const <String>[
      'list',
      '-plist',
      'physical',
    ]);
    if (listResult.exitCode != 0) {
      throw ProcessException(
        '/usr/sbin/diskutil',
        const <String>['list', '-plist', 'physical'],
        listResult.stderr.toString(),
        listResult.exitCode,
      );
    }

    final root = ApplePropertyList.parseDictionary(
      listResult.stdout.toString(),
    );
    final disks = root['AllDisksAndPartitions'];
    if (disks is! List<Object?>) {
      return const <StorageDevice>[];
    }

    final devices = await Future.wait(
      disks.whereType<Map<String, Object?>>().map((disk) async {
        final identifier = disk['DeviceIdentifier']?.toString();
        if (identifier == null || identifier.isEmpty) {
          return null;
        }
        final infoResult = await Process.run('/usr/sbin/diskutil', <String>[
          'info',
          '-plist',
          identifier,
        ]);
        if (infoResult.exitCode != 0) {
          return null;
        }
        final info = ApplePropertyList.parseDictionary(
          infoResult.stdout.toString(),
        );
        final rawPath = '/dev/r$identifier';
        return StorageDevice(
          id: identifier,
          displayName: _firstNonEmpty(<Object?>[
            info['MediaName'],
            info['IORegistryEntryName'],
            info['VolumeName'],
            identifier,
          ]),
          devicePath: rawPath,
          size: _asInt(info['TotalSize'] ?? info['Size'] ?? disk['Size']),
          isInternal: info['Internal'] == true,
          isSolidState: info['SolidState'] == true,
          busProtocol: _firstNonEmpty(<Object?>[info['BusProtocol'], '未知接口']),
          canReadDirectly: await _canOpen(rawPath),
          isSystemDisk: startupDiskIds.contains(identifier),
          blockSize: _normalizedBlockSize(info['DeviceBlockSize']),
        );
      }),
    );

    return devices.whereType<StorageDevice>().toList(growable: false)
      ..sort((left, right) {
        if (left.isInternal != right.isInternal) {
          return left.isInternal ? 1 : -1;
        }
        return left.id.compareTo(right.id);
      });
  }

  Future<Set<String>> _discoverMacOSStartupDiskIds() async {
    final result = await Process.run('/usr/sbin/diskutil', const <String>[
      'info',
      '-plist',
      '/',
    ]);
    if (result.exitCode != 0) {
      return const <String>{};
    }
    try {
      return MacOSDiskIdentity.startupPhysicalDiskIdentifiers(
        ApplePropertyList.parseDictionary(result.stdout.toString()),
      );
    } on FormatException {
      return const <String>{};
    }
  }

  Future<List<StorageDevice>> _discoverWindows() async {
    const command = r'''
$ErrorActionPreference = 'Stop'
Get-CimInstance Win32_DiskDrive |
  Select-Object Index,Model,Size,InterfaceType,MediaType |
  ConvertTo-Json -Compress
''';
    final result = await Process.run('powershell.exe', const <String>[
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      command,
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'powershell.exe',
        const <String>['-NoProfile', '-NonInteractive', '-Command', command],
        result.stderr.toString(),
        result.exitCode,
      );
    }

    final decoded = jsonDecode(result.stdout.toString());
    final records = decoded is List<Object?> ? decoded : <Object?>[decoded];
    final devices = <StorageDevice>[];
    for (final record in records.whereType<Map<String, Object?>>()) {
      final index = _asInt(record['Index']);
      final rawPath =
          r'\\.\PhysicalDrive'
          '$index';
      final mediaType = record['MediaType']?.toString() ?? '';
      devices.add(
        StorageDevice(
          id: 'PhysicalDrive$index',
          displayName: _firstNonEmpty(<Object?>[record['Model'], '磁盘 $index']),
          devicePath: rawPath,
          size: _asInt(record['Size']),
          isInternal:
              !(record['InterfaceType']?.toString().toUpperCase().contains(
                    'USB',
                  ) ??
                  false),
          isSolidState: mediaType.toUpperCase().contains('SSD'),
          busProtocol: _firstNonEmpty(<Object?>[
            record['InterfaceType'],
            '未知接口',
          ]),
          canReadDirectly: await _canOpen(rawPath),
          blockSize: 512,
        ),
      );
    }
    return devices;
  }

  static Future<bool> _canOpen(String path) async {
    RandomAccessFile? handle;
    try {
      handle = await File(path).open(mode: FileMode.read);
      return true;
    } on FileSystemException {
      return false;
    } finally {
      await handle?.close();
    }
  }

  static String _firstNonEmpty(List<Object?> candidates) {
    for (final value in candidates) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        return text;
      }
    }
    return '';
  }

  static int _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static int _normalizedBlockSize(Object? value) {
    final parsed = _asInt(value);
    return parsed > 0 ? parsed : 512;
  }
}

class MacOSDiskIdentity {
  const MacOSDiskIdentity._();

  static Set<String> startupPhysicalDiskIdentifiers(
    Map<String, Object?> rootVolumeInfo,
  ) {
    final identifiers = <String>{};
    final physicalStores = rootVolumeInfo['APFSPhysicalStores'];
    if (physicalStores is List<Object?>) {
      for (final store in physicalStores.whereType<Map<String, Object?>>()) {
        _addWholeDisk(store['APFSPhysicalStore'], identifiers);
      }
    }
    _addWholeDisk(rootVolumeInfo['ParentWholeDisk'], identifiers);
    return identifiers;
  }

  static void _addWholeDisk(Object? value, Set<String> identifiers) {
    final match = RegExp(r'^(disk\d+)').firstMatch(value?.toString() ?? '');
    final identifier = match?.group(1);
    if (identifier != null) {
      identifiers.add(identifier);
    }
  }
}
