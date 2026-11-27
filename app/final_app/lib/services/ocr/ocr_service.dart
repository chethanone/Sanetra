import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'ocr_detection.dart';
import 'ocr_recognition.dart';
import 'ocr_postprocessing.dart';
import 'ocr_result.dart';

export 'ocr_result.dart';
export 'ocr_detection.dart';
export 'ocr_recognition.dart';
export 'ocr_preprocessing.dart';
export 'ocr_postprocessing.dart';
export 'ocr_symbol_normalizer.dart';

class OcrService {
  final OcrDetectionService _detectionService = OcrDetectionService();
  final OcrRecognitionService _recognitionService = OcrRecognitionService();

  bool _isInitialized = false;
  bool get isLoaded => _detectionService.isLoaded && _recognitionService.isLoaded;

  /// Initialize and load both detection and recognition models.
  Future<void> loadModels() async {
    if (_isInitialized && isLoaded) return;

    final stopwatch = Stopwatch()..start();
    debugPrint('[OCR-SERVICE] Initializing PP-OCRv5 Mobile pipeline...');

    await _detectionService.loadModel();
    await _recognitionService.loadModel();

    _isInitialized = true;
    stopwatch.stop();
    debugPrint(
      '[OCR-SERVICE] All OCR models successfully initialized in ${stopwatch.elapsedMilliseconds}ms.',
    );
  }

  /// Run end-to-end OCR pipeline on raw JPEG/PNG image bytes.
  ///
  /// Steps:
  /// 1. Decode & EXIF orientation normalization
  /// 2. DB Text Detection
  /// 3. Perspective Warp per text region
  /// 4. CTC Text Recognition
  /// 5. Reading Order Sorting (top-to-bottom, left-to-right)
  Future<OcrResult> processImage(
    Uint8List imageBytes, {
    double threshold = 0.30,
    double boxThreshold = 0.60,
    double unclipRatio = 1.50,
    String? preferredLanguage,
  }) async {
    if (!isLoaded) {
      await loadModels();
    }

    final stopwatch = Stopwatch()..start();

    try {
      // 1. Decode Image & Normalize EXIF Orientation
      final rawImage = img.decodeImage(imageBytes);
      if (rawImage == null) {
        return OcrResult.failure('Could not decode camera image.');
      }
      img.Image image = img.bakeOrientation(rawImage);

      // Downscale high-resolution camera photos (e.g. 12MP/50MP) to a max side of 1600.
      // This preserves full OCR clarity while dramatically accelerating inference speed.
      final int maxSide = math.max(image.width, image.height);
      if (maxSide > 1600) {
        final double scale = 1600.0 / maxSide.toDouble();
        image = img.copyResize(
          image,
          width: (image.width * scale).round(),
          height: (image.height * scale).round(),
          interpolation: img.Interpolation.linear,
        );
      }

      // 2. Text Detection
      final detSw = Stopwatch()..start();
      final polygons = await _detectionService.detectText(
        image,
        threshold: threshold,
        boxThreshold: boxThreshold,
        unclipRatio: unclipRatio,
      );
      detSw.stop();
      debugPrint(
        '[OCR-PERF] Detection: ${detSw.elapsedMilliseconds}ms, regions=${polygons.length}',
      );

      if (polygons.isEmpty) {
        stopwatch.stop();
        return OcrResult.empty(
          durationMs: stopwatch.elapsedMilliseconds,
          imageWidth: image.width,
          imageHeight: image.height,
        );
      }

      // 3 & 4. Perspective Correction & Recognition for each text candidate
      final recSw = Stopwatch()..start();
      final recognizedLines = <OcrLineResult>[];
      int candidateIndex = 0;

      for (final polygon in polygons) {
        final line = await _recognitionService.recognizeRegion(
          originalImage: image,
          polygon: polygon,
          lineIndex: candidateIndex++,
          preferredLanguage: preferredLanguage,
        );

        if (line != null && line.text.trim().isNotEmpty) {
          recognizedLines.add(line);
        }
      }
      recSw.stop();
      debugPrint(
        '[OCR-PERF] Recognition (${recognizedLines.length}/${polygons.length} lines): ${recSw.elapsedMilliseconds}ms',
      );

      if (recognizedLines.isEmpty) {
        stopwatch.stop();
        return OcrResult.empty(
          durationMs: stopwatch.elapsedMilliseconds,
          imageWidth: image.width,
          imageHeight: image.height,
        );
      }

      // 5. Intelligent Scene Analysis & Natural Reading Order Sorting
      final orderSw = Stopwatch()..start();
      final analyzed = OcrPostprocessing.analyzeSceneAndOrder(
        recognizedLines,
        imageWidth: image.width,
        imageHeight: image.height,
      );
      final orderedLines = analyzed.lines;
      orderSw.stop();

      // 6. Build combined text
      final fullText = orderedLines.map((l) => l.text).join('\n');

      stopwatch.stop();
      debugPrint(
        '[OCR-PROFILE] regions=${polygons.length} recognized=${orderedLines.length} '
        'recMs=${recSw.elapsedMilliseconds} readingOrderMs=${orderSw.elapsedMilliseconds} '
        'totalMs=${stopwatch.elapsedMilliseconds}',
      );
      if (analyzed.sceneSummary.isNotEmpty) {
        debugPrint('[OCR-SCENE] ${analyzed.sceneSummary}');
      }
      debugPrint('[OCR-SERVICE] OCR completed in ${stopwatch.elapsedMilliseconds}ms.');
      debugPrint('[OCR-SERVICE] Recognized ${orderedLines.length} line(s):\n$fullText');

      return OcrResult(
        lines: orderedLines,
        fullText: fullText,
        durationMs: stopwatch.elapsedMilliseconds,
        imageWidth: image.width,
        imageHeight: image.height,
        isSuccess: true,
        sceneSummary: analyzed.sceneSummary,
      );
    } catch (e, stackTrace) {
      stopwatch.stop();
      debugPrint('[OCR-SERVICE] OCR Processing FAILED: $e');
      debugPrint('$stackTrace');
      return OcrResult.failure(e.toString());
    }
  }

  /// Free all resources and sessions.
  Future<void> dispose() async {
    _isInitialized = false;
    await _detectionService.dispose();
    await _recognitionService.dispose();
  }
}
