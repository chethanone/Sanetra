import 'dart:math' as math;

/// A 2D point with double precision coordinates.
class OcrPoint {
  final double x;
  final double y;

  const OcrPoint(this.x, this.y);

  @override
  String toString() => '(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)})';

  double distanceTo(OcrPoint other) {
    final dx = x - other.x;
    final dy = y - other.y;
    return math.sqrt(dx * dx + dy * dy);
  }
}

/// A 4-point polygon representing a detected text region in original image coordinates.
class OcrPolygon {
  final OcrPoint topLeft;
  final OcrPoint topRight;
  final OcrPoint bottomRight;
  final OcrPoint bottomLeft;
  final double score;
  final List<OcrPoint> centerline;
  final double curveHalfHeight;
  final String geometryType;
  final double angleDegrees;

  const OcrPolygon({
    required this.topLeft,
    required this.topRight,
    required this.bottomRight,
    required this.bottomLeft,
    required this.score,
    this.centerline = const [],
    this.curveHalfHeight = 0.0,
    this.geometryType = 'straight',
    this.angleDegrees = 0.0,
  });

  bool get isCurved => geometryType == 'curved' && centerline.length >= 3;

  List<OcrPoint> get points => [topLeft, topRight, bottomRight, bottomLeft];

  double get minX => math.min(
        math.min(topLeft.x, topRight.x),
        math.min(bottomRight.x, bottomLeft.x),
      );

  double get maxX => math.max(
        math.max(topLeft.x, topRight.x),
        math.max(bottomRight.x, bottomLeft.x),
      );

  double get minY => math.min(
        math.min(topLeft.y, topRight.y),
        math.min(bottomRight.y, bottomLeft.y),
      );

  double get maxY => math.max(
        math.max(topLeft.y, topRight.y),
        math.max(bottomRight.y, bottomLeft.y),
      );

  double get width => math.max(0.0, maxX - minX);
  double get height => math.max(0.0, maxY - minY);

  double get centerX => (topLeft.x + topRight.x + bottomRight.x + bottomLeft.x) / 4.0;
  double get centerY => (topLeft.y + topRight.y + bottomRight.y + bottomLeft.y) / 4.0;

  /// Approximate polygon perimeter.
  double get perimeter =>
      topLeft.distanceTo(topRight) +
      topRight.distanceTo(bottomRight) +
      bottomRight.distanceTo(bottomLeft) +
      bottomLeft.distanceTo(topLeft);

  /// Approximate polygon area via Shoelace formula.
  double get area {
    final pts = points;
    double a = 0.0;
    for (int i = 0; i < pts.length; i++) {
      final j = (i + 1) % pts.length;
      a += pts[i].x * pts[j].y - pts[j].x * pts[i].y;
    }
    return (a / 2.0).abs();
  }
}

/// A contiguous same-script text segment within a recognized line.
class OcrTextSegment {
  final String text;
  final String language;
  final double confidence;
  final bool isLanguageUncertain;

  const OcrTextSegment({
    required this.text,
    required this.language,
    required this.confidence,
    this.isLanguageUncertain = false,
  });
}

/// A recognized text line along with its polygon region, confidence, and detected language.
class OcrLineResult {
  final String text;
  final double confidence;
  final OcrPolygon polygon;
  final int lineIndex;
  final String language;
  final bool isLanguageUncertain;
  final List<OcrTextSegment> segments;
  final String geometryType;
  final int orientationDegrees;
  final String spatialPosition;
  final int columnIndex;
  final bool isHeading;

  const OcrLineResult({
    required this.text,
    required this.confidence,
    required this.polygon,
    required this.lineIndex,
    this.language = 'en-IN',
    this.isLanguageUncertain = false,
    this.segments = const [],
    this.geometryType = 'straight',
    this.orientationDegrees = 0,
    this.spatialPosition = '',
    this.columnIndex = 0,
    this.isHeading = false,
  });

  OcrLineResult copyWith({
    String? text,
    double? confidence,
    OcrPolygon? polygon,
    int? lineIndex,
    String? language,
    bool? isLanguageUncertain,
    List<OcrTextSegment>? segments,
    String? geometryType,
    int? orientationDegrees,
    String? spatialPosition,
    int? columnIndex,
    bool? isHeading,
  }) {
    return OcrLineResult(
      text: text ?? this.text,
      confidence: confidence ?? this.confidence,
      polygon: polygon ?? this.polygon,
      lineIndex: lineIndex ?? this.lineIndex,
      language: language ?? this.language,
      isLanguageUncertain: isLanguageUncertain ?? this.isLanguageUncertain,
      segments: segments ?? this.segments,
      geometryType: geometryType ?? this.geometryType,
      orientationDegrees: orientationDegrees ?? this.orientationDegrees,
      spatialPosition: spatialPosition ?? this.spatialPosition,
      columnIndex: columnIndex ?? this.columnIndex,
      isHeading: isHeading ?? this.isHeading,
    );
  }

  @override
  String toString() =>
      'Line $lineIndex [$language${isLanguageUncertain ? "?" : ""}]: "$text" (${(confidence * 100).toStringAsFixed(1)}%)';
}

/// Overall OCR execution result.
class OcrResult {
  final List<OcrLineResult> lines;
  final String fullText;
  final int durationMs;
  final int imageWidth;
  final int imageHeight;
  final bool isSuccess;
  final String? errorMessage;
  final String sceneSummary;

  const OcrResult({
    required this.lines,
    required this.fullText,
    required this.durationMs,
    required this.imageWidth,
    required this.imageHeight,
    this.isSuccess = true,
    this.errorMessage,
    this.sceneSummary = '',
  });

  factory OcrResult.empty({
    int durationMs = 0,
    int imageWidth = 0,
    int imageHeight = 0,
  }) {
    return OcrResult(
      lines: const [],
      fullText: '',
      durationMs: durationMs,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      isSuccess: true,
    );
  }

  factory OcrResult.failure(String message) {
    return OcrResult(
      lines: const [],
      fullText: '',
      durationMs: 0,
      imageWidth: 0,
      imageHeight: 0,
      isSuccess: false,
      errorMessage: message,
    );
  }

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;
  int get lineCount => lines.length;
}

