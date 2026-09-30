import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recovera_studio/features/recovery/data/background_file_scanner.dart';
import 'package:recovera_studio/features/recovery/domain/recovery_candidate.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'recovera-background-test-',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('scans and reports progress from the background isolate', () async {
    final jpeg = <int>[0xFF, 0xD8, 0xFF, 1, 2, 3, 0xFF, 0xD9];
    final sourceBytes = <int>[0, 0, ...jpeg, 0, 0];
    final source = File('${temporaryDirectory.path}/background.img');
    await source.writeAsBytes(sourceBytes, flush: true);
    final scanner = BackgroundFileScanner(chunkSize: 4);
    final progressUpdates = <ScanProgress>[];
    addTearDown(scanner.dispose);

    final summary = await scanner.scan(
      source.path,
      totalBytes: sourceBytes.length,
      onProgress: progressUpdates.add,
    );

    expect(summary.candidates, hasLength(1));
    expect(summary.candidates.single.kind, RecoveryFileKind.jpeg);
    expect(summary.bytesScanned, sourceBytes.length);
    expect(progressUpdates, isNotEmpty);
    expect(progressUpdates.last.bytesScanned, sourceBytes.length);
    expect(scanner.isRunning, isFalse);
  });

  test('cancels a background scan through its command port', () async {
    final source = File('${temporaryDirectory.path}/cancel.img');
    final handle = await source.open(mode: FileMode.write);
    await handle.truncate(64 * 1024 * 1024);
    await handle.close();
    final scanner = BackgroundFileScanner(chunkSize: 64 * 1024);
    addTearDown(scanner.dispose);

    final scan = scanner.scan(source.path, totalBytes: await source.length());
    scanner.cancel();

    await expectLater(scan, throwsA(isA<ScanCancelledException>()));
    expect(scanner.isRunning, isFalse);
  });

  test(
    'reads an authorized native descriptor in the background isolate',
    () async {
      if (!Platform.isMacOS) {
        return;
      }

      final jpeg = <int>[0xFF, 0xD8, 0xFF, 5, 6, 7, 0xFF, 0xD9];
      final sourceBytes = <int>[1, 2, ...jpeg, 8, 9];
      final source = File('${temporaryDirectory.path}/native-background.img');
      await source.writeAsBytes(sourceBytes, flush: true);
      final path = source.path.toNativeUtf8();
      final libc = DynamicLibrary.process();
      final open = libc.lookupFunction<_OpenNative, _OpenDart>('open');
      final close = libc.lookupFunction<_CloseNative, _CloseDart>('close');
      final descriptor = open(path, 0);
      malloc.free(path);
      expect(descriptor, greaterThanOrEqualTo(0));
      addTearDown(() => close(descriptor));
      final scanner = BackgroundFileScanner(chunkSize: 5);
      addTearDown(scanner.dispose);

      final summary = await scanner.scan(
        'authorized-raw-disk',
        totalBytes: sourceBytes.length,
        nativeHandle: descriptor,
        nativeBlockSize: 8,
      );

      expect(summary.candidates, hasLength(1));
      expect(summary.candidates.single.length, jpeg.length);
    },
  );
}

typedef _OpenNative = Int32 Function(Pointer<Utf8> path, Int32 flags);
typedef _OpenDart = int Function(Pointer<Utf8> path, int flags);
typedef _CloseNative = Int32 Function(Int32 descriptor);
typedef _CloseDart = int Function(int descriptor);
