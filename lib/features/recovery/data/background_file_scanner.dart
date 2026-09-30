import 'dart:async';
import 'dart:isolate';

import '../domain/recovery_candidate.dart';
import 'file_carver.dart';

typedef BackgroundScanProgressCallback = void Function(ScanProgress progress);

class BackgroundFileScanner {
  BackgroundFileScanner({this.chunkSize = 4 * 1024 * 1024});

  final int chunkSize;

  Isolate? _isolate;
  ReceivePort? _receivePort;
  StreamSubscription<dynamic>? _subscription;
  SendPort? _commandPort;
  Completer<ScanSummary>? _completer;
  bool _cancelRequested = false;

  bool get isRunning => _completer != null;

  Future<ScanSummary> scan(
    String sourcePath, {
    required int totalBytes,
    int? nativeHandle,
    int nativeBlockSize = 512,
    BackgroundScanProgressCallback? onProgress,
  }) async {
    if (isRunning) {
      throw StateError('已有扫描任务正在运行');
    }

    final receivePort = ReceivePort();
    final completer = Completer<ScanSummary>();
    _receivePort = receivePort;
    _completer = completer;
    _cancelRequested = false;
    _subscription = receivePort.listen((message) {
      _handleMessage(message, completer, onProgress);
    });

    try {
      final isolate = await Isolate.spawn<Map<String, Object?>>(
        _backgroundScanEntry,
        <String, Object?>{
          'sendPort': receivePort.sendPort,
          'sourcePath': sourcePath,
          'totalBytes': totalBytes,
          'nativeHandle': nativeHandle,
          'nativeBlockSize': nativeBlockSize,
          'chunkSize': chunkSize,
        },
        onError: receivePort.sendPort,
        onExit: receivePort.sendPort,
        errorsAreFatal: true,
        debugName: 'recovera-deep-scan',
      );
      if (identical(_completer, completer)) {
        _isolate = isolate;
        if (_cancelRequested) {
          _commandPort?.send('cancel');
        }
      } else {
        isolate.kill(priority: Isolate.immediate);
      }
    } catch (error, stackTrace) {
      _finishWithError(completer, error, stackTrace);
    }

    return completer.future;
  }

  void cancel() {
    if (!isRunning) {
      return;
    }
    _cancelRequested = true;
    _commandPort?.send('cancel');
  }

  void dispose() {
    final completer = _completer;
    _isolate?.kill(priority: Isolate.immediate);
    if (completer != null && !completer.isCompleted) {
      completer.completeError(const ScanCancelledException());
    }
    _clearCurrentTask();
  }

  void _handleMessage(
    dynamic message,
    Completer<ScanSummary> completer,
    BackgroundScanProgressCallback? onProgress,
  ) {
    if (!identical(_completer, completer)) {
      return;
    }
    if (message == null) {
      if (!completer.isCompleted) {
        _finishWithError(
          completer,
          const BackgroundScanException('后台扫描进程意外结束'),
          StackTrace.current,
        );
      }
      return;
    }
    if (message is List && message.length >= 2) {
      _finishWithError(
        completer,
        BackgroundScanException(message.first.toString()),
        StackTrace.fromString(message[1].toString()),
      );
      return;
    }
    if (message is! Map<Object?, Object?>) {
      return;
    }

    switch (message['type']) {
      case 'ready':
        _commandPort = message['commandPort'] as SendPort;
        if (_cancelRequested) {
          _commandPort!.send('cancel');
        }
      case 'progress':
        if (!_cancelRequested) {
          onProgress?.call(_decodeProgress(message));
        }
      case 'complete':
        _finishWithValue(completer, _decodeSummary(message));
      case 'cancelled':
        _finishWithError(
          completer,
          const ScanCancelledException(),
          StackTrace.current,
        );
      case 'error':
        _finishWithError(
          completer,
          _decodeError(message),
          StackTrace.fromString(message['stackTrace']?.toString() ?? ''),
        );
    }
  }

  void _finishWithValue(Completer<ScanSummary> completer, ScanSummary summary) {
    if (!identical(_completer, completer) || completer.isCompleted) {
      return;
    }
    completer.complete(summary);
    _clearCurrentTask();
  }

  void _finishWithError(
    Completer<ScanSummary> completer,
    Object error,
    StackTrace stackTrace,
  ) {
    if (!identical(_completer, completer) || completer.isCompleted) {
      return;
    }
    completer.completeError(error, stackTrace);
    _clearCurrentTask();
  }

  void _clearCurrentTask() {
    _isolate = null;
    _commandPort = null;
    _completer = null;
    _cancelRequested = false;
    _receivePort?.close();
    _receivePort = null;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
  }
}

class BackgroundScanException implements Exception {
  const BackgroundScanException(this.message);

  final String message;

  @override
  String toString() => message;
}

@pragma('vm:entry-point')
Future<void> _backgroundScanEntry(Map<String, Object?> request) async {
  final sendPort = request['sendPort']! as SendPort;
  final commandPort = ReceivePort();
  final cancellationToken = CancellationToken();
  final commandSubscription = commandPort.listen((message) {
    if (message == 'cancel') {
      cancellationToken.cancel();
    }
  });
  sendPort.send(<String, Object?>{
    'type': 'ready',
    'commandPort': commandPort.sendPort,
  });

  try {
    final summary = await FileCarver(chunkSize: request['chunkSize']! as int)
        .scan(
          request['sourcePath']! as String,
          totalBytesOverride: request['totalBytes']! as int,
          nativeHandle: request['nativeHandle'] as int?,
          nativeBlockSize: request['nativeBlockSize']! as int,
          cancellationToken: cancellationToken,
          onProgress: (progress) {
            sendPort.send(_encodeProgress(progress));
          },
        );
    sendPort.send(_encodeSummary(summary));
  } on ScanCancelledException {
    sendPort.send(const <String, Object?>{'type': 'cancelled'});
  } catch (error, stackTrace) {
    sendPort.send(_encodeError(error, stackTrace));
  } finally {
    await commandSubscription.cancel();
    commandPort.close();
  }
}

Map<String, Object?> _encodeProgress(ScanProgress progress) =>
    <String, Object?>{
      'type': 'progress',
      'bytesScanned': progress.bytesScanned,
      'totalBytes': progress.totalBytes,
      'foundCount': progress.foundCount,
      'elapsedMicroseconds': progress.elapsed.inMicroseconds,
    };

ScanProgress _decodeProgress(Map<Object?, Object?> message) => ScanProgress(
  bytesScanned: message['bytesScanned']! as int,
  totalBytes: message['totalBytes']! as int,
  foundCount: message['foundCount']! as int,
  elapsed: Duration(microseconds: message['elapsedMicroseconds']! as int),
);

Map<String, Object?> _encodeSummary(ScanSummary summary) => <String, Object?>{
  'type': 'complete',
  'bytesScanned': summary.bytesScanned,
  'elapsedMicroseconds': summary.elapsed.inMicroseconds,
  'candidates': summary.candidates
      .map(
        (candidate) => <String, Object?>{
          'id': candidate.id,
          'sourcePath': candidate.sourcePath,
          'offset': candidate.offset,
          'length': candidate.length,
          'kind': candidate.kind.index,
          'confidence': candidate.confidence.index,
        },
      )
      .toList(growable: false),
};

ScanSummary _decodeSummary(Map<Object?, Object?> message) {
  final encodedCandidates = message['candidates']! as List<Object?>;
  return ScanSummary(
    candidates: encodedCandidates
        .map((encoded) {
          final candidate = encoded! as Map<Object?, Object?>;
          return RecoveryCandidate(
            id: candidate['id']! as String,
            sourcePath: candidate['sourcePath']! as String,
            offset: candidate['offset']! as int,
            length: candidate['length']! as int,
            kind: RecoveryFileKind.values[candidate['kind']! as int],
            confidence:
                RecoveryConfidence.values[candidate['confidence']! as int],
          );
        })
        .toList(growable: false),
    bytesScanned: message['bytesScanned']! as int,
    elapsed: Duration(microseconds: message['elapsedMicroseconds']! as int),
  );
}

Map<String, Object?> _encodeError(Object error, StackTrace stackTrace) =>
    <String, Object?>{
      'type': 'error',
      'message': error.toString(),
      'stackTrace': stackTrace.toString(),
    };

Object _decodeError(Map<Object?, Object?> message) =>
    BackgroundScanException(message['message']?.toString() ?? '后台扫描失败');
