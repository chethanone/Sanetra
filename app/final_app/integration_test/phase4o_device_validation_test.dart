// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:vision_assistant/services/banknote_tracker.dart';
import 'package:vision_assistant/services/currency_model_service.dart';
import 'package:vision_assistant/services/currency_safety_evaluator.dart';

Uint8List _rgbToYuv420Planes(
  img.Image decoded,
  int targetW,
  int targetH,
  List<Uint8List> outPlanes,
) {
  final resized = img.copyResize(decoded, width: targetW, height: targetH);
  final yPlane = Uint8List(targetW * targetH);
  final uPlane = Uint8List((targetW ~/ 2) * (targetH ~/ 2));
  final vPlane = Uint8List((targetW ~/ 2) * (targetH ~/ 2));

  int yIdx = 0;
  for (int y = 0; y < targetH; y++) {
    for (int x = 0; x < targetW; x++) {
      final p = resized.getPixel(x, y);
      final r = p.r.toInt();
      final g = p.g.toInt();
      final b = p.b.toInt();
      yPlane[yIdx++] = (0.299 * r + 0.587 * g + 0.114 * b).round().clamp(0, 255);
      if (y % 2 == 0 && x % 2 == 0) {
        final uvIdx = (y ~/ 2) * (targetW ~/ 2) + (x ~/ 2);
        uPlane[uvIdx] = ((-0.169 * r - 0.331 * g + 0.500 * b) + 128).round().clamp(0, 255);
        vPlane[uvIdx] = ((0.500 * r - 0.419 * g - 0.081 * b) + 128).round().clamp(0, 255);
      }
    }
  }
  outPlanes.addAll([yPlane, uPlane, vPlane]);
  return yPlane;
}

double _boxIoU(List<double> a, List<double> b) {
  final ix1 = math.max(a[0], b[0]);
  final iy1 = math.max(a[1], b[1]);
  final ix2 = math.min(a[2], b[2]);
  final iy2 = math.min(a[3], b[3]);
  final inter = math.max(0.0, ix2 - ix1) * math.max(0.0, iy2 - iy1);
  if (inter <= 0.0) return 0.0;
  final aa = math.max(0.0, a[2] - a[0]) * math.max(0.0, a[3] - a[1]);
  final ab = math.max(0.0, b[2] - b[0]) * math.max(0.0, b[3] - b[1]);
  final uni = aa + ab - inter;
  return uni > 0.0 ? inter / uni : 0.0;
}

double _boxIoMin(List<double> a, List<double> b) {
  final ix1 = math.max(a[0], b[0]);
  final iy1 = math.max(a[1], b[1]);
  final ix2 = math.min(a[2], b[2]);
  final iy2 = math.min(a[3], b[3]);
  final inter = math.max(0.0, ix2 - ix1) * math.max(0.0, iy2 - iy1);
  if (inter <= 0.0) return 0.0;
  final aa = math.max(0.0, a[2] - a[0]) * math.max(0.0, a[3] - a[1]);
  final ab = math.max(0.0, b[2] - b[0]) * math.max(0.0, b[3] - b[1]);
  final m = math.min(aa, ab);
  return m > 0.0 ? inter / m : 0.0;
}

Map<String, dynamic> _scoreCoinsAndSafety({
  required List<CurrencyDetection> allDets,
  required List<Map<String, dynamic>> gtCoinBoxesNorm,
  required List<Map<String, dynamic>> gtNoteBoxesNorm,
  required int gtTotalInr,
  required int imgW,
  required int imgH,
  required int uncertainCoinsPresent,
  required bool isDevPlaceholderBox,
  required bool candidateMode,
  required CurrencyInferenceResult res,
}) {
  final coins = List<CurrencyDetection>.from(allDets.where((d) => d.isCoin))
    ..sort((a, b) => b.confidence.compareTo(a.confidence));
  final notes = allDets.where((d) => !d.isCoin).toList();

  final gtPxBoxes = gtCoinBoxesNorm.map((b) {
    return [
      (b['x1n'] as num).toDouble() * imgW,
      (b['y1n'] as num).toDouble() * imgH,
      (b['x2n'] as num).toDouble() * imgW,
      (b['y2n'] as num).toDouble() * imgH,
    ];
  }).toList();
  final gtNames = gtCoinBoxesNorm.map((b) => b['class_name'] as String).toList();

  int tp = 0;
  int wrongDenom = 0;
  int falsePositive = 0;
  int duplicateBoxes = 0;
  final matchedGt = <int>{};

  for (final pred in coins) {
    final pBox = [pred.x1, pred.y1, pred.x2, pred.y2];
    int bestSameIdx = -1;
    double bestSameScore = 0.0;
    int bestAnyIdx = -1;
    double bestAnyScore = 0.0;

    for (int gi = 0; gi < gtPxBoxes.length; gi++) {
      if (matchedGt.contains(gi)) continue;
      final ov = isDevPlaceholderBox
          ? _boxIoMin(pBox, gtPxBoxes[gi])
          : _boxIoU(pBox, gtPxBoxes[gi]);
      final th = isDevPlaceholderBox ? 0.50 : 0.40;
      if (ov >= th) {
        if (gtNames[gi] == pred.denomination && ov > bestSameScore) {
          bestSameScore = ov;
          bestSameIdx = gi;
        }
        if (ov > bestAnyScore) {
          bestAnyScore = ov;
          bestAnyIdx = gi;
        }
      }
    }

    if (bestSameIdx >= 0) {
      matchedGt.add(bestSameIdx);
      tp++;
    } else if (bestAnyIdx >= 0) {
      matchedGt.add(bestAnyIdx);
      wrongDenom++;
    } else {
      // Check if it's a duplicate detection overlapping an already-matched GT coin
      bool overlapsMatched = false;
      for (final mgi in matchedGt) {
        if (_boxIoU(pBox, gtPxBoxes[mgi]) >= 0.30 || _boxIoMin(pBox, gtPxBoxes[mgi]) >= 0.65) {
          overlapsMatched = true;
          break;
        }
      }
      if (overlapsMatched) {
        duplicateBoxes++;
      } else {
        falsePositive++;
      }
    }
  }

  final int missed = gtPxBoxes.length - matchedGt.length;

  // Banknote count / class summary (for mixed & banknote_and_rbi_seal categories)
  int noteMatched = 0;
  if (gtNoteBoxesNorm.isNotEmpty) {
    final gtNoteNames = <String, int>{};
    for (final nb in gtNoteBoxesNorm) {
      final n = nb['class_name'] as String;
      gtNoteNames[n] = (gtNoteNames[n] ?? 0) + 1;
    }
    final predNoteNames = <String, int>{};
    for (final n in notes) {
      predNoteNames[n.denomination] = (predNoteNames[n.denomination] ?? 0) + 1;
    }
    for (final e in gtNoteNames.entries) {
      final pc = predNoteNames[e.key] ?? 0;
      noteMatched += pc < e.value ? pc : e.value;
    }
  }

  // Run full Flutter safety evaluator identically to live/snapshot app pipeline
  final assessment = CurrencySafetyEvaluator.evaluate(
    allDets,
    candidateMode: candidateMode,
    imageWidth: imgW,
    imageHeight: imgH,
    hasUncertainObjectCount:
        candidateMode && res.totalStatus == 'conflicting' && res.conflictingNoteCount == 0,
    extraReasons: res.uncertaintyReasons.toSet(),
  );

  final int rawTotal = allDets.fold<int>(0, (s, d) => s + d.value);
  final int confirmedCoinCount = assessment.screenedDetections
      .where((d) => d.isCoin && d.isConfirmed)
      .length;
  final int tentativeCoinCount = assessment.screenedDetections
      .where((d) => d.isCoin && d.isTentative)
      .length;
  final int conflictingCoinCount = assessment.screenedDetections
      .where((d) => d.isCoin && d.isConflicting)
      .length;

  final bool totalMismatch = (assessment.isTotalConfirmed
          ? (assessment.confirmedTotalRupees ?? -1) != gtTotalInr
          : false);
  final bool rawTotalMismatch = rawTotal != gtTotalInr;
  final bool zeroCoinConfirmedFp = gtPxBoxes.isEmpty && confirmedCoinCount > 0;
  final bool coinInflatedNoteTotal =
      gtPxBoxes.isEmpty &&
      gtNoteBoxesNorm.isNotEmpty &&
      assessment.isTotalConfirmed &&
      allDets.any((d) => d.isCoin);

  return {
    'gt_coins': gtPxBoxes.length,
    'pred_coins': coins.length,
    'tp_coins': tp,
    'missed_coins': missed,
    'wrong_denom_coins': wrongDenom,
    'dup_boxes_coins': duplicateBoxes,
    'fp_coins': falsePositive,
    'confirmed_coins': confirmedCoinCount,
    'tentative_coins': tentativeCoinCount,
    'conflicting_coins': conflictingCoinCount,
    'gt_notes': gtNoteBoxesNorm.length,
    'pred_notes': notes.length,
    'matched_notes': noteMatched,
    'gt_total_inr': gtTotalInr,
    'raw_total_inr': rawTotal,
    'confirmed_total_inr': assessment.confirmedTotalRupees,
    'is_total_confirmed': assessment.isTotalConfirmed,
    'status': assessment.status.name,
    'reasons': assessment.reasons.toList(),
    'raw_total_mismatch': rawTotalMismatch,
    'confirmed_total_mismatch': totalMismatch,
    'zero_coin_confirmed_fp': zeroCoinConfirmedFp,
    'coin_inflated_note_total': coinInflatedNoteTotal,
    'uncertain_coins_present': uncertainCoinsPresent,
    'coin_confs': coins.map((c) => double.parse(c.confidence.toStringAsFixed(4))).toList(),
    'coin_classes': coins.map((c) => c.denomination).toList(),
    'coin_states': assessment.screenedDetections
        .where((d) => d.isCoin)
        .map((d) => d.confirmationState.name)
        .toList(),
    'spoken': assessment.spokenMessage,
  };
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 4O On-Device Coin & Dual Currency Hardware Evaluation', () {
    late CurrencyModelService service;
    const evalDirPath = '/data/user/0/com.visionassistant.vision_assistant.candidate/files/phase4o_eval';
    final Map<String, dynamic> fullReport = {
      'phase': '4O',
      'device': 'Nothing Phone (3a) Pro (A059P, Snapdragon 7s Gen 3)',
      'timestamp': DateTime.now().toIso8601String(),
    };

    setUpAll(() {
      service = CurrencyModelService();
    });

    tearDownAll(() async {
      await service.loadModel(useCandidate: true);
      await service.dispose();
      print('[PHASE4O_DEVICE_REPORT_BEGIN]');
      print(jsonEncode(fullReport));
      print('[PHASE4O_DEVICE_REPORT_END]');
    });

    testWidgets('1. Candidate vs Production Coin & Mixed Evaluation on Hardware', (tester) async {
      // Step A: Verify Candidate initializes and loads BOTH Phase 4N Coin and Phase 4L Banknote ONNX
      final swInit = Stopwatch()..start();
      await service.loadModel(useCandidate: true);
      swInit.stop();
      expect(service.isLoaded, isTrue);
      expect(service.isCandidateMode, isTrue);
      fullReport['candidate_init_ms'] = swInit.elapsedMilliseconds;

      // Step B: Verify adversarial uncertain coin detections NEVER inflate confirmed totals on device logic
      final adversarialCases = <String, CurrencySafetyAssessment>{
        'low_conf_coin_alone': CurrencySafetyEvaluator.evaluate([
          const CurrencyDetection(
            classId: 9, denomination: 'INR_10_COIN', value: 10, confidence: 0.48,
            x1: 300, y1: 200, x2: 450, y2: 350, type: 'coin', classMargin: 0.40,
          ),
        ], candidateMode: true, imageWidth: 1280, imageHeight: 720),
        'low_conf_coin_plus_confirmed_note': CurrencySafetyEvaluator.evaluate([
          const CurrencyDetection(
            classId: 3, denomination: 'INR_100', value: 100, confidence: 0.91,
            x1: 50, y1: 50, x2: 650, y2: 400, type: 'banknote', classMargin: 0.80,
          ),
          const CurrencyDetection(
            classId: 9, denomination: 'INR_10_COIN', value: 10, confidence: 0.52,
            x1: 800, y1: 200, x2: 940, y2: 340, type: 'coin', classMargin: 0.45,
          ),
        ], candidateMode: true, imageWidth: 1280, imageHeight: 720),
        'narrow_margin_coin': CurrencySafetyEvaluator.evaluate([
          const CurrencyDetection(
            classId: 7, denomination: 'INR_2_COIN', value: 2, confidence: 0.72,
            x1: 300, y1: 200, x2: 450, y2: 350, type: 'coin', classMargin: 0.08,
          ),
        ], candidateMode: true, imageWidth: 1280, imageHeight: 720),
        'cross_class_suppressed_conflict': CurrencySafetyEvaluator.evaluate([
          const CurrencyDetection(
            classId: 8, denomination: 'INR_5_COIN', value: 5, confidence: 0.76,
            x1: 300, y1: 200, x2: 450, y2: 350, type: 'coin', classMargin: 0.35,
            suppressedConflictConfidence: 0.42, suppressedConflictClassId: 7, suppressedConflictClassName: 'INR_2_COIN',
          ),
        ], candidateMode: true, imageWidth: 1280, imageHeight: 720),
        'coin_overlap_conflict': CurrencySafetyEvaluator.evaluate([
          const CurrencyDetection(
            classId: 8, denomination: 'INR_5_COIN', value: 5, confidence: 0.81,
            x1: 300, y1: 200, x2: 440, y2: 340, type: 'coin', classMargin: 0.50,
          ),
          const CurrencyDetection(
            classId: 9, denomination: 'INR_10_COIN', value: 10, confidence: 0.79,
            x1: 330, y1: 220, x2: 470, y2: 360, type: 'coin', classMargin: 0.45,
          ),
        ], candidateMode: true, imageWidth: 1280, imageHeight: 720),
        'cross_model_rbi_seal_inside_note': CurrencySafetyEvaluator.evaluate([
          const CurrencyDetection(
            classId: 5, denomination: 'INR_500', value: 500, confidence: 0.92,
            x1: 100, y1: 100, x2: 900, y2: 520, type: 'banknote', classMargin: 0.85,
          ),
          const CurrencyDetection(
            classId: 9, denomination: 'INR_10_COIN', value: 10, confidence: 0.78,
            x1: 720, y1: 300, x2: 790, y2: 370, type: 'coin', classMargin: 0.60,
          ),
        ], candidateMode: true, imageWidth: 1280, imageHeight: 720),
        'tiny_and_extreme_aspect_coin': CurrencySafetyEvaluator.evaluate([
          const CurrencyDetection(
            classId: 6, denomination: 'INR_1_COIN', value: 1, confidence: 0.80,
            x1: 200, y1: 200, x2: 225, y2: 265, type: 'coin', classMargin: 0.60,
          ),
        ], candidateMode: true, imageWidth: 1280, imageHeight: 720),
      };

      final advSummary = <String, dynamic>{};
      for (final e in adversarialCases.entries) {
        expect(e.value.isTotalConfirmed, isFalse, reason: '${e.key} must not confirm total');
        expect(e.value.confirmedTotalRupees, isNull, reason: '${e.key} confirmedTotalRupees must be null');
        expect(e.value.spokenMessage.contains('Confirmed total'), isFalse, reason: '${e.key} must not announce confirmed total');
        advSummary[e.key] = {
          'is_total_confirmed': e.value.isTotalConfirmed,
          'status': e.value.status.name,
          'reasons': e.value.reasons.toList(),
          'spoken': e.value.spokenMessage,
        };
      }
      fullReport['adversarial_uncertain_coin_checks'] = advSummary;

      // Step C: Run pushed 91-scene static evaluation suite on BOTH Candidate and Production Baseline
      final manifestFile = File('$evalDirPath/phase4o_eval_manifest.json');
      expect(manifestFile.existsSync(), isTrue, reason: 'Missing $evalDirPath/phase4o_eval_manifest.json');
      final manifest = jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
      final items = (manifest['items'] as List<dynamic>).cast<Map<String, dynamic>>();
      final yuvSeq = (manifest['yuv_sequence'] as List<dynamic>).cast<Map<String, dynamic>>();

      Future<Map<String, dynamic>> evaluateMode({required bool candidateMode}) async {
        await service.loadModel(
          useCandidate: candidateMode,
          forceProductionBaseline: !candidateMode,
        );

        final perCategory = <String, Map<String, dynamic>>{};
        final sampleLogs = <Map<String, dynamic>>[];
        final coinInferMs = <double>[];
        final noteInferMs = <double>[];
        final totalNativeMs = <double>[];
        final e2eMs = <double>[];

        for (final item in items) {
          final cat = item['category'] as String;
          final fname = item['file'] as String;
          final coinBoxes = (item['coin_boxes'] as List<dynamic>).cast<Map<String, dynamic>>();
          final noteBoxes = (item['note_boxes'] as List<dynamic>).cast<Map<String, dynamic>>();
          final gtTotal = item['gt_total_inr'] as int;
          final uncCount = item['uncertain_coins_present'] as int;
          final isDev = (item['note'] as String) == 'dev_sample';

          final bytes = await File('$evalDirPath/images/$fname').readAsBytes();
          final sw = Stopwatch()..start();
          final res = await service.runImageInference(
            bytes,
            source: fname,
            coinConfThreshold: candidateMode ? 0.35 : 0.25,
            banknoteConfThreshold: candidateMode ? 0.30 : 0.25,
          );
          sw.stop();

          final roundtripMs = sw.elapsedMilliseconds.toDouble();
          coinInferMs.add(res.coinInferenceTimeMs);
          noteInferMs.add(res.banknoteInferenceTimeMs);
          totalNativeMs.add(res.totalTimeMs);
          e2eMs.add(roundtripMs);

          final scored = _scoreCoinsAndSafety(
            allDets: res.detections,
            gtCoinBoxesNorm: coinBoxes,
            gtNoteBoxesNorm: noteBoxes,
            gtTotalInr: gtTotal,
            imgW: res.imageWidth,
            imgH: res.imageHeight,
            uncertainCoinsPresent: uncCount,
            isDevPlaceholderBox: isDev,
            candidateMode: candidateMode,
            res: res,
          );
          scored['file'] = fname;
          scored['category'] = cat;
          scored['native_coin_ms'] = res.coinInferenceTimeMs;
          scored['native_note_ms'] = res.banknoteInferenceTimeMs;
          scored['native_total_ms'] = res.totalTimeMs;
          scored['e2e_ms'] = roundtripMs;
          sampleLogs.add(scored);

          final b = perCategory.putIfAbsent(cat, () => {
            'scenes': 0,
            'gt_coins': 0,
            'pred_coins': 0,
            'tp_coins': 0,
            'missed_coins': 0,
            'wrong_denom_coins': 0,
            'dup_boxes_coins': 0,
            'fp_coins': 0,
            'confirmed_coins': 0,
            'tentative_coins': 0,
            'conflicting_coins': 0,
            'gt_notes': 0,
            'matched_notes': 0,
            'raw_total_mismatches': 0,
            'confirmed_total_mismatches': 0,
            'total_confirmed_scenes': 0,
            'zero_coin_confirmed_fps': 0,
            'coin_inflated_note_totals': 0,
          });
          b['scenes'] = (b['scenes'] as int) + 1;
          b['gt_coins'] = (b['gt_coins'] as int) + (scored['gt_coins'] as int);
          b['pred_coins'] = (b['pred_coins'] as int) + (scored['pred_coins'] as int);
          b['tp_coins'] = (b['tp_coins'] as int) + (scored['tp_coins'] as int);
          b['missed_coins'] = (b['missed_coins'] as int) + (scored['missed_coins'] as int);
          b['wrong_denom_coins'] = (b['wrong_denom_coins'] as int) + (scored['wrong_denom_coins'] as int);
          b['dup_boxes_coins'] = (b['dup_boxes_coins'] as int) + (scored['dup_boxes_coins'] as int);
          b['fp_coins'] = (b['fp_coins'] as int) + (scored['fp_coins'] as int);
          b['confirmed_coins'] = (b['confirmed_coins'] as int) + (scored['confirmed_coins'] as int);
          b['tentative_coins'] = (b['tentative_coins'] as int) + (scored['tentative_coins'] as int);
          b['conflicting_coins'] = (b['conflicting_coins'] as int) + (scored['conflicting_coins'] as int);
          b['gt_notes'] = (b['gt_notes'] as int) + (scored['gt_notes'] as int);
          b['matched_notes'] = (b['matched_notes'] as int) + (scored['matched_notes'] as int);
          b['raw_total_mismatches'] = (b['raw_total_mismatches'] as int) + ((scored['raw_total_mismatch'] as bool) ? 1 : 0);
          b['confirmed_total_mismatches'] = (b['confirmed_total_mismatches'] as int) + ((scored['confirmed_total_mismatch'] as bool) ? 1 : 0);
          b['total_confirmed_scenes'] = (b['total_confirmed_scenes'] as int) + ((scored['is_total_confirmed'] as bool) ? 1 : 0);
          b['zero_coin_confirmed_fps'] = (b['zero_coin_confirmed_fps'] as int) + ((scored['zero_coin_confirmed_fp'] as bool) ? 1 : 0);
          b['coin_inflated_note_totals'] = (b['coin_inflated_note_totals'] as int) + ((scored['coin_inflated_note_total'] as bool) ? 1 : 0);
        }

        // Step D: Live YUV420 Camera Frame Streaming + Tracker Sequence
        const nativeChannel = MethodChannel('visionmission/currency_detector');
        final tracker = BanknoteTracker(candidateMode: candidateMode);
        final seqLogs = <Map<String, dynamic>>[];

        for (final step in yuvSeq) {
          final fname = step['file'] as String;
          final rawBytes = await File('$evalDirPath/images/$fname').readAsBytes();
          final decoded = img.decodeImage(rawBytes)!;
          final planes = <Uint8List>[];
          _rgbToYuv420Planes(decoded, 640, 480, planes);

          final sw = Stopwatch()..start();
          final resMap = await nativeChannel.invokeMethod<Map<dynamic, dynamic>>('detectCameraFrame', {
            'yBytes': planes[0],
            'uBytes': planes[1],
            'vBytes': planes[2],
            'width': 640,
            'height': 480,
            'yRowStride': 640,
            'uvRowStride': 320,
            'uvPixelStride': 1,
            'sensorOrientation': 0,
            'coinConfThreshold': candidateMode ? 0.35 : 0.25,
            'banknoteConfThreshold': candidateMode ? 0.30 : 0.25,
            'iouThreshold': 0.45,
          });
          sw.stop();

          final rawList = (resMap?['detections'] as List<dynamic>?) ?? const [];
          final parsed = <CurrencyDetection>[];
          for (final item in rawList) {
            if (item is Map) {
              final box = (item['box'] as List<dynamic>?) ?? [0.0, 0.0, 0.0, 0.0];
              parsed.add(CurrencyDetection(
                classId: (item['classId'] as num?)?.toInt() ?? 0,
                denomination: item['denomination']?.toString() ?? '',
                value: (item['value'] as num?)?.toInt() ?? 0,
                confidence: (item['confidence'] as num?)?.toDouble() ?? 0.0,
                x1: (box[0] as num).toDouble(),
                y1: (box[1] as num).toDouble(),
                x2: (box[2] as num).toDouble(),
                y2: (box[3] as num).toDouble(),
                type: item['type']?.toString() ?? '',
                classMargin: (item['classMargin'] as num?)?.toDouble() ?? 1.0,
                suppressedConflictCount: (item['suppressedConflictCount'] as num?)?.toInt() ?? 0,
                suppressedConflictClassName: item['suppressedConflictClassName']?.toString() ?? '',
                suppressedConflictConfidence: (item['suppressedConflictConfidence'] as num?)?.toDouble() ?? 0.0,
                interBoxMaxIoU: (item['interBoxMaxIoU'] as num?)?.toDouble() ?? 0.0,
                interBoxMaxIoMin: (item['interBoxMaxIoMin'] as num?)?.toDouble() ?? 0.0,
                confirmationState: parseConfirmationState(item['confirmationState']?.toString()),
                uncertaintyReasons: ((item['uncertaintyReasons'] as List<dynamic>?) ?? const []).map((e) => e.toString()).toList(),
              ));
            }
          }

          final tr = tracker.updateWithSafety(parsed, imageWidth: 640, imageHeight: 480);
          seqLogs.add({
            'stage': step['stage'],
            'raw_coin_count': parsed.where((d) => d.isCoin).length,
            'raw_note_count': parsed.where((d) => !d.isCoin).length,
            'tracked_classes': tr.activeDetections.map((d) => d.denomination).toList(),
            'is_total_confirmed': tr.assessment.isTotalConfirmed,
            'confirmed_total': tr.assessment.confirmedTotalRupees,
            'visible_sum': tr.assessment.visibleDetectedSumRupees,
            'status': tr.assessment.status.name,
            'spoken': tr.assessment.spokenMessage,
            'yuv_e2e_ms': sw.elapsedMilliseconds,
            'native_total_ms': (resMap?['totalTimeMs'] as num?)?.toDouble() ?? 0.0,
          });
        }

        double avg(List<double> v) => v.isEmpty ? 0.0 : v.reduce((a, b) => a + b) / v.length;
        return {
          'mean_coin_infer_ms': double.parse(avg(coinInferMs).toStringAsFixed(2)),
          'mean_note_infer_ms': double.parse(avg(noteInferMs).toStringAsFixed(2)),
          'mean_native_total_ms': double.parse(avg(totalNativeMs).toStringAsFixed(2)),
          'mean_e2e_ms': double.parse(avg(e2eMs).toStringAsFixed(2)),
          'per_category': perCategory,
          'yuv_sequence': seqLogs,
          'samples': sampleLogs,
        };
      }

      fullReport['candidate_mode'] = await evaluateMode(candidateMode: true);
      fullReport['production_baseline'] = await evaluateMode(candidateMode: false);
    });
  });
}

