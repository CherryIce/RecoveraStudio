enum RecoverySourceKind { physicalDisk, diskImage }

class StorageDevice {
  const StorageDevice({
    required this.id,
    required this.displayName,
    required this.devicePath,
    required this.size,
    required this.isInternal,
    required this.isSolidState,
    required this.busProtocol,
    required this.canReadDirectly,
    this.isSystemDisk = false,
    this.blockSize = 512,
  });

  final String id;
  final String displayName;
  final String devicePath;
  final int size;
  final bool isInternal;
  final bool isSolidState;
  final String busProtocol;
  final bool canReadDirectly;
  final bool isSystemDisk;
  final int blockSize;

  bool get requiresAuthorization => !canReadDirectly;

  String get locationLabel => isInternal ? '内部磁盘' : '外接设备';

  String get mediaLabel => isSolidState ? 'SSD / 闪存' : '磁盘设备';
}

class AuthorizedRawDisk {
  const AuthorizedRawDisk({required this.path, this.nativeHandle});

  final String path;
  final int? nativeHandle;
}
