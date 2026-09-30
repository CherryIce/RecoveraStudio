import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/background_file_scanner.dart';
import '../data/disk_discovery_service.dart';
import '../data/file_carver.dart';
import '../data/raw_disk_access_service.dart';
import '../domain/recovery_candidate.dart';
import '../domain/storage_device.dart';

enum RecoveryPhase { idle, ready, scanning, completed, cancelled, failed }

class RecoveryController extends ChangeNotifier {
  RecoveryController({
    FileCarver? carver,
    BackgroundFileScanner? scanner,
    DiskDiscoveryService? diskDiscovery,
    RawDiskAccessService? rawDiskAccess,
  }) : _carver = carver ?? FileCarver(),
       _scanner =
           scanner ??
           BackgroundFileScanner(
             chunkSize: carver?.chunkSize ?? 4 * 1024 * 1024,
           ),
       _diskDiscovery = diskDiscovery ?? const PlatformDiskDiscoveryService(),
       _rawDiskAccess = rawDiskAccess ?? const RawDiskAccessService();

  final FileCarver _carver;
  final BackgroundFileScanner _scanner;
  final DiskDiscoveryService _diskDiscovery;
  final RawDiskAccessService _rawDiskAccess;
  AuthorizedRawDisk? _authorizedDisk;
  bool _disposed = false;

  String? sourcePath;
  String? sourceLabel;
  RecoverySourceKind? sourceKind;
  int sourceSize = 0;
  RecoveryPhase phase = RecoveryPhase.idle;
  ScanProgress? progress;
  ScanSummary? summary;
  String? errorMessage;
  List<StorageDevice> devices = const <StorageDevice>[];
  StorageDevice? selectedDevice;
  bool isLoadingDevices = false;
  bool isAuthorizing = false;
  String? deviceError;
  final Map<String, String> recoveredPaths = <String, String>{};

  bool get isScanning => phase == RecoveryPhase.scanning;
  bool get hasSource => sourcePath != null;
  bool get isSystemDiskSelected =>
      sourceKind == RecoverySourceKind.physicalDisk &&
      selectedDevice?.isSystemDisk == true;
  bool get needsAuthorization =>
      sourceKind == RecoverySourceKind.physicalDisk &&
      selectedDevice != null &&
      sourcePath == null;

  Future<void> initialize() => refreshDevices();

  Future<void> refreshDevices() async {
    if (isLoadingDevices || isScanning) {
      return;
    }
    isLoadingDevices = true;
    deviceError = null;
    _notifyIfActive();
    try {
      final discovered = await _diskDiscovery.discover();
      devices = discovered;
      final previousId = selectedDevice?.id;
      final nextSelection =
          discovered.where((item) => item.id == previousId).firstOrNull ??
          discovered.firstOrNull;
      if (nextSelection != null) {
        await selectDevice(nextSelection);
      } else {
        await _clearAuthorizedDisk();
        selectedDevice = null;
        sourcePath = null;
        sourceLabel = null;
        sourceKind = null;
        sourceSize = 0;
        phase = RecoveryPhase.idle;
      }
    } catch (error) {
      devices = const <StorageDevice>[];
      deviceError = '无法检测磁盘：${_friendlyError(error)}';
    } finally {
      isLoadingDevices = false;
      _notifyIfActive();
    }
  }

  Future<void> selectDevice(StorageDevice device) async {
    if (isScanning) {
      return;
    }
    await _clearAuthorizedDisk();
    selectedDevice = device;
    sourceKind = RecoverySourceKind.physicalDisk;
    sourceLabel = device.displayName;
    sourceSize = device.size;
    sourcePath = device.canReadDirectly ? device.devicePath : null;
    phase = sourcePath == null ? RecoveryPhase.idle : RecoveryPhase.ready;
    _clearScanState();
    _notifyIfActive();
  }

  Future<void> authorizeSelectedDevice() async {
    final device = selectedDevice;
    if (device == null || isAuthorizing || isScanning) {
      return;
    }
    isAuthorizing = true;
    errorMessage = null;
    _notifyIfActive();
    try {
      await _clearAuthorizedDisk();
      _authorizedDisk = await _rawDiskAccess.authorize(device);
      sourcePath = _authorizedDisk!.path;
      sourceKind = RecoverySourceKind.physicalDisk;
      sourceLabel = device.displayName;
      sourceSize = device.size;
      phase = RecoveryPhase.ready;
      _clearScanState();
    } catch (error) {
      sourcePath = null;
      phase = RecoveryPhase.failed;
      errorMessage = _friendlyError(error);
    } finally {
      isAuthorizing = false;
      _notifyIfActive();
    }
  }

  Future<void> selectImage(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('找不到所选文件', path);
    }
    await _clearAuthorizedDisk();
    selectedDevice = null;
    sourcePath = path;
    sourceLabel = file.uri.pathSegments.last;
    sourceKind = RecoverySourceKind.diskImage;
    sourceSize = await file.length();
    phase = RecoveryPhase.ready;
    _clearScanState();
    _notifyIfActive();
  }

  Future<void> startScan() async {
    final path = sourcePath;
    if (path == null || isScanning) {
      return;
    }

    phase = RecoveryPhase.scanning;
    progress = ScanProgress(
      bytesScanned: 0,
      totalBytes: sourceSize,
      foundCount: 0,
      elapsed: Duration.zero,
    );
    summary = null;
    errorMessage = null;
    recoveredPaths.clear();
    _notifyIfActive();

    try {
      summary = await _scanner.scan(
        path,
        totalBytes: sourceSize,
        nativeHandle: _authorizedDisk?.nativeHandle,
        nativeBlockSize: selectedDevice?.blockSize ?? 512,
        onProgress: (value) {
          progress = value;
          _notifyIfActive();
        },
      );
      phase = RecoveryPhase.completed;
    } on ScanCancelledException {
      phase = RecoveryPhase.cancelled;
    } catch (error) {
      errorMessage = _friendlyError(error);
      phase = RecoveryPhase.failed;
    } finally {
      _notifyIfActive();
    }
  }

  void cancelScan() => _scanner.cancel();

  Future<void> openFullDiskAccessSettings() async {
    try {
      await _rawDiskAccess.openFullDiskAccessSettings();
    } catch (error) {
      errorMessage = '无法打开完全磁盘访问设置：${_friendlyError(error)}';
      _notifyIfActive();
    }
  }

  Future<String> recoverCandidate(
    RecoveryCandidate candidate,
    String destinationDirectory,
  ) async {
    final path = await _carver.recover(
      candidate,
      destinationDirectory,
      nativeHandle: _authorizedDisk?.nativeHandle,
      nativeBlockSize: selectedDevice?.blockSize ?? 512,
    );
    recoveredPaths[candidate.id] = path;
    _notifyIfActive();
    return path;
  }

  Future<List<String>> recoverAll(String destinationDirectory) async {
    final candidates = summary?.candidates ?? const <RecoveryCandidate>[];
    final outputs = <String>[];
    for (final candidate in candidates) {
      outputs.add(await recoverCandidate(candidate, destinationDirectory));
    }
    return outputs;
  }

  Future<Uint8List> preview(RecoveryCandidate candidate) => _carver.readPreview(
    candidate,
    nativeHandle: _authorizedDisk?.nativeHandle,
    nativeBlockSize: selectedDevice?.blockSize ?? 512,
  );

  void _clearScanState() {
    progress = null;
    summary = null;
    errorMessage = null;
    recoveredPaths.clear();
  }

  Future<void> _clearAuthorizedDisk() async {
    final previous = _authorizedDisk;
    _authorizedDisk = null;
    await _rawDiskAccess.close(previous);
  }

  void _notifyIfActive() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _scanner.dispose();
    unawaited(_rawDiskAccess.close(_authorizedDisk));
    super.dispose();
  }

  String _friendlyError(Object error) {
    if (error is PlatformException) {
      final message = error.message ?? error.code;
      final normalized = message.toLowerCase();
      if (normalized.contains('operation not permitted')) {
        return 'macOS 拒绝了原始磁盘访问。请确认选择的是外接磁盘；'
            '如果仍被拒绝，请在“系统设置 → 隐私与安全性 → 完全磁盘访问”'
            '允许本应用后重新启动。';
      }
      if (normalized.contains('resource busy')) {
        return '磁盘正在被 macOS 使用。请先在“磁盘工具”中卸载该外接磁盘的卷'
            '（不要拔出设备），然后重新检测。';
      }
      return message;
    }
    if (error is FileSystemException) {
      final osError = error.osError;
      final path = error.path;
      return <String>[
        error.message,
        if (osError != null) '${osError.message} (${osError.errorCode})',
        if (path != null) path,
      ].join('：');
    }
    if (error is UnsupportedError) {
      return error.message ?? error.toString();
    }
    return error.toString();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
