import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'ocr_preprocessing.dart';
import 'ocr_postprocessing.dart';
import 'ocr_result.dart';
import 'ocr_model_loader.dart';

class OcrDetectionService {
  final OnnxRuntime _runtime = OnnxRuntime();
  OrtSession? _session;

  bool get isLoaded => _session != null;

  /// Load PP-OCRv5 Mobile detection ONNX model from Flutter assets.
  Future<void> loadModel() async {
    if (_session != null) return;

    try {
      debugPrint('[OCR-DET] Loading detection ONNX model...');
      _session = await loadOcrSessionFromAsset(
        _runtime,
        'assets/models/ocr/detection/detector.onnx',
      );
      debugPrint('[OCR-DET] Detection model loaded successfully.');
      debugPrint('[OCR-DET] Inputs: ${_session!.inputNames}, Outputs: ${_session!.outputNames}');
    } catch (e, stackTrace) {
      debugPrint('[OCR-DET] FAILED to load detection model: $e');
      debugPrint('$stackTrace');
      await _session?.close();
      _session = null;
      rethrow;
    }
  }

  /// Run text detection on an image and return detected text region polygons.
  Future<List<OcrPolygon>> detectText(
    img.Image image, {
    double threshold = 0.30,
    double boxThreshold = 0.60,
    double unclipRatio = 1.50,
  }) async {
    if (_session == null) {
      throw StateError('OCR Detection model is not loaded.');
    }

    // 1. Preprocess image
    final prep = OcrPreprocessing.prepareDetectionTensor(image);

    OrtValue? inputTensor;
    Map<String, OrtValue>? outputs;

    try {
      // 2. Create input tensor [1, 3, targetH, targetW]
      inputTensor = await OrtValue.fromList(
        prep.tensorData,
        [1, 3, prep.targetHeight, prep.targetWidth],
      );

      // 3. Run detection model
      outputs = await _session!.run({
        'x': inputTensor,
      });

      final outputTensor = outputs['fetch_name_0'];
      if (outputTensor == null) {
        throw StateError('Detection model did not return "fetch_name_0".');
      }

      final rawOutputList = await outputTensor.asFlattenedList();
      final predMap = Float32List.fromList(
        rawOutputList.map((e) => (e as num).toDouble()).toList(),
      );

      // 4. DB Postprocessing: Extract text polygons
      final polygons = OcrPostprocessing.extractTextPolygons(
        predMap: predMap,
        targetWidth: prep.targetWidth,
        targetHeight: prep.targetHeight,
        scaleX: prep.scaleX,
        scaleY: prep.scaleY,
        origWidth: prep.originalWidth,
        origHeight: prep.originalHeight,
        threshold: threshold,
        boxThreshold: boxThreshold,
        unclipRatio: unclipRatio,
      );

      debugPrint('[OCR-DET] Found ${polygons.length} text candidates.');
      return polygons;
    } finally {
      if (inputTensor != null) {
        await inputTensor.dispose();
      }
      if (outputs != null) {
        for (final tensor in outputs.values) {
          await tensor.dispose();
        }
      }
    }
  }

  /// Close session and free native resources.
  Future<void> dispose() async {
    await _session?.close();
    _session = null;
  }
}
