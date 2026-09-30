enum RecoveryFileKind { jpeg, png, pdf, zip, docx, xlsx, pptx }

enum RecoveryConfidence { high, medium }

class RecoveryCandidate {
  const RecoveryCandidate({
    required this.id,
    required this.sourcePath,
    required this.offset,
    required this.length,
    required this.kind,
    required this.confidence,
  });

  final String id;
  final String sourcePath;
  final int offset;
  final int length;
  final RecoveryFileKind kind;
  final RecoveryConfidence confidence;

  String get extension => switch (kind) {
    RecoveryFileKind.jpeg => 'jpg',
    RecoveryFileKind.png => 'png',
    RecoveryFileKind.pdf => 'pdf',
    RecoveryFileKind.zip => 'zip',
    RecoveryFileKind.docx => 'docx',
    RecoveryFileKind.xlsx => 'xlsx',
    RecoveryFileKind.pptx => 'pptx',
  };

  String get typeLabel => switch (kind) {
    RecoveryFileKind.jpeg => 'JPEG 图片',
    RecoveryFileKind.png => 'PNG 图片',
    RecoveryFileKind.pdf => 'PDF 文档',
    RecoveryFileKind.zip => 'ZIP 压缩包',
    RecoveryFileKind.docx => 'Word 文档',
    RecoveryFileKind.xlsx => 'Excel 表格',
    RecoveryFileKind.pptx => 'PowerPoint',
  };

  bool get canPreview =>
      (kind == RecoveryFileKind.jpeg || kind == RecoveryFileKind.png) &&
      length <= 16 * 1024 * 1024;

  String get suggestedName =>
      'recovered_${offset.toRadixString(16).padLeft(12, '0')}.$extension';
}

class ScanSummary {
  const ScanSummary({
    required this.candidates,
    required this.bytesScanned,
    required this.elapsed,
  });

  final List<RecoveryCandidate> candidates;
  final int bytesScanned;
  final Duration elapsed;
}

class ScanProgress {
  const ScanProgress({
    required this.bytesScanned,
    required this.totalBytes,
    required this.foundCount,
    required this.elapsed,
  });

  final int bytesScanned;
  final int totalBytes;
  final int foundCount;
  final Duration elapsed;

  double get fraction => totalBytes == 0 ? 0 : bytesScanned / totalBytes;

  double get bytesPerSecond => elapsed.inMicroseconds == 0
      ? 0
      : bytesScanned * Duration.microsecondsPerSecond / elapsed.inMicroseconds;

  Duration? get estimatedRemaining {
    final rate = bytesPerSecond;
    if (rate <= 0 || bytesScanned >= totalBytes) {
      return null;
    }
    return Duration(seconds: ((totalBytes - bytesScanned) / rate).ceil());
  }
}

class CancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

class ScanCancelledException implements Exception {
  const ScanCancelledException();
}
