import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

abstract interface class RecoveryRandomAccessReader {
  Future<Uint8List> readAt(int offset, int length);

  Future<void> close();
}

class FileRecoveryRandomAccessReader implements RecoveryRandomAccessReader {
  FileRecoveryRandomAccessReader._(this._file);

  final RandomAccessFile _file;

  static Future<FileRecoveryRandomAccessReader> open(String path) async {
    final file = await File(path).open(mode: FileMode.read);
    return FileRecoveryRandomAccessReader._(file);
  }

  @override
  Future<Uint8List> readAt(int offset, int length) async {
    await _file.setPosition(offset);
    return Uint8List.fromList(await _file.read(length));
  }

  @override
  Future<void> close() => _file.close();
}

class NativeFileDescriptorReader implements RecoveryRandomAccessReader {
  NativeFileDescriptorReader(this.fileDescriptor, {required this.blockSize})
    : assert(fileDescriptor >= 0),
      assert(blockSize > 0);

  final int fileDescriptor;
  final int blockSize;

  static final DynamicLibrary _libc = DynamicLibrary.process();
  static final _PreadDart _pread = _libc
      .lookupFunction<_PreadNative, _PreadDart>('pread');
  static final _ErrnoDart _errno = _libc
      .lookupFunction<_ErrnoNative, _ErrnoDart>('__error');
  static final _StrerrorDart _strerror = _libc
      .lookupFunction<_StrerrorNative, _StrerrorDart>('strerror');

  @override
  Future<Uint8List> readAt(int offset, int length) async {
    if (offset < 0 || length < 0) {
      throw RangeError('offset and length must be non-negative');
    }
    if (length == 0) {
      return Uint8List(0);
    }

    final alignedStart = offset - (offset % blockSize);
    final prefixLength = offset - alignedStart;
    final requestedEnd = prefixLength + length;
    final alignedLength =
        ((requestedEnd + blockSize - 1) ~/ blockSize) * blockSize;
    final buffer = malloc.allocate<Uint8>(alignedLength, alignment: blockSize);

    try {
      final bytesRead = _pread(
        fileDescriptor,
        buffer.cast<Void>(),
        alignedLength,
        alignedStart,
      );
      if (bytesRead < 0) {
        final code = _errno().value;
        final message = _strerror(code).toDartString();
        throw FileSystemException(
          '原始磁盘读取失败',
          'fd:$fileDescriptor @ $offset',
          OSError(message, code),
        );
      }
      if (bytesRead <= prefixLength) {
        return Uint8List(0);
      }
      final available = math.min(length, bytesRead - prefixLength);
      return Uint8List.fromList(
        buffer
            .asTypedList(bytesRead)
            .sublist(prefixLength, prefixLength + available),
      );
    } finally {
      malloc.free(buffer);
    }
  }

  @override
  Future<void> close() async {
    // The native bridge owns and closes the authorized descriptor.
  }
}

typedef _PreadNative =
    IntPtr Function(
      Int32 fileDescriptor,
      Pointer<Void> buffer,
      UintPtr length,
      Int64 offset,
    );
typedef _PreadDart =
    int Function(
      int fileDescriptor,
      Pointer<Void> buffer,
      int length,
      int offset,
    );
typedef _ErrnoNative = Pointer<Int32> Function();
typedef _ErrnoDart = Pointer<Int32> Function();
typedef _StrerrorNative = Pointer<Utf8> Function(Int32 code);
typedef _StrerrorDart = Pointer<Utf8> Function(int code);
