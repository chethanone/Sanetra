import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'ocr_preprocessing.dart';
import 'ocr_postprocessing.dart';
import 'ocr_result.dart';
import 'ocr_model_loader.dart';
import 'ocr_symbol_normalizer.dart';

class _DecodedResult {
  final String text;
  final double confidence;
  final double minCharConfidence;
  final String language;
  final double nativeScriptRatio;
  final int nativeCharCount;
  final bool hasUncoveredInkGap;

  const _DecodedResult({
    required this.text,
    required this.confidence,
    this.minCharConfidence = 0.0,
    required this.language,
    required this.nativeScriptRatio,
    required this.nativeCharCount,
    this.hasUncoveredInkGap = false,
  });
}

class OcrRecognitionService {
  final OnnxRuntime _runtime = OnnxRuntime();

  // Multi-script recognition sessions
  OrtSession? _sessionKa;
  List<String> _dictKa = const [];

  OrtSession? _sessionKaScene;
  List<String> _dictKaScene = const [];

  OrtSession? _sessionEn;
  List<String> _dictEn = const [];

  OrtSession? _sessionHi;
  List<String> _dictHi = const [];

  bool get isLoaded =>
      (_sessionEn != null ||
          _sessionKa != null ||
          _sessionKaScene != null ||
          _sessionHi != null);

  /// Load PP-OCR recognition models: English/Latin (en), Kannada (ka), and Hindi/Devanagari (hi).
  Future<void> loadModel() async {
    if (isLoaded) return;

    // 1. Load English / Latin Recognition Model & Dictionary (Primary)
    try {
      final swEn = Stopwatch()..start();
      debugPrint('[OCR-REC] Loading Latin character dictionary...');
      final enJson = await rootBundle.loadString(
        'assets/models/ocr/recognition/character_dict.json',
      );
      _dictEn = (jsonDecode(enJson) as List).map((e) => e.toString()).toList();
      _sessionEn = await loadOcrSessionFromAsset(
        _runtime,
        'assets/models/ocr/recognition/recognizer.onnx',
      );
      await verifyRecognizerCompatibility(
        _sessionEn!,
        _dictEn,
        inputHeight: 48,
        inputWidth: 320,
        expectedOffset: 2,
        label: 'en-IN',
      );
      swEn.stop();
      debugPrint(
        '[OCR-REC] English recognizer loaded (${_dictEn.length} chars) in ${swEn.elapsedMilliseconds}ms.',
      );
    } catch (e) {
      debugPrint('[OCR-REC] ERROR: English model loading failed: $e');
    }

    // 2. Load Kannada Recognition Model & Dictionary (Phase 5.5 CRNN, 48px height)
    try {
      final swKa = Stopwatch()..start();
      debugPrint('[OCR-REC] Loading Kannada character dictionary...');
      final kaJson = await rootBundle.loadString(
        'assets/models/ocr/kannada/character_dict_ka.json',
      );
      _dictKa = (jsonDecode(kaJson) as List).map((e) => e.toString()).toList();
      _sessionKa = await loadOcrSessionFromAsset(
        _runtime,
        'assets/models/ocr/kannada/recognizer_ka.onnx',
      );
      await verifyRecognizerCompatibility(
        _sessionKa!,
        _dictKa,
        inputHeight: 48,
        inputWidth: 320,
        expectedOffset: 2,
        label: 'kn-IN',
      );
      swKa.stop();
      debugPrint(
        '[OCR-REC] Kannada recognizer loaded (${_dictKa.length} chars) in ${swKa.elapsedMilliseconds}ms.',
      );
    } catch (e) {
      debugPrint('[OCR-REC] ERROR: Kannada model loading failed: $e');
    }

    // 2b. Load Kannada Scene Fallback Recognizer (Arjuna SVTRv2 INT8, 32px height)
    try {
      final swKaScene = Stopwatch()..start();
      final kaSceneJson = await rootBundle.loadString(
        'assets/models/ocr/kannada/charset_ka_scene.json',
      );
      _dictKaScene = (jsonDecode(kaSceneJson) as List)
          .map((e) => e.toString())
          .toList();
      _sessionKaScene = await loadOcrSessionFromAsset(
        _runtime,
        'assets/models/ocr/kannada/recognizer_ka_scene.onnx',
      );
      await verifyRecognizerCompatibility(
        _sessionKaScene!,
        _dictKaScene,
        inputHeight: 32,
        inputWidth: 64,
        expectedOffset: 1,
        label: 'kn-IN-scene',
      );
      swKaScene.stop();
      debugPrint(
        '[OCR-REC] Kannada scene fallback loaded (${_dictKaScene.length} chars) in ${swKaScene.elapsedMilliseconds}ms.',
      );
    } catch (e) {
      debugPrint('[OCR-REC] WARN: Kannada scene fallback loading failed: $e');
    }

    // 3. Load Devanagari (Hindi) Recognition Model & Dictionary
    try {
      final swHi = Stopwatch()..start();
      debugPrint('[OCR-REC] Loading Devanagari character dictionary...');
      final hiJson = await rootBundle.loadString(
        'assets/models/ocr/devanagari/character_dict_hi.json',
      );
      _dictHi = (jsonDecode(hiJson) as List).map((e) => e.toString()).toList();
      _sessionHi = await loadOcrSessionFromAsset(
        _runtime,
        'assets/models/ocr/devanagari/recognizer_hi.onnx',
      );
      await verifyRecognizerCompatibility(
        _sessionHi!,
        _dictHi,
        inputHeight: 48,
        inputWidth: 320,
        expectedOffset: 2,
        label: 'hi-IN',
      );
      swHi.stop();
      debugPrint(
        '[OCR-REC] Hindi recognizer loaded (${_dictHi.length} chars) in ${swHi.elapsedMilliseconds}ms.',
      );
    } catch (e) {
      debugPrint('[OCR-REC] ERROR: Hindi model loading failed: $e');
    }
  }

  /// Compute fraction of non-whitespace characters belonging to the target script.
  static ({double ratio, int count}) _measureNativeScript(
    String text,
    String language,
  ) {
    final compact = text.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty) return (ratio: 0.0, count: 0);

    int nativeCount = 0;
    int totalCount = 0;
    for (final rune in compact.runes) {
      totalCount++;
      if (language == 'kn-IN') {
        if (rune >= 0x0C80 && rune <= 0x0CFF) {
          nativeCount++;
        } else if ((rune >= 0x0030 && rune <= 0x0039) ||
            OcrSymbolNormalizer.isSymbolRune(rune)) {
          nativeCount++;
        }
      } else if (language == 'hi-IN') {
        if (rune >= 0x0900 && rune <= 0x097F) {
          nativeCount++;
        } else if ((rune >= 0x0030 && rune <= 0x0039) ||
            OcrSymbolNormalizer.isSymbolRune(rune)) {
          nativeCount++;
        }
      } else {
        // English / Latin + digits + common symbols
        if ((rune >= 0x0021 && rune <= 0x007E) ||
            OcrSymbolNormalizer.isSymbolRune(rune)) {
          nativeCount++;
        }
      }
    }
    return (
      ratio: totalCount > 0 ? nativeCount / totalCount : 0.0,
      count: nativeCount,
    );
  }

  /// Compute per-column ink presence on a cropped line image using border-estimated background luma.
  @visibleForTesting
  static List<bool> computeInkColumns(img.Image crop) {
    final w = crop.width;
    final h = crop.height;
    if (w <= 0 || h <= 0) return const [];

    double bgSum = 0.0;
    int bgCount = 0;
    for (int x = 0; x < w; x++) {
      for (final y in [0, h - 1]) {
        final px = crop.getPixel(x, y);
        bgSum += 0.299 * px.r + 0.587 * px.g + 0.114 * px.b;
        bgCount++;
      }
    }
    final bgLuma = bgCount > 0 ? bgSum / bgCount : 255.0;

    final yStart = h > 6 ? 1 : 0;
    final yEnd = h > 6 ? h - 1 : h;
    final cols = List<bool>.filled(w, false);
    for (int x = 0; x < w; x++) {
      for (int y = yStart; y < yEnd; y++) {
        final px = crop.getPixel(x, y);
        final luma = 0.299 * px.r + 0.587 * px.g + 0.114 * px.b;
        if ((luma - bgLuma).abs() > 35.0) {
          cols[x] = true;
          break;
        }
      }
    }
    return cols;
  }

  /// Extract horizontal word chunks [startX, endX] without splitting combining characters
  /// or grapheme clusters (only splits on whitespace gaps >= max(4, 0.18 * height)).
  @visibleForTesting
  static List<({int startX, int endX})> extractWordChunks(
    img.Image crop, {
    List<bool>? inkColumns,
  }) {
    final cols = inkColumns ?? computeInkColumns(crop);
    if (cols.isEmpty) return const [];

    final minSpaceGap = math.max(4, (crop.height * 0.18).round());
    final rawRuns = <({int startX, int endX})>[];
    int? runStart;
    for (int x = 0; x < cols.length; x++) {
      if (cols[x]) {
        runStart ??= x;
      } else if (runStart != null) {
        rawRuns.add((startX: runStart, endX: x - 1));
        runStart = null;
      }
    }
    if (runStart != null) {
      rawRuns.add((startX: runStart, endX: cols.length - 1));
    }
    if (rawRuns.isEmpty) return const [];

    final merged = <({int startX, int endX})>[rawRuns.first];
    for (int i = 1; i < rawRuns.length; i++) {
      final prev = merged.last;
      final cur = rawRuns[i];
      if (cur.startX - prev.endX - 1 < minSpaceGap) {
        merged[merged.length - 1] = (startX: prev.startX, endX: cur.endX);
      } else {
        merged.add(cur);
      }
    }
    return merged;
  }

  /// Merge adjacent word/phrase segments sharing the same language while preserving order.
  @visibleForTesting
  static List<OcrTextSegment> mergeAdjacentSegments(
    List<OcrTextSegment> rawSegments,
  ) {
    if (rawSegments.isEmpty) return const [];
    final merged = <OcrTextSegment>[];
    for (final seg in rawSegments) {
      final clean = seg.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (clean.isEmpty) continue;
      if (merged.isNotEmpty && merged.last.language == seg.language) {
        final prev = merged.last;
        final combinedText = '${prev.text} $clean';
        merged[merged.length - 1] = OcrTextSegment(
          text: combinedText,
          language: prev.language,
          confidence: (prev.confidence + seg.confidence) / 2.0,
          isLanguageUncertain: prev.isLanguageUncertain || seg.isLanguageUncertain,
        );
      } else {
        merged.add(
          OcrTextSegment(
            text: clean,
            language: seg.language,
            confidence: seg.confidence,
            isLanguageUncertain: seg.isLanguageUncertain,
          ),
        );
      }
    }
    return merged;
  }

  Future<_DecodedResult?> _runRecognizer(
    OrtSession? session,
    List<String> dict,
    OrtValue inputTensor,
    String language, {
    List<bool>? inkColumns,
    int? targetWidth,
    int? tensorWidth,
    int padLr = 4,
    bool hasTrailingSpaceClass = true,
  }) async {
    if (session == null || dict.isEmpty) return null;
    final inputName = session.inputNames.isNotEmpty ? session.inputNames.first : 'x';
    final outputs = await session.run({inputName: inputTensor});
    final outTensor = outputs.isNotEmpty
        ? (outputs['fetch_name_0'] ?? outputs.values.first)
        : null;
    if (outTensor == null) {
      for (final t in outputs.values) {
        await t.dispose();
      }
      return null;
    }
    final decoded = await _decodeOutput(
      outTensor,
      dict,
      language,
      inkColumns: inkColumns,
      targetWidth: targetWidth,
      tensorWidth: tensorWidth,
      padLr: padLr,
      hasTrailingSpaceClass: hasTrailingSpaceClass,
    );
    for (final t in outputs.values) {
      await t.dispose();
    }
    return decoded;
  }

  /// Clean up common CTC artifacts in Kannada script output:
  /// - Removes orphaned combining marks at word starts (e.g. ಾ, ಿ, ್ without a base consonant)
  /// - Collapses duplicate viramas (e.g. ್್ -> ್)
  /// - Normalizes combining sequences
  static String cleanKannadaUnicode(String text) {
    if (text.isEmpty) return text;
    var cleaned = text.replaceAll(RegExp(r'\u0CCD{2,}'), '\u0CCD');
    cleaned = cleaned.replaceAllMapped(
      RegExp(r'(^|\s)[\u0CBE-\u0CD6\u0CCD]+'),
      (m) => m[1] ?? '',
    );
    cleaned = cleaned.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return cleaned;
  }

  Future<_DecodedResult?> _runKannadaRecognizer(
    img.Image crop, {
    List<bool>? inkColumns,
    bool allowSceneFallback = true,
    bool isHandwriting = false,
  }) async {
    _DecodedResult? tier1;
    if (_sessionKa != null && _dictKa.isNotEmpty && !isHandwriting) {
      final prepKa = OcrPreprocessing.prepareRecognitionTensor(crop);
      OrtValue? kaTensor;
      try {
        kaTensor = await OrtValue.fromList(
          prepKa.tensorData,
          [1, 3, prepKa.targetHeight, prepKa.tensorWidth],
        );
        tier1 = await _runRecognizer(
          _sessionKa,
          _dictKa,
          kaTensor,
          'kn-IN',
          inkColumns: inkColumns,
          targetWidth: prepKa.targetWidth,
          tensorWidth: prepKa.tensorWidth,
          padLr: 4,
          hasTrailingSpaceClass: true,
        );
      } finally {
        if (kaTensor != null) await kaTensor.dispose();
      }
    }

    // Always run Arjuna SVTRv2 (tier2) if tier1 is null, low confidence, handwriting, or has gaps
    final bool needsSceneFallback = allowSceneFallback &&
        _sessionKaScene != null &&
        _dictKaScene.isNotEmpty &&
        (tier1 == null ||
            isHandwriting ||
            tier1.confidence < 0.88 ||
            tier1.nativeCharCount < 2 ||
            tier1.hasUncoveredInkGap);
    if (!needsSceneFallback) {
      return tier1;
    }

    final tier2 = await _runKannadaSceneFallback(crop, inkColumns: inkColumns);
    if (tier2 == null) return tier1;
    if (tier1 == null) return tier2;

    double kaScore(_DecodedResult r) {
      final nativeBonus = math.min(0.20, r.nativeCharCount * 0.04);
      final scriptBonus = r.nativeScriptRatio * 0.15;
      final gapPenalty = r.hasUncoveredInkGap ? 0.10 : 0.0;
      return r.confidence + scriptBonus + nativeBonus - gapPenalty;
    }

    if (kaScore(tier2) >= kaScore(tier1)) {
      debugPrint(
        '[OCR-REC-SCENE] Tier2 (Arjuna SVTRv2) selected "${tier2.text}"(${(tier2.confidence * 100).toStringAsFixed(0)}%) '
        'over Tier1 "${tier1.text}"(${(tier1.confidence * 100).toStringAsFixed(0)}%)',
      );
      return tier2;
    }
    return tier1;
  }

  Future<_DecodedResult?> _runKannadaSceneFallback(
    img.Image crop, {
    List<bool>? inkColumns,
  }) async {
    if (_sessionKaScene == null || _dictKaScene.isEmpty) return null;
    final prep = OcrPreprocessing.prepareArjunaKannadaTensor(crop);
    OrtValue? tensor;
    try {
      tensor = await OrtValue.fromList(
        prep.tensorData,
        [1, 3, prep.targetHeight, prep.tensorWidth],
      );
      return await _runRecognizer(
        _sessionKaScene,
        _dictKaScene,
        tensor,
        'kn-IN',
        inkColumns: inkColumns,
        targetWidth: prep.targetWidth,
        tensorWidth: prep.tensorWidth,
        padLr: 0,
        hasTrailingSpaceClass: false,
      );
    } finally {
      if (tensor != null) await tensor.dispose();
    }
  }

  /// Recognize text in a cropped polygon region using perspective correction and
  /// measurable multi-script CTC selection (English, Kannada, Hindi).
  ///
  /// When [preferredLanguage] is provided (`en-IN`, `kn-IN`, or `hi-IN`), that
  /// script's recognizer runs first with a high-confidence fast-path exit to cut
  /// latency on single-script pages, while still falling back to all scripts on
  /// mixed-language or uncertain regions.
  Future<OcrLineResult?> recognizeRegion({
    required img.Image originalImage,
    required OcrPolygon polygon,
    int lineIndex = 0,
    String? preferredLanguage,
  }) async {
    if (!isLoaded) {
      throw StateError('OCR Recognition models are not loaded.');
    }

    // 1. Curved centerline or perspective crop (without blind 90-deg rotation)
    final rawCrop = OcrPostprocessing.extractRegionCrop(
      originalImage: originalImage,
      polygon: polygon,
      allowAutoVerticalRotate: false,
    );

    if (rawCrop == null ||
        math.max(rawCrop.width, rawCrop.height) < 12 ||
        math.min(rawCrop.width, rawCrop.height) < 8) {
      return null;
    }

    // 2. Per-region orientation selection (90 vs 270 for vertical; 0 vs 180 when uncertain)
    double scoreCandidate(({
      _DecodedResult best,
      _DecodedResult? primary,
      _DecodedResult? resEn,
      _DecodedResult? resKa,
      _DecodedResult? resHi,
      String selectedText,
      String selectedLang,
      bool uncertain,
    })? res) {
      if (res == null || res.selectedText.trim().isEmpty) return -1.0;
      final lenBonus = math.min(res.selectedText.trim().length, 8) * 0.012;
      final scriptBonus = res.best.nativeScriptRatio * 0.08;
      return res.best.confidence + scriptBonus + lenBonus;
    }

    img.Image crop = rawCrop;
    int orientationDegrees = 0;
    List<bool> inkCols;
    ({
      _DecodedResult best,
      _DecodedResult? primary,
      _DecodedResult? resEn,
      _DecodedResult? resKa,
      _DecodedResult? resHi,
      String selectedText,
      String selectedLang,
      bool uncertain,
    })? single;

    if (rawCrop.height > rawCrop.width * 1.15) {
      final crop90 = img.copyRotate(rawCrop, angle: 90);
      final crop270 = img.copyRotate(rawCrop, angle: 270);
      final ink90 = computeInkColumns(crop90);
      final ink270 = computeInkColumns(crop270);
      final res90 = await _recognizeCropTensor(
        crop: crop90,
        inkCols: ink90,
        preferredLanguage: preferredLanguage,
        allowUncoveredGapFastPath: false,
      );
      final res270 = await _recognizeCropTensor(
        crop: crop270,
        inkCols: ink270,
        preferredLanguage: preferredLanguage,
        allowUncoveredGapFastPath: false,
      );
      if (scoreCandidate(res270) > scoreCandidate(res90)) {
        crop = crop270;
        inkCols = ink270;
        single = res270;
        orientationDegrees = 270;
      } else {
        crop = crop90;
        inkCols = ink90;
        single = res90;
        orientationDegrees = 90;
      }
    } else {
      inkCols = computeInkColumns(rawCrop);
      single = await _recognizeCropTensor(
        crop: rawCrop,
        inkCols: inkCols,
        preferredLanguage: preferredLanguage,
        allowUncoveredGapFastPath: false,
      );

      final bool needs180Check = single == null ||
          single.best.confidence < 0.78 ||
          single.selectedText.trim().length <= 2;
      if (needs180Check) {
        final crop180 = img.copyRotate(rawCrop, angle: 180);
        final ink180 = computeInkColumns(crop180);
        final res180 = await _recognizeCropTensor(
          crop: crop180,
          inkCols: ink180,
          preferredLanguage: preferredLanguage,
          allowUncoveredGapFastPath: false,
        );
        final s0 = scoreCandidate(single);
        final s180 = scoreCandidate(res180);
        if (res180 != null && (single == null || s180 > s0 + 0.06)) {
          crop = crop180;
          inkCols = ink180;
          single = res180;
          orientationDegrees = 180;
        }
      }

      // For curved text: also check horizontally flipped unwrapping in case curve was traced in reverse
      if (polygon.isCurved && (single == null || single.best.confidence < 0.78)) {
        final cropFlipped = img.copyFlip(rawCrop, direction: img.FlipDirection.horizontal);
        final inkFlipped = computeInkColumns(cropFlipped);
        final resFlipped = await _recognizeCropTensor(
          crop: cropFlipped,
          inkCols: inkFlipped,
          preferredLanguage: preferredLanguage,
          allowUncoveredGapFastPath: false,
        );
        final currentScore = scoreCandidate(single);
        final sFlipped = scoreCandidate(resFlipped);
        if (resFlipped != null && (single == null || sFlipped > currentScore + 0.06)) {
          crop = cropFlipped;
          inkCols = inkFlipped;
          single = resFlipped;
          orientationDegrees = 0;
        }
      }

      // Handwriting & low-contrast rescue retry
      final bool isKannadaContext = preferredLanguage == 'kn-IN' ||
          (single?.resKa != null &&
              ((single!.resKa!.nativeCharCount >= 1) ||
                  single!.resKa!.confidence >= 0.40));

      final bool needsHandwritingRescue = single == null ||
          single.best.confidence < 0.78 ||
          single.selectedText.trim().length <= 2 ||
          (isKannadaContext &&
              (single.resKa == null || single.resKa!.confidence < 0.82));

      if (needsHandwritingRescue) {
        final img.Image transformedCrop;
        if (isKannadaContext) {
          // Use specialized Kannada local adaptive enhancement, NO destructive shear on circular loops!
          transformedCrop = OcrPreprocessing.enhanceCropForKannadaHandwriting(crop);
        } else {
          final enhanced = OcrPreprocessing.enhanceCropForHandwriting(crop);
          transformedCrop = OcrPreprocessing.deSlantCrop(enhanced);
        }

        final inkHw = computeInkColumns(transformedCrop);
        final resHw = await _recognizeCropTensor(
          crop: transformedCrop,
          inkCols: inkHw,
          preferredLanguage: preferredLanguage,
          allowUncoveredGapFastPath: false,
        );
        if (resHw != null &&
            (single == null || scoreCandidate(resHw) > scoreCandidate(single) + 0.03)) {
          crop = transformedCrop;
          inkCols = inkHw;
          single = resHw;
        }
      }
    }

    if (single == null) return null;

    final primaryRes = single.primary;
    final bool hasGap = primaryRes?.hasUncoveredInkGap ?? false;
    final bool multiScriptOverlap = (single.resEn != null &&
            single.resEn!.text.length >= 2 &&
            single.resEn!.confidence >= 0.65) &&
        (((single.resKa?.nativeCharCount ?? 0) >= 2 &&
                (single.resKa?.confidence ?? 0.0) >= 0.50) ||
            ((single.resHi?.nativeCharCount ?? 0) >= 2 &&
                (single.resHi?.confidence ?? 0.0) >= 0.50));

    if (hasGap || multiScriptOverlap) {
      final chunks = extractWordChunks(crop, inkColumns: inkCols);
      if (chunks.length >= 2) {
        final rawSegments = <OcrTextSegment>[];
        for (final chunk in chunks) {
          final x0 = math.max(0, chunk.startX - 2);
          final x1 = math.min(crop.width - 1, chunk.endX + 2);
          final cw = x1 - x0 + 1;
          if (cw < 4) continue;
          final subCrop = img.copyCrop(
            crop,
            x: x0,
            y: 0,
            width: cw,
            height: crop.height,
          );
          final subRes = await _recognizeCropTensor(
            crop: subCrop,
            inkCols: computeInkColumns(subCrop),
            preferredLanguage: preferredLanguage,
            allowUncoveredGapFastPath: true,
          );
          if (subRes != null && subRes.selectedText.isNotEmpty) {
            rawSegments.add(
              OcrTextSegment(
                text: subRes.selectedText,
                language: subRes.selectedLang,
                confidence: subRes.best.confidence.clamp(0.0, 1.0),
                isLanguageUncertain: subRes.uncertain,
              ),
            );
          }
        }

        final merged = mergeAdjacentSegments(rawSegments);
        if (merged.length >= 2 ||
            (merged.isNotEmpty &&
                merged.map((s) => s.text).join(' ').length >
                    single.selectedText.length + 2)) {
          final combinedText = merged.map((s) => s.text).join(' ').trim();
          final distinctLangs = merged.map((s) => s.language).toSet();
          final avgConf = merged.fold<double>(0.0, (a, b) => a + b.confidence) /
              merged.length;
          final anyUncertain = merged.any((s) => s.isLanguageUncertain);
          // Line-level language prefers Indic script if present, otherwise first segment
          final lineLang = distinctLangs.contains('kn-IN')
              ? 'kn-IN'
              : (distinctLangs.contains('hi-IN')
                  ? 'hi-IN'
                  : merged.first.language);

          debugPrint(
            '[OCR-REC-SEG] Line #$lineIndex: langs=${distinctLangs.toList()} '
            'segments=${merged.map((s) => '${s.language}:"${s.text}"').join(' | ')}',
          );

          return OcrLineResult(
            text: combinedText,
            confidence: avgConf.clamp(0.0, 1.0),
            polygon: polygon,
            lineIndex: lineIndex,
            language: lineLang,
            isLanguageUncertain: anyUncertain,
            segments: merged,
            geometryType: polygon.geometryType,
            orientationDegrees: orientationDegrees,
          );
        }
      }
    }

    debugPrint(
      '[OCR-REC] Line #$lineIndex: selected=${single.selectedLang} '
      'conf=${(single.best.confidence * 100).toStringAsFixed(1)}% '
      'uncertain=${single.uncertain} '
      '[en="${single.resEn?.text ?? ""}"(${((single.resEn?.confidence ?? 0) * 100).toStringAsFixed(0)}%), '
      'ka="${single.resKa?.text ?? ""}"(${((single.resKa?.confidence ?? 0) * 100).toStringAsFixed(0)}%), '
      'hi="${single.resHi?.text ?? ""}"(${((single.resHi?.confidence ?? 0) * 100).toStringAsFixed(0)}%)]',
    );

    return OcrLineResult(
      text: single.selectedText,
      confidence: single.best.confidence.clamp(0.0, 1.0),
      polygon: polygon,
      lineIndex: lineIndex,
      language: single.selectedLang,
      isLanguageUncertain: single.uncertain,
      geometryType: polygon.geometryType,
      orientationDegrees: orientationDegrees,
      segments: [
        OcrTextSegment(
          text: single.selectedText,
          language: single.selectedLang,
          confidence: single.best.confidence.clamp(0.0, 1.0),
          isLanguageUncertain: single.uncertain,
        ),
      ],
    );
  }

  Future<({
    _DecodedResult best,
    _DecodedResult? primary,
    _DecodedResult? resEn,
    _DecodedResult? resKa,
    _DecodedResult? resHi,
    String selectedText,
    String selectedLang,
    bool uncertain,
  })?> _recognizeCropTensor({
    required img.Image crop,
    required List<bool> inkCols,
    String? preferredLanguage,
    required bool allowUncoveredGapFastPath,
  }) async {
    final prep = OcrPreprocessing.prepareRecognitionTensor(crop);

    OrtValue? inputTensor;
    try {
      inputTensor = await OrtValue.fromList(
        prep.tensorData,
        [1, 3, prep.targetHeight, prep.tensorWidth],
      );

      _DecodedResult? resEn;
      _DecodedResult? resKa;
      _DecodedResult? resHi;
      _DecodedResult? primary;

      if (preferredLanguage == 'kn-IN') {
        resKa = await _runKannadaRecognizer(
          crop,
          inkColumns: inkCols,
        );
        primary = resKa;
        final bool highConfKa = resKa != null &&
            resKa.nativeCharCount >= 2 &&
            resKa.confidence >= 0.86 &&
            resKa.nativeScriptRatio >= 0.85 &&
            (allowUncoveredGapFastPath || !resKa.hasUncoveredInkGap);
        if (!highConfKa) {
          resEn = await _runRecognizer(
            _sessionEn,
            _dictEn,
            inputTensor,
            'en-IN',
            inkColumns: inkCols,
            targetWidth: prep.targetWidth,
            tensorWidth: prep.tensorWidth,
          );
          resHi = await _runRecognizer(
            _sessionHi,
            _dictHi,
            inputTensor,
            'hi-IN',
            inkColumns: inkCols,
            targetWidth: prep.targetWidth,
            tensorWidth: prep.tensorWidth,
          );
        }
      } else if (preferredLanguage == 'hi-IN') {
        resHi = await _runRecognizer(
          _sessionHi,
          _dictHi,
          inputTensor,
          'hi-IN',
          inkColumns: inkCols,
          targetWidth: prep.targetWidth,
          tensorWidth: prep.tensorWidth,
        );
        primary = resHi;
        final bool highConfHi = resHi != null &&
            resHi.nativeCharCount >= 2 &&
            resHi.confidence >= 0.86 &&
            resHi.nativeScriptRatio >= 0.85 &&
            (allowUncoveredGapFastPath || !resHi.hasUncoveredInkGap);
        if (!highConfHi) {
          resEn = await _runRecognizer(
            _sessionEn,
            _dictEn,
            inputTensor,
            'en-IN',
            inkColumns: inkCols,
            targetWidth: prep.targetWidth,
            tensorWidth: prep.tensorWidth,
          );
          resKa = await _runKannadaRecognizer(
            crop,
            inkColumns: inkCols,
            allowSceneFallback: true,
          );
        }
      } else {
        // Default / English-first fast-path
        resEn = await _runRecognizer(
          _sessionEn,
          _dictEn,
          inputTensor,
          'en-IN',
          inkColumns: inkCols,
          targetWidth: prep.targetWidth,
          tensorWidth: prep.tensorWidth,
        );
        primary = resEn;

        final bool highConfEnglish = resEn != null &&
            resEn.text.length >= 3 &&
            resEn.confidence >= 0.80 &&
            resEn.nativeScriptRatio >= 0.95 &&
            (allowUncoveredGapFastPath || !resEn.hasUncoveredInkGap);

        if (!highConfEnglish) {
          resKa = await _runKannadaRecognizer(
            crop,
            inkColumns: inkCols,
            allowSceneFallback: true,
          );
          resHi = await _runRecognizer(
            _sessionHi,
            _dictHi,
            inputTensor,
            'hi-IN',
            inkColumns: inkCols,
            targetWidth: prep.targetWidth,
            tensorWidth: prep.tensorWidth,
          );
        }
      }

      // Build eligible candidates:
      // Strong Latin candidate requires solid confidence and high script purity
      final bool strongLatinCandidate = resEn != null &&
          resEn.text.length >= 3 &&
          resEn.nativeScriptRatio >= 0.95 &&
          resEn.confidence >= 0.82 &&
          !resEn.hasUncoveredInkGap;

      final int minKaChars = 1;
      final double minKaRatio = (preferredLanguage == 'kn-IN') ? 0.35 : 0.50;
      final double minKaConf = strongLatinCandidate
          ? (resEn.confidence - 0.05)
          : ((preferredLanguage == 'kn-IN') ? 0.35 : 0.48);

      final int minHiChars = (preferredLanguage == 'hi-IN' && !strongLatinCandidate) ? 1 : 2;
      final double minHiRatio = (preferredLanguage == 'hi-IN') ? 0.50 : 0.65;
      final double minHiConf = strongLatinCandidate
          ? (resEn.confidence + 0.06)
          : (preferredLanguage == 'hi-IN' ? 0.40 : 0.55);

      final candidates = <_DecodedResult>[];
      if (resEn != null && resEn.text.isNotEmpty) {
        candidates.add(resEn);
      }
      if (resKa != null &&
          resKa.text.isNotEmpty &&
          resKa.nativeCharCount >= minKaChars &&
          resKa.nativeScriptRatio >= minKaRatio &&
          resKa.confidence >= minKaConf) {
        candidates.add(resKa);
      }
      if (resHi != null &&
          resHi.text.isNotEmpty &&
          resHi.nativeCharCount >= minHiChars &&
          resHi.nativeScriptRatio >= minHiRatio &&
          resHi.confidence >= minHiConf) {
        candidates.add(resHi);
      }

      if (candidates.isEmpty) {
        final fallback = [resEn, resKa, resHi]
            .whereType<_DecodedResult>()
            .where(
              (r) =>
                  r.text.isNotEmpty &&
                  (r.language == 'en-IN' ||
                      (r.nativeCharCount >= 1 && r.confidence >= 0.40)),
            )
            .toList()
          ..sort((a, b) => b.confidence.compareTo(a.confidence));
        if (fallback.isEmpty) return null;
        candidates.add(fallback.first);
      }

      // If an Indic recognizer produced native characters, prefer it over English
      // unless English is overwhelmingly confident and covers the ink without gaps.
      candidates.sort((a, b) => b.confidence.compareTo(a.confidence));
      var best = candidates.first;
      for (final c in candidates) {
        if (c.language == 'kn-IN' &&
            c.nativeCharCount >= 1 &&
            c.nativeScriptRatio >= 0.40 &&
            c.confidence >= 0.45 &&
            best.language == 'en-IN') {
          if (best.hasUncoveredInkGap ||
              best.confidence < c.confidence + 0.20 ||
              preferredLanguage == 'kn-IN') {
            best = c;
            break;
          }
        } else if (c.language == 'hi-IN' &&
            c.nativeCharCount >= 2 &&
            c.nativeScriptRatio >= 0.70 &&
            c.confidence >= 0.55 &&
            best.language == 'en-IN') {
          if (best.hasUncoveredInkGap ||
              best.confidence < c.confidence + 0.15 ||
              preferredLanguage == 'hi-IN') {
            best = c;
            break;
          }
        }
      }

      // Calibrated multi-signal quality control:
      // Reject garbled/low-confidence fragments rather than speaking noise.
      var text = best.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (best.language == 'kn-IN') {
        text = cleanKannadaUnicode(text);
      }
      final bool isSingleSymbol = text.runes.length == 1 &&
          OcrSymbolNormalizer.isSymbolRune(text.runes.first);
      if (text.isEmpty ||
          (text.length == 1 &&
              !RegExp(r'[0-9a-zA-Z\u0C80-\u0CFF\u0900-\u097F]')
                  .hasMatch(text) &&
              !isSingleSymbol) ||
          best.confidence < 0.45 ||
          (text.length < 4 && best.minCharConfidence < 0.20 && !isSingleSymbol) ||
          (crop.height < 12 && best.confidence < 0.65)) {
        debugPrint(
          '[OCR-QC] Rejected region: text="$text" conf=${best.confidence.toStringAsFixed(3)} '
          'minChar=${best.minCharConfidence.toStringAsFixed(3)} h=${crop.height}',
        );
        return null;
      }

      bool uncertain = best.confidence < 0.62 || best.minCharConfidence < 0.28;
      if (candidates.length >= 2 &&
          (best.confidence - candidates[1].confidence).abs() < 0.08) {
        if (best.language != 'en-IN' &&
            candidates[1].language == 'en-IN' &&
            best.nativeCharCount >= 1) {
          uncertain = false;
        } else {
          uncertain = true;
        }
      }

      final selectedLang =
          (best.confidence < 0.30 && best.nativeScriptRatio < 0.50)
              ? 'unknown'
              : best.language;

      return (
        best: best,
        primary: primary,
        resEn: resEn,
        resKa: resKa,
        resHi: resHi,
        selectedText: text,
        selectedLang: selectedLang,
        uncertain: uncertain,
      );
    } catch (e) {
      debugPrint('[OCR-REC] Inference error for polygon: $e');
      return null;
    } finally {
      if (inputTensor != null) await inputTensor.dispose();
    }
  }

  Future<_DecodedResult> _decodeOutput(
    OrtValue outputTensor,
    List<String> dict,
    String language, {
    List<bool>? inkColumns,
    int? targetWidth,
    int? tensorWidth,
    int padLr = 4,
    bool hasTrailingSpaceClass = true,
  }) async {
    final shape = outputTensor.shape;
    final rawList = await outputTensor.asFlattenedList();

    final int numClasses = shape.length >= 3
        ? shape[2]
        : (dict.length + (hasTrailingSpaceClass ? 2 : 1));
    final int timesteps =
        shape.length >= 2 ? shape[1] : (rawList.length ~/ numClasses);

    final buffer = StringBuffer();
    int prevToken = -1;
    double sumConf = 0.0;
    double minCharConf = 1.0;
    int tokenCount = 0;

    final int activeTimesteps = (targetWidth != null &&
            tensorWidth != null &&
            tensorWidth > 0)
        ? ((targetWidth / tensorWidth) * timesteps).round().clamp(1, timesteps)
        : timesteps;
    final tokenCols = List<bool>.filled(activeTimesteps, false);

    for (int t = 0; t < timesteps; t++) {
      final offset = t * numClasses;
      int bestIdx = 0;
      double bestVal = (rawList[offset] as num).toDouble();

      for (int c = 1; c < numClasses; c++) {
        final val = (rawList[offset + c] as num).toDouble();
        if (val > bestVal) {
          bestVal = val;
          bestIdx = c;
        }
      }

      // CTC rule: Ignore consecutive duplicates and blanks (index 0)
      if (bestIdx != prevToken && bestIdx != 0) {
        if (hasTrailingSpaceClass && bestIdx == numClasses - 1) {
          buffer.write(' ');
        } else if (bestIdx >= 1 && bestIdx <= dict.length) {
          buffer.write(dict[bestIdx - 1]);
          sumConf += bestVal;
          if (bestVal < minCharConf) minCharConf = bestVal;
          tokenCount++;
          if (t < activeTimesteps) {
            tokenCols[t] = true;
          }
        }
      } else if (bestIdx > 0 && bestIdx <= dict.length && t < activeTimesteps) {
        tokenCols[t] = true;
      }
      prevToken = bestIdx;
    }

    bool hasUncoveredInkGap = false;
    if (inkColumns != null && inkColumns.length >= 24 && activeTimesteps >= 8) {
      int gapStart = -1;
      final minGapSteps = math.max(6, (activeTimesteps * 0.18).round());
      for (int t = 0; t <= activeTimesteps; t++) {
        final isBlank = t == activeTimesteps || !tokenCols[t];
        if (!isBlank || t == activeTimesteps) {
          if (gapStart >= 0) {
            final gapEnd = t - 1;
            if (gapEnd - gapStart + 1 >= minGapSteps) {
              final totalW = inkColumns.length + 2 * padLr;
              final x0 = ((gapStart / activeTimesteps) * totalW).floor() - padLr;
              final x1 = (((gapEnd + 1) / activeTimesteps) * totalW).ceil() - padLr;
              final cx0 = x0.clamp(0, inkColumns.length - 1);
              final cx1 = x1.clamp(0, inkColumns.length - 1);
              if (cx1 - cx0 + 1 >= 16) {
                int inkCount = 0;
                for (int x = cx0; x <= cx1; x++) {
                  if (inkColumns[x]) inkCount++;
                }
                if (inkCount >= 8 && inkCount / (cx1 - cx0 + 1) >= 0.25) {
                  hasUncoveredInkGap = true;
                  break;
                }
              }
            }
            gapStart = -1;
          }
        } else {
          gapStart = gapStart < 0 ? t : gapStart;
        }
      }
    }

    // Bounded postprocessing: collapse accidental trailing double-period '..' -> '.'
    final rawText = buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    final text = rawText.replaceAll(RegExp(r'\.{2,}$'), '.');
    final conf = tokenCount > 0 ? (sumConf / tokenCount) : 0.0;
    final minC = tokenCount > 0 ? minCharConf : 0.0;
    final scriptStats = _measureNativeScript(text, language);
    return _DecodedResult(
      text: text,
      confidence: conf,
      minCharConfidence: minC,
      language: language,
      nativeScriptRatio: scriptStats.ratio,
      nativeCharCount: scriptStats.count,
      hasUncoveredInkGap: hasUncoveredInkGap,
    );
  }

  Future<void> dispose() async {
    await _sessionKa?.close();
    _sessionKa = null;
    await _sessionKaScene?.close();
    _sessionKaScene = null;
    await _sessionEn?.close();
    _sessionEn = null;
    await _sessionHi?.close();
    _sessionHi = null;
  }
}
