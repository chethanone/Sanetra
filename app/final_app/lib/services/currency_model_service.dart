import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// ------------------------------------------------------------
// CURRENCY DETECTION RESULT & CONFIRMATION STATES
// ------------------------------------------------------------

enum DetectionConfirmationState {
  confirmed,
  tentative,
  conflicting,
}

DetectionConfirmationState parseConfirmationState(String? raw) {
  switch (raw) {
    case 'conflicting':
      return DetectionConfirmationState.conflicting;
    case 'tentative':
      return DetectionConfirmationState.tentative;
    case 'confirmed':
    default:
      return DetectionConfirmationState.confirmed;
  }
}

class CurrencyDetection {
  final int classId;
  final String denomination;
  final int value;
  final double confidence;

  // Bounding box in original image coordinates [x1, y1, x2, y2].
  final double x1;
  final double y1;
  final double x2;
  final double y2;

  // Phase 4M Calibrated Uncertainty & Conflict Metadata
  final String type;
  final int top2ClassId;
  final String top2ClassName;
  final double top2Confidence;
  final double classMargin;
  final int suppressedConflictCount;
  final int suppressedConflictClassId;
  final String suppressedConflictClassName;
  final double suppressedConflictConfidence;
  final double interBoxMaxIoU;
  final double interBoxMaxIoMin;
  final DetectionConfirmationState confirmationState;
  final List<String> uncertaintyReasons;
  final int framesVisible;
  final int framesMissing;

  const CurrencyDetection({
    required this.classId,
    required this.denomination,
    required this.value,
    required this.confidence,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    this.type = '',
    this.top2ClassId = -1,
    this.top2ClassName = '',
    this.top2Confidence = 0.0,
    this.classMargin = 1.0,
    this.suppressedConflictCount = 0,
    this.suppressedConflictClassId = -1,
    this.suppressedConflictClassName = '',
    this.suppressedConflictConfidence = 0.0,
    this.interBoxMaxIoU = 0.0,
    this.interBoxMaxIoMin = 0.0,
    this.confirmationState = DetectionConfirmationState.confirmed,
    this.uncertaintyReasons = const [],
    this.framesVisible = 1,
    this.framesMissing = 0,
  });

  double get width => math.max(0.0, x2 - x1);
  double get height => math.max(0.0, y2 - y1);
  double get area => width * height;
  bool get isCoin => type == 'coin' || denomination.contains('COIN') || classId >= 6;
  bool get isConfirmed => confirmationState == DetectionConfirmationState.confirmed;
  bool get isTentative => confirmationState == DetectionConfirmationState.tentative;
  bool get isConflicting => confirmationState == DetectionConfirmationState.conflicting;

  CurrencyDetection copyWith({
    int? classId,
    String? denomination,
    int? value,
    double? confidence,
    double? x1,
    double? y1,
    double? x2,
    double? y2,
    String? type,
    int? top2ClassId,
    String? top2ClassName,
    double? top2Confidence,
    double? classMargin,
    int? suppressedConflictCount,
    int? suppressedConflictClassId,
    String? suppressedConflictClassName,
    double? suppressedConflictConfidence,
    double? interBoxMaxIoU,
    double? interBoxMaxIoMin,
    DetectionConfirmationState? confirmationState,
    List<String>? uncertaintyReasons,
    int? framesVisible,
    int? framesMissing,
  }) {
    return CurrencyDetection(
      classId: classId ?? this.classId,
      denomination: denomination ?? this.denomination,
      value: value ?? this.value,
      confidence: confidence ?? this.confidence,
      x1: x1 ?? this.x1,
      y1: y1 ?? this.y1,
      x2: x2 ?? this.x2,
      y2: y2 ?? this.y2,
      type: type ?? this.type,
      top2ClassId: top2ClassId ?? this.top2ClassId,
      top2ClassName: top2ClassName ?? this.top2ClassName,
      top2Confidence: top2Confidence ?? this.top2Confidence,
      classMargin: classMargin ?? this.classMargin,
      suppressedConflictCount: suppressedConflictCount ?? this.suppressedConflictCount,
      suppressedConflictClassId: suppressedConflictClassId ?? this.suppressedConflictClassId,
      suppressedConflictClassName: suppressedConflictClassName ?? this.suppressedConflictClassName,
      suppressedConflictConfidence: suppressedConflictConfidence ?? this.suppressedConflictConfidence,
      interBoxMaxIoU: interBoxMaxIoU ?? this.interBoxMaxIoU,
      interBoxMaxIoMin: interBoxMaxIoMin ?? this.interBoxMaxIoMin,
      confirmationState: confirmationState ?? this.confirmationState,
      uncertaintyReasons: uncertaintyReasons ?? this.uncertaintyReasons,
      framesVisible: framesVisible ?? this.framesVisible,
      framesMissing: framesMissing ?? this.framesMissing,
    );
  }
}

class CurrencyInferenceResult {
  final List<CurrencyDetection> detections;
  final int totalValue;
  final int imageWidth;
  final int imageHeight;
  final bool isCandidateMode;
  final String totalStatus;
  final bool isTotalConfirmed;
  final int confirmedValue;
  final int detectedSumValue;
  final int confirmedItemsValue;
  final int confirmedNoteCount;
  final int tentativeNoteCount;
  final int conflictingNoteCount;
  final List<String> uncertaintyReasons;
  final double preprocessTimeMs;
  final double coinInferenceTimeMs;
  final double banknoteInferenceTimeMs;
  final double totalTimeMs;

  const CurrencyInferenceResult({
    required this.detections,
    required this.totalValue,
    required this.imageWidth,
    required this.imageHeight,
    this.isCandidateMode = false,
    this.totalStatus = 'confirmed',
    this.isTotalConfirmed = true,
    this.confirmedValue = 0,
    this.detectedSumValue = 0,
    this.confirmedItemsValue = 0,
    this.confirmedNoteCount = 0,
    this.tentativeNoteCount = 0,
    this.conflictingNoteCount = 0,
    this.uncertaintyReasons = const [],
    this.preprocessTimeMs = 0.0,
    this.coinInferenceTimeMs = 0.0,
    this.banknoteInferenceTimeMs = 0.0,
    this.totalTimeMs = 0.0,
  });
}

// ------------------------------------------------------------
// NATIVE CURRENCY MODEL SERVICE (MethodChannel)
// ------------------------------------------------------------

class CurrencyModelService {
  static const MethodChannel _nativeChannel =
      MethodChannel('visionmission/currency_detector');

  bool _isLoaded = false;
  bool get isLoaded => _isLoaded;

  static const double confidenceThreshold = 0.25;
  static const double candidateBanknoteConfThreshold = 0.30;
  static const double candidateCoinConfThreshold = 0.35;
  static const double candidateConfirmConfThreshold = 0.45;
  static const double candidateMinClassMargin = 0.15;
  static const double candidateMaxSuppressedConflict = 0.25;
  static const double candidateMaxInterBoxIoU = 0.25;
  static const double candidateMaxInterBoxIoMin = 0.70;
  static const double candidateCoinConfirmConfThreshold = 0.60;
  static const double candidateCoinMinClassMargin = 0.15;
  static const double candidateCoinCrossModelIoMin = 0.70;
  static const double candidateCoinOnNoteMinMargin = 0.25;
  static const double candidateCoinOnNoteMinAreaFrac = 0.012;
  static const double candidateCoinOnNoteMinAspect = 0.70;
  static const double candidateCoinOnNoteMaxAspect = 1.45;
  static const double candidateSpuriousWrapperNoteMinAreaFrac = 0.72;
  static const double candidateCoinMinAspectRatio = 0.60;
  static const double candidateCoinMaxAspectRatio = 1.65;
  static const double candidateCoinMinAreaFrac = 0.002;
  static const double iouThreshold = 0.45;

  double get effectiveCoinConfThreshold =>
      _isCandidateMode ? candidateCoinConfThreshold : confidenceThreshold;

  double get effectiveBanknoteConfThreshold =>
      _isCandidateMode ? candidateBanknoteConfThreshold : confidenceThreshold;

  static const List<String> classNames = [
    'INR_10',
    'INR_20',
    'INR_50',
    'INR_100',
    'INR_200',
    'INR_500',
    'INR_1_COIN',
    'INR_2_COIN',
    'INR_5_COIN',
    'INR_10_COIN',
  ];

  static const List<int> denominationValues = [
    10,
    20,
    50,
    100,
    200,
    500,
    1,
    2,
    5,
    10,
  ];

  static const List<String> coinClasses = [
    'INR_1_COIN',
    'INR_2_COIN',
    'INR_5_COIN',
    'INR_10_COIN',
  ];

  static const List<String> banknoteClasses = [
    'INR_10',
    'INR_20',
    'INR_50',
    'INR_100',
    'INR_200',
    'INR_500',
  ];

  static String formatItemDisplayName(String className, int value) {
    switch (className) {
      case 'INR_10': return '₹10 Note';
      case 'INR_20': return '₹20 Note';
      case 'INR_50': return '₹50 Note';
      case 'INR_100': return '₹100 Note';
      case 'INR_200': return '₹200 Note';
      case 'INR_500': return '₹500 Note';
      case 'INR_1_COIN':
      case 'COIN_1': return '₹1 Coin';
      case 'INR_2_COIN':
      case 'COIN_2': return '₹2 Coin';
      case 'INR_5_COIN':
      case 'COIN_5': return '₹5 Coin';
      case 'INR_10_COIN':
      case 'COIN_10': return '₹10 Coin';
      case 'COIN_20': return '₹20 Coin';
      default:
        if (className.contains('COIN')) {
          return '₹$value Coin';
        }
        return '₹$value Note';
    }
  }

  static String formatItemSpokenName(String className, int value) {
    if (className.startsWith('COIN_') || className.contains('COIN')) {
      return '$value Rupee Coin';
    } else {
      return '$value Rupee Note';
    }
  }

  static const bool isCandidateBuild =
      bool.fromEnvironment('CANDIDATE_BUILD', defaultValue: false);
  static const String candidateCoinAsset = String.fromEnvironment(
    'CANDIDATE_COIN_ASSET',
    defaultValue: 'assets/models/currency/candidates/indian_coin_phase4n_candidate.onnx',
  );
  bool _isCandidateMode = isCandidateBuild;
  bool get isCandidateMode => _isCandidateMode;

  Future<void> loadModel({
    bool? useCandidate,
    bool forceProductionBaseline = false,
  }) async {
    if (_isLoaded && !forceProductionBaseline && useCandidate == null) return;

    try {
      final bool candidate = forceProductionBaseline ? false : (useCandidate ?? isCandidateBuild);
      final String coinAsset = candidate
          ? candidateCoinAsset
          : 'assets/models/currency/indian_coin_yolov8n.onnx';
      final String banknoteAsset = candidate
          ? 'assets/models/currency/candidates/indian_banknote_phase4l_candidate.onnx'
          : 'assets/models/currency/indian_banknote_yolov8n.onnx';

      debugPrint('[CURRENCY-SERVICE] Initializing native ONNX currency models (CandidateReq=$candidate, ForceProd=$forceProductionBaseline)...');
      debugPrint('  Coin asset: $coinAsset');
      debugPrint('  Banknote asset: $banknoteAsset');

      final Map<dynamic, dynamic>? res = await _nativeChannel.invokeMethod('initModels', {
        'coinModelAsset': coinAsset,
        'banknoteModelAsset': banknoteAsset,
        'forceProductionBaseline': forceProductionBaseline,
        'numThreads': 4,
      });

      final bool nativeCandidateMode = res?['isCandidateMode'] == true;
      if (candidate && !forceProductionBaseline && !nativeCandidateMode) {
        throw StateError(
          'Sanetra refused to start currency recognition: Android did not activate the validated final currency pipeline. '
          'This prevents fallback to the legacy detector without identity verification.',
        );
      }
      _isCandidateMode = nativeCandidateMode;
      debugPrint('[CURRENCY-SERVICE] Native models initialized successfully (activeCandidateMode=$_isCandidateMode): $res');
      _isLoaded = true;
    } catch (e, stackTrace) {
      debugPrint('[CURRENCY-SERVICE] Model load error: $e');
      debugPrint('$stackTrace');
      _isLoaded = false;
      rethrow;
    }
  }

  /// High-resolution Snapshot Inference (MethodChannel 'detectSnapshot')
  Future<CurrencyInferenceResult> runImageInference(
    Uint8List imageBytes, {
    String source = 'Image',
    int orientationDegrees = 0,
    double? coinConfThreshold,
    double? banknoteConfThreshold,
    double iouThreshold = CurrencyModelService.iouThreshold,
  }) async {
    if (!_isLoaded) {
      await loadModel();
    }

    try {
      final double resolvedCoinConf = coinConfThreshold ?? effectiveCoinConfThreshold;
      final double resolvedNoteConf = banknoteConfThreshold ?? effectiveBanknoteConfThreshold;
      debugPrint('[CURRENCY-SERVICE] Running native snapshot inference: $source (${imageBytes.length} bytes, coinConf=$resolvedCoinConf, noteConf=$resolvedNoteConf)');

      final Map<dynamic, dynamic>? res = await _nativeChannel.invokeMethod('detectSnapshot', {
        'imageBytes': imageBytes,
        'orientationDegrees': orientationDegrees,
        'coinConfThreshold': resolvedCoinConf,
        'banknoteConfThreshold': resolvedNoteConf,
        'iouThreshold': iouThreshold,
      });

      if (res == null) {
        return const CurrencyInferenceResult(
          detections: [],
          totalValue: 0,
          imageWidth: 0,
          imageHeight: 0,
        );
      }

      final parsed = _parseInferenceResult(res, 0, 0);
      debugPrint(
        '[CURRENCY-SERVICE] Detections parsed: ${parsed.detections.length}, '
        'RawSum: ₹${parsed.detectedSumValue}, Status: ${parsed.totalStatus}, '
        'Confirmed: ${parsed.isTotalConfirmed}',
      );
      return parsed;
    } catch (e, stackTrace) {
      debugPrint('[CURRENCY-SERVICE] Inference error: $e');
      debugPrint('$stackTrace');
      rethrow;
    }
  }

  /// Real-time Camera Image Stream Inference (MethodChannel 'detectCameraFrame')
  Future<CurrencyInferenceResult> runCameraImageInference(
    CameraImage cameraImage, {
    int sensorOrientation = 90,
    double? coinConfThreshold,
    double? banknoteConfThreshold,
    double iouThreshold = CurrencyModelService.iouThreshold,
  }) async {
    if (!_isLoaded) {
      await loadModel();
    }

    try {
      if (cameraImage.planes.length < 3) {
        return CurrencyInferenceResult(
          detections: const [],
          totalValue: 0,
          imageWidth: cameraImage.width,
          imageHeight: cameraImage.height,
        );
      }

      final double resolvedCoinConf = coinConfThreshold ?? effectiveCoinConfThreshold;
      final double resolvedNoteConf = banknoteConfThreshold ?? effectiveBanknoteConfThreshold;

      final Map<dynamic, dynamic>? res = await _nativeChannel.invokeMethod('detectCameraFrame', {
        'yBytes': cameraImage.planes[0].bytes,
        'uBytes': cameraImage.planes[1].bytes,
        'vBytes': cameraImage.planes[2].bytes,
        'width': cameraImage.width,
        'height': cameraImage.height,
        'yRowStride': cameraImage.planes[0].bytesPerRow,
        'uvRowStride': cameraImage.planes[1].bytesPerRow,
        'uvPixelStride': cameraImage.planes[1].bytesPerPixel ?? 1,
        'sensorOrientation': sensorOrientation,
        'coinConfThreshold': resolvedCoinConf,
        'banknoteConfThreshold': resolvedNoteConf,
        'iouThreshold': iouThreshold,
      });

      if (res == null) {
        return CurrencyInferenceResult(
          detections: const [],
          totalValue: 0,
          imageWidth: cameraImage.width,
          imageHeight: cameraImage.height,
        );
      }

      return _parseInferenceResult(res, cameraImage.width, cameraImage.height);
    } catch (e, stackTrace) {
      debugPrint('[CURRENCY-SERVICE] Live camera frame inference error: $e');
      debugPrint('$stackTrace');
      return CurrencyInferenceResult(
        detections: const [],
        totalValue: 0,
        imageWidth: cameraImage.width,
        imageHeight: cameraImage.height,
      );
    }
  }

  CurrencyInferenceResult _parseInferenceResult(
    Map<dynamic, dynamic> res,
    int fallbackWidth,
    int fallbackHeight,
  ) {
    final int imageWidth = (res['imageWidth'] as num?)?.toInt() ?? fallbackWidth;
    final int imageHeight = (res['imageHeight'] as num?)?.toInt() ?? fallbackHeight;
    final int totalValue = (res['totalValue'] as num?)?.toInt() ?? 0;
    final rawDetections = (res['detections'] as List<dynamic>?) ?? [];

    final List<CurrencyDetection> detections = [];
    for (final item in rawDetections) {
      if (item is Map) {
        final int classId = (item['classId'] as num?)?.toInt() ?? 0;
        final String denomination = item['denomination']?.toString() ?? '';
        final int value = (item['value'] as num?)?.toInt() ?? 0;
        final double confidence = (item['confidence'] as num?)?.toDouble() ?? 0.0;
        final boxList = (item['box'] as List<dynamic>?) ?? [0.0, 0.0, 0.0, 0.0];
        final double x1 = boxList.isNotEmpty ? (boxList[0] as num).toDouble() : 0.0;
        final double y1 = boxList.length > 1 ? (boxList[1] as num).toDouble() : 0.0;
        final double x2 = boxList.length > 2 ? (boxList[2] as num).toDouble() : 0.0;
        final double y2 = boxList.length > 3 ? (boxList[3] as num).toDouble() : 0.0;
        final reasonsRaw = (item['uncertaintyReasons'] as List<dynamic>?) ?? const [];

        detections.add(
          CurrencyDetection(
            classId: classId,
            denomination: denomination,
            value: value,
            confidence: confidence,
            x1: x1,
            y1: y1,
            x2: x2,
            y2: y2,
            type: item['type']?.toString() ?? '',
            top2ClassId: (item['top2ClassId'] as num?)?.toInt() ?? -1,
            top2ClassName: item['top2ClassName']?.toString() ?? '',
            top2Confidence: (item['top2Confidence'] as num?)?.toDouble() ?? 0.0,
            classMargin: (item['classMargin'] as num?)?.toDouble() ?? 1.0,
            suppressedConflictCount: (item['suppressedConflictCount'] as num?)?.toInt() ?? 0,
            suppressedConflictClassId: (item['suppressedConflictClassId'] as num?)?.toInt() ?? -1,
            suppressedConflictClassName: item['suppressedConflictClassName']?.toString() ?? '',
            suppressedConflictConfidence: (item['suppressedConflictConfidence'] as num?)?.toDouble() ?? 0.0,
            interBoxMaxIoU: (item['interBoxMaxIoU'] as num?)?.toDouble() ?? 0.0,
            interBoxMaxIoMin: (item['interBoxMaxIoMin'] as num?)?.toDouble() ?? 0.0,
            confirmationState: parseConfirmationState(item['confirmationState']?.toString()),
            uncertaintyReasons: reasonsRaw.map((e) => e.toString()).toList(),
          ),
        );
      }
    }

    final frameReasonsRaw = (res['uncertaintyReasons'] as List<dynamic>?) ?? const [];

    return CurrencyInferenceResult(
      detections: detections,
      totalValue: totalValue,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      isCandidateMode: (res['isCandidateMode'] as bool?) ?? _isCandidateMode,
      totalStatus: res['totalStatus']?.toString() ?? 'confirmed',
      isTotalConfirmed: (res['isTotalConfirmed'] as bool?) ?? true,
      confirmedValue: (res['confirmedValue'] as num?)?.toInt() ?? totalValue,
      detectedSumValue: (res['detectedSumValue'] as num?)?.toInt() ?? totalValue,
      confirmedItemsValue: (res['confirmedItemsValue'] as num?)?.toInt() ?? totalValue,
      confirmedNoteCount: (res['confirmedNoteCount'] as num?)?.toInt() ?? 0,
      tentativeNoteCount: (res['tentativeNoteCount'] as num?)?.toInt() ?? 0,
      conflictingNoteCount: (res['conflictingNoteCount'] as num?)?.toInt() ?? 0,
      uncertaintyReasons: frameReasonsRaw.map((e) => e.toString()).toList(),
      preprocessTimeMs: (res['preprocessTimeMs'] as num?)?.toDouble() ?? 0.0,
      coinInferenceTimeMs: (res['coinInferenceTimeMs'] as num?)?.toDouble() ?? 0.0,
      banknoteInferenceTimeMs: (res['banknoteInferenceTimeMs'] as num?)?.toDouble() ?? 0.0,
      totalTimeMs: (res['totalTimeMs'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Future<CurrencyInferenceResult> testImageInference() async {
    final imageData = await rootBundle.load(
      'assets/test_images/test_currency_valid.jpg',
    );
    return runImageInference(
      imageData.buffer.asUint8List(),
      source: 'Static test image',
    );
  }

  Future<void> dispose() async {
    if (!_isLoaded) return;
    try {
      await _nativeChannel.invokeMethod('dispose');
    } catch (e) {
      debugPrint('[CURRENCY-SERVICE] Dispose error: $e');
    }
    _isLoaded = false;
  }
}
