import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recovera_studio/features/recovery/data/file_carver.dart';
import 'package:recovera_studio/features/recovery/domain/recovery_candidate.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'recovera-test-',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'finds supported files even when signatures cross chunk boundaries',
    () async {
      final jpeg = <int>[0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 0xFF, 0xD9];
      final png = <int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0,
        0,
        0,
        0,
        0x49,
        0x45,
        0x4E,
        0x44,
        0xAE,
        0x42,
        0x60,
        0x82,
      ];
      final pdf = '%PDF-1.7\nexample\n%%EOF'.codeUnits;
      final docxLikeZip = <int>[
        0x50,
        0x4B,
        0x03,
        0x04,
        ...'word/document.xml'.codeUnits,
        0x50,
        0x4B,
        0x03,
        0x04,
        ...'word/styles.xml'.codeUnits,
        0x50,
        0x4B,
        0x05,
        0x06,
        ...List<int>.filled(18, 0),
      ];
      final sourceBytes = <int>[
        ...List<int>.filled(6, 0x11),
        ...jpeg,
        ...List<int>.filled(5, 0x22),
        ...png,
        ...List<int>.filled(9, 0x33),
        ...pdf,
        ...List<int>.filled(3, 0x44),
        ...docxLikeZip,
      ];
      final source = File('${temporaryDirectory.path}/sample.img');
      await source.writeAsBytes(sourceBytes, flush: true);

      final summary = await FileCarver(chunkSize: 7).scan(source.path);

      expect(summary.bytesScanned, sourceBytes.length);
      expect(
        summary.candidates.map((candidate) => candidate.kind),
        containsAll(<RecoveryFileKind>[
          RecoveryFileKind.jpeg,
          RecoveryFileKind.png,
          RecoveryFileKind.pdf,
          RecoveryFileKind.docx,
        ]),
      );
      expect(summary.candidates.length, 4);
      expect(
        summary.candidates.where(
          (candidate) => candidate.kind == RecoveryFileKind.docx,
        ),
        hasLength(1),
      );
    },
  );

  test(
    'recovers exact candidate bytes and never overwrites an existing file',
    () async {
      final jpeg = <int>[0xFF, 0xD8, 0xFF, 0xE0, 5, 6, 7, 0xFF, 0xD9];
      final source = File('${temporaryDirectory.path}/source.bin');
      await source.writeAsBytes(<int>[1, 2, 3, ...jpeg, 8, 9], flush: true);
      final carver = FileCarver(chunkSize: 4);
      final summary = await carver.scan(source.path);
      final candidate = summary.candidates.single;
      final outputDirectory = Directory('${temporaryDirectory.path}/output');
      await outputDirectory.create();

      final firstPath = await carver.recover(candidate, outputDirectory.path);
      final secondPath = await carver.recover(candidate, outputDirectory.path);

      expect(await File(firstPath).readAsBytes(), jpeg);
      expect(await File(secondPath).readAsBytes(), jpeg);
      expect(secondPath, isNot(firstPath));
      expect(await source.readAsBytes(), <int>[1, 2, 3, ...jpeg, 8, 9]);
    },
  );

  test('ignores a start signature without a complete end marker', () async {
    final source = File('${temporaryDirectory.path}/incomplete.img');
    await source.writeAsBytes(<int>[0xFF, 0xD8, 0xFF, 1, 2, 3]);

    final summary = await FileCarver(chunkSize: 3).scan(source.path);

    expect(summary.candidates, isEmpty);
  });

  test('finds sequential files during one streaming scan', () async {
    final first = <int>[0xFF, 0xD8, 0xFF, 1, 2, 0xFF, 0xD9];
    final second = <int>[0xFF, 0xD8, 0xFF, 3, 4, 0xFF, 0xD9];
    final sourceBytes = <int>[
      ...List<int>.filled(5, 0),
      ...first,
      ...List<int>.filled(11, 0),
      ...second,
    ];
    final source = File('${temporaryDirectory.path}/sequential.img');
    await source.writeAsBytes(sourceBytes, flush: true);

    final summary = await FileCarver(chunkSize: 6).scan(source.path);

    expect(summary.candidates, hasLength(2));
    expect(summary.candidates.map((candidate) => candidate.length), <int>[
      first.length,
      second.length,
    ]);
  });

  test('honors cancellation before reading source data', () async {
    final source = File('${temporaryDirectory.path}/cancel.img');
    await source.writeAsBytes(List<int>.filled(64, 0));
    final token = CancellationToken()..cancel();

    expect(
      () =>
          FileCarver(chunkSize: 8).scan(source.path, cancellationToken: token),
      throwsA(isA<ScanCancelledException>()),
    );
  });

  test('scans and recovers through an authorized native descriptor', () async {
    if (!Platform.isMacOS) {
      return;
    }

    final jpeg = <int>[0xFF, 0xD8, 0xFF, 0xE0, 5, 6, 7, 0xFF, 0xD9];
    final sourceBytes = <int>[1, 2, 3, ...jpeg, 8, 9, 10];
    final source = File('${temporaryDirectory.path}/native-source.bin');
    await source.writeAsBytes(sourceBytes, flush: true);
    final path = source.path.toNativeUtf8();
    final libc = DynamicLibrary.process();
    final open = libc.lookupFunction<_OpenNative, _OpenDart>('open');
    final close = libc.lookupFunction<_CloseNative, _CloseDart>('close');
    final descriptor = open(path, 0);
    malloc.free(path);
    expect(descriptor, greaterThanOrEqualTo(0));
    addTearDown(() => close(descriptor));

    final carver = FileCarver(chunkSize: 7);
    final summary = await carver.scan(
      'authorized-raw-disk',
      totalBytesOverride: sourceBytes.length,
      nativeHandle: descriptor,
      nativeBlockSize: 8,
    );
    final candidate = summary.candidates.single;
    final preview = await carver.readPreview(
      candidate,
      nativeHandle: descriptor,
      nativeBlockSize: 8,
    );
    final outputDirectory = Directory('${temporaryDirectory.path}/native-out');
    await outputDirectory.create();
    final output = await carver.recover(
      candidate,
      outputDirectory.path,
      nativeHandle: descriptor,
      nativeBlockSize: 8,
    );

    expect(preview, jpeg);
    expect(await File(output).readAsBytes(), jpeg);
  });
}

typedef _OpenNative = Int32 Function(Pointer<Utf8> path, Int32 flags);
typedef _OpenDart = int Function(Pointer<Utf8> path, int flags);
typedef _CloseNative = Int32 Function(Int32 descriptor);
typedef _CloseDart = int Function(int descriptor);
