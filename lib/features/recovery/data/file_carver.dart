import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../domain/recovery_candidate.dart';
import 'recovery_random_access_reader.dart';

typedef ProgressCallback = void Function(ScanProgress progress);

class FileCarver {
  FileCarver({this.chunkSize = 4 * 1024 * 1024});

  final int chunkSize;

  static final List<_SignatureSpec> _specs = <_SignatureSpec>[
    _SignatureSpec(
      kind: RecoveryFileKind.jpeg,
      start: const <int>[0xFF, 0xD8, 0xFF],
      end: const <int>[0xFF, 0xD9],
      maxLength: 128 * 1024 * 1024,
      confidence: RecoveryConfidence.high,
    ),
    _SignatureSpec(
      kind: RecoveryFileKind.png,
      start: const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
      end: const <int>[0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82],
      maxLength: 128 * 1024 * 1024,
      confidence: RecoveryConfidence.high,
    ),
    _SignatureSpec(
      kind: RecoveryFileKind.pdf,
      start: const <int>[0x25, 0x50, 0x44, 0x46, 0x2D],
      end: const <int>[0x25, 0x25, 0x45, 0x4F, 0x46],
      maxLength: 256 * 1024 * 1024,
      confidence: RecoveryConfidence.medium,
    ),
    _SignatureSpec(
      kind: RecoveryFileKind.zip,
      start: const <int>[0x50, 0x4B, 0x03, 0x04],
      end: const <int>[0x50, 0x4B, 0x05, 0x06],
      maxLength: 512 * 1024 * 1024,
      confidence: RecoveryConfidence.medium,
      usesZipEndRecord: true,
    ),
  ];

  Future<ScanSummary> scan(
    String sourcePath, {
    int? totalBytesOverride,
    int? nativeHandle,
    int nativeBlockSize = 512,
    ProgressCallback? onProgress,
    CancellationToken? cancellationToken,
  }) async {
    final stopwatch = Stopwatch()..start();
    final totalBytes =
        totalBytesOverride ??
        (nativeHandle == null
            ? await File(sourcePath).length()
            : throw const FileSystemException('原始磁盘缺少容量信息'));
    final reader = await _openReader(
      sourcePath,
      nativeHandle: nativeHandle,
      nativeBlockSize: nativeBlockSize,
    );
    final found = <RecoveryCandidate>[];
    final seenOffsets = <String>{};
    final scanStates = <_SignatureSpec, _SignatureScanState>{
      for (final spec in _specs) spec: _SignatureScanState(),
    };
    final maxPatternLength = _specs
        .expand((spec) => <int>[spec.start.length, spec.end.length])
        .reduce(math.max);

    var carry = Uint8List(0);
    var bytesScanned = 0;
    var lastProgressUpdate = Duration.zero;

    try {
      while (bytesScanned < totalBytes) {
        _throwIfCancelled(cancellationToken);
        final block = await reader.readAt(
          bytesScanned,
          math.min(chunkSize, totalBytes - bytesScanned),
        );
        if (block.isEmpty) {
          break;
        }

        final window = Uint8List(carry.length + block.length)
          ..setRange(0, carry.length, carry)
          ..setRange(carry.length, carry.length + block.length, block);
        final windowStart = bytesScanned - carry.length;

        for (final spec in _specs) {
          final state = scanStates[spec]!;
          var searchFrom = 0;
          while (searchFrom < window.length) {
            var pending = state.pending;
            if (pending == null) {
              final startIndex = _indexOf(window, spec.start, searchFrom);
              if (startIndex == -1) {
                break;
              }
              final startOffset = windowStart + startIndex;
              final key = '${spec.kind.name}:$startOffset';
              searchFrom = startIndex + spec.start.length;
              if (startOffset < 0 || !seenOffsets.add(key)) {
                continue;
              }
              pending = _PendingSignature(startOffset: startOffset);
              state.pending = pending;
            }

            final minimumEndIndex = math.max(
              searchFrom,
              pending.startOffset + spec.start.length - windowStart,
            );
            final endIndex = _indexOf(window, spec.end, minimumEndIndex);
            final maximumEndOffset = pending.startOffset + spec.maxLength;

            if (endIndex == -1) {
              final windowEndOffset = windowStart + window.length;
              if (windowEndOffset >= maximumEndOffset) {
                state.pending = null;
                searchFrom = math.max(
                  searchFrom,
                  math.max(0, maximumEndOffset - windowStart),
                );
                continue;
              }
              break;
            }

            final markerOffset = windowStart + endIndex;
            if (markerOffset + spec.end.length > maximumEndOffset) {
              state.pending = null;
              searchFrom = math.max(
                searchFrom,
                math.max(0, maximumEndOffset - windowStart),
              );
              continue;
            }

            var endOffset = markerOffset + spec.end.length;
            if (spec.usesZipEndRecord) {
              final zipEndOffset = await _readZipEndOffset(
                reader,
                markerOffset,
                totalBytes,
              );
              if (zipEndOffset == null || zipEndOffset > maximumEndOffset) {
                searchFrom = endIndex + 1;
                continue;
              }
              endOffset = zipEndOffset;
            }

            var kind = spec.kind;
            if (kind == RecoveryFileKind.zip) {
              kind = await _classifyZip(
                sourcePath,
                pending.startOffset,
                endOffset - pending.startOffset,
                nativeHandle: nativeHandle,
                nativeBlockSize: nativeBlockSize,
              );
            }
            found.add(
              RecoveryCandidate(
                id: '${spec.kind.name}-${pending.startOffset}',
                sourcePath: sourcePath,
                offset: pending.startOffset,
                length: endOffset - pending.startOffset,
                kind: kind,
                confidence: spec.confidence,
              ),
            );
            state.pending = null;
            searchFrom = math.max(endIndex + spec.end.length, searchFrom);
          }
        }

        bytesScanned += block.length;
        final carryLength = math.min(maxPatternLength - 1, window.length);
        carry = Uint8List.fromList(window.sublist(window.length - carryLength));
        final elapsedSinceUpdate = stopwatch.elapsed - lastProgressUpdate;
        if (bytesScanned == totalBytes ||
            elapsedSinceUpdate >= const Duration(milliseconds: 100)) {
          onProgress?.call(
            ScanProgress(
              bytesScanned: bytesScanned,
              totalBytes: totalBytes,
              foundCount: found.length,
              elapsed: stopwatch.elapsed,
            ),
          );
          lastProgressUpdate = stopwatch.elapsed;
        }
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      await reader.close();
      stopwatch.stop();
    }

    found.sort((left, right) => left.offset.compareTo(right.offset));
    return ScanSummary(
      candidates: List<RecoveryCandidate>.unmodifiable(found),
      bytesScanned: bytesScanned,
      elapsed: stopwatch.elapsed,
    );
  }

  Future<String> recover(
    RecoveryCandidate candidate,
    String destinationDirectory, {
    int? nativeHandle,
    int nativeBlockSize = 512,
    CancellationToken? cancellationToken,
  }) async {
    final destination = Directory(destinationDirectory);
    if (!await destination.exists()) {
      throw FileSystemException('恢复目录不存在', destinationDirectory);
    }

    final outputPath = await _uniqueOutputPath(
      destinationDirectory,
      candidate.suggestedName,
    );
    final partialPath = '$outputPath.part';
    final sourceReader = await _openReader(
      candidate.sourcePath,
      nativeHandle: nativeHandle,
      nativeBlockSize: nativeBlockSize,
    );
    final outputWriter = await File(partialPath).open(mode: FileMode.write);
    var remaining = candidate.length;
    var sourceOffset = candidate.offset;

    try {
      while (remaining > 0) {
        _throwIfCancelled(cancellationToken);
        final bytes = await sourceReader.readAt(
          sourceOffset,
          math.min(chunkSize, remaining),
        );
        if (bytes.isEmpty) {
          throw const FileSystemException('源数据提前结束');
        }
        await outputWriter.writeFrom(bytes);
        remaining -= bytes.length;
        sourceOffset += bytes.length;
      }
      await outputWriter.flush();
    } catch (_) {
      await outputWriter.close();
      await sourceReader.close();
      final partial = File(partialPath);
      if (await partial.exists()) {
        await partial.delete();
      }
      rethrow;
    }

    await outputWriter.close();
    await sourceReader.close();
    await File(partialPath).rename(outputPath);
    return outputPath;
  }

  Future<Uint8List> readPreview(
    RecoveryCandidate candidate, {
    int? nativeHandle,
    int nativeBlockSize = 512,
  }) async {
    if (!candidate.canPreview) {
      throw const FileSystemException('该文件不支持内存预览');
    }
    final reader = await _openReader(
      candidate.sourcePath,
      nativeHandle: nativeHandle,
      nativeBlockSize: nativeBlockSize,
    );
    try {
      return reader.readAt(candidate.offset, candidate.length);
    } finally {
      await reader.close();
    }
  }

  Future<int?> _readZipEndOffset(
    RecoveryRandomAccessReader reader,
    int markerOffset,
    int totalBytes,
  ) async {
    const fixedRecordLength = 22;
    if (markerOffset + fixedRecordLength > totalBytes) {
      return null;
    }
    final record = await reader.readAt(markerOffset, fixedRecordLength);
    if (record.length != fixedRecordLength) {
      return null;
    }
    final commentLength = record[20] | (record[21] << 8);
    final endOffset = markerOffset + fixedRecordLength + commentLength;
    return endOffset <= totalBytes ? endOffset : null;
  }

  Future<RecoveryFileKind> _classifyZip(
    String sourcePath,
    int offset,
    int length, {
    required int? nativeHandle,
    required int nativeBlockSize,
  }) async {
    final reader = await _openReader(
      sourcePath,
      nativeHandle: nativeHandle,
      nativeBlockSize: nativeBlockSize,
    );
    try {
      final sample = await reader.readAt(
        offset,
        math.min(length, 4 * 1024 * 1024),
      );
      if (_indexOf(sample, _ascii('word/'), 0) != -1) {
        return RecoveryFileKind.docx;
      }
      if (_indexOf(sample, _ascii('xl/'), 0) != -1) {
        return RecoveryFileKind.xlsx;
      }
      if (_indexOf(sample, _ascii('ppt/'), 0) != -1) {
        return RecoveryFileKind.pptx;
      }
      return RecoveryFileKind.zip;
    } finally {
      await reader.close();
    }
  }

  Future<String> _uniqueOutputPath(String directory, String name) async {
    final extension = p.extension(name);
    final stem = p.basenameWithoutExtension(name);
    var candidate = p.join(directory, name);
    var suffix = 1;
    while (await File(candidate).exists()) {
      candidate = p.join(directory, '${stem}_$suffix$extension');
      suffix += 1;
    }
    return candidate;
  }

  Future<RecoveryRandomAccessReader> _openReader(
    String sourcePath, {
    required int? nativeHandle,
    required int nativeBlockSize,
  }) {
    if (nativeHandle != null) {
      return Future<RecoveryRandomAccessReader>.value(
        NativeFileDescriptorReader(nativeHandle, blockSize: nativeBlockSize),
      );
    }
    return FileRecoveryRandomAccessReader.open(sourcePath);
  }

  static List<int> _ascii(String value) => value.codeUnits;

  static int _indexOf(List<int> source, List<int> pattern, int start) {
    if (pattern.isEmpty || source.length < pattern.length) {
      return -1;
    }
    var index = source.indexOf(pattern.first, math.max(0, start));
    while (index != -1 && index <= source.length - pattern.length) {
      var matches = true;
      for (
        var patternIndex = 1;
        patternIndex < pattern.length;
        patternIndex++
      ) {
        if (source[index + patternIndex] != pattern[patternIndex]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        return index;
      }
      index = source.indexOf(pattern.first, index + 1);
    }
    return -1;
  }

  static void _throwIfCancelled(CancellationToken? token) {
    if (token?.isCancelled ?? false) {
      throw const ScanCancelledException();
    }
  }
}

class _SignatureScanState {
  _PendingSignature? pending;
}

class _PendingSignature {
  const _PendingSignature({required this.startOffset});

  final int startOffset;
}

class _SignatureSpec {
  const _SignatureSpec({
    required this.kind,
    required this.start,
    required this.end,
    required this.maxLength,
    required this.confidence,
    this.usesZipEndRecord = false,
  });

  final RecoveryFileKind kind;
  final List<int> start;
  final List<int> end;
  final int maxLength;
  final RecoveryConfidence confidence;
  final bool usesZipEndRecord;
}
