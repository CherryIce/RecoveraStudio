import 'dart:io';

import 'package:flutter/services.dart';

import '../domain/storage_device.dart';

class RawDiskAccessService {
  const RawDiskAccessService();

  static const MethodChannel _channel = MethodChannel('recovera/raw_disk');

  Future<AuthorizedRawDisk> authorize(StorageDevice device) async {
    if (device.canReadDirectly) {
      return AuthorizedRawDisk(path: device.devicePath);
    }
    if (!Platform.isMacOS) {
      throw const FileSystemException('请使用管理员身份运行桌面程序后重新检测磁盘');
    }

    final handle = await _channel.invokeMethod<int>(
      'authorizeRawDisk',
      <String, Object?>{'path': device.devicePath},
    );
    if (handle == null || handle < 0) {
      throw const FileSystemException('没有获得磁盘只读权限');
    }
    return AuthorizedRawDisk(path: '/dev/fd/$handle', nativeHandle: handle);
  }

  Future<void> openFullDiskAccessSettings() async {
    if (!Platform.isMacOS) {
      return;
    }
    await _channel.invokeMethod<void>('openFullDiskAccessSettings');
  }

  Future<void> close(AuthorizedRawDisk? disk) async {
    final handle = disk?.nativeHandle;
    if (handle == null || !Platform.isMacOS) {
      return;
    }
    await _channel.invokeMethod<void>('closeRawDisk', <String, Object?>{
      'handle': handle,
    });
  }
}
