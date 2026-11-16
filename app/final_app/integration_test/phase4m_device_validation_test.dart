// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:vision_assistant/services/banknote_tracker.dart';
import 'package:vision_assistant/services/currency_model_service.dart';
import 'package:vision_assistant/services/currency_safety_evaluator.dart';

Uint8List _rgbToYuv420Planes(img.Image decoded, int targetW, int targetH, List<Uint8List> outPlanes) {
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

Map<String, dynamic> _scoreBanknoteDetections(
  List<CurrencyDetection> dets,
  List<int> gtClasses,
  int gtTotalInr,
  bool candidateMode,
  CurrencyInferenceResult res,
) {
  final notes = dets.where((d) => !d.isCoin).toList();
  final predClasses = notes.map((d) => d.classId).toList();

  // Bag-of-classes matching for scene-level misses, duplicates, and denom errors
  final gtCounts = <int, int>{};
  for (final c in gtClasses) {
    gtCounts[c] = (gtCounts[c] ?? 0) + 1;
  }
  final predCounts = <int, int>{};
  for (final c in predClasses) {
    predCounts[c] = (predCounts[c] ?? 0) + 1;
  }

  int matchedSameClass = 0;
  for (final e in gtCounts.entries) {
    final pCount = predCounts[e.key] ?? 0;
    matchedSameClass += pCount < e.value ? pCount : e.value;
  }

  int missed = 0;
  int wrongDenom = 0;
  int duplicateOrExtra = 0;
  int crossClassDup = 0;

  if (gtClasses.isNotEmpty) {
    final unmatchedGt = gtClasses.length - matchedSameClass;
    final unmatchedPred = notes.length - matchedSameClass;
    wrongDenom = unmatchedGt < unmatchedPred ? unmatchedGt : unmatchedPred;
    missed = unmatchedGt - wrongDenom;
    duplicateOrExtra = unmatchedPred - wrongDenom;

    // Detect spatially overlapping pairs on same physical note
    for (int i = 0; i < notes.length; i++) {
      for (int j = i + 1; j < notes.length; j++) {
        if (CurrencySafetyEvaluator.computeIoU(notes[i], notes[j]) > 0.45 &&
            notes[i].classId != notes[j].classId) {
          crossClassDup++;
        }
      }
    }
  } else {
    duplicateOrExtra = notes.length; // False positives on negative scene
  }

  final assessment = CurrencySafetyEvaluator.evaluate(
    notes,
    candidateMode: candidateMode,
    hasUncertainObjectCount:
        candidateMode && res.totalStatus == 'conflicting' && res.conflictingNoteCount == 0,
    extraReasons: res.uncertaintyReasons.toSet(),
  );

  final rawTotal = notes.fold<int>(0, (s, d) => s + d.value);
  final rawIncorrectTotal = rawTotal != gtTotalInr;
  final confirmedTotalIncorrect =
      assessment.isTotalConfirmed && (assessment.confirmedTotalRupees ?? -1) != gtTotalInr;
  final gatedUncertain = candidateMode && notes.isNotEmpty && !assessment.isTotalConfirmed;
  final spuriousNegSpeech = gtClasses.isEmpty && notes.isNotEmpty && assessment.isTotalConfirmed;
  final spuriousNegGateSpeech = gtClasses.isEmpty && notes.isNotEmpty && !assessment.isTotalConfirmed;

  return {
    'gt_count': gtClasses.length,
    'pred_count': notes.length,
    'gt_total': gtTotalInr,
    'raw_total': rawTotal,
    'confirmed_total': assessment.confirmedTotalRupees,
    'is_total_confirmed': assessment.isTotalConfirmed,
    'status': assessment.status.name,
    'spoken': assessment.spokenMessage,
    'missed': missed,
    'wrong_denom': wrongDenom,
    'dup_or_extra': duplicateOrExtra,
    'cross_class_dup': crossClassDup,
    'raw_incorrect_total': rawIncorrectTotal,
    'confirmed_incorrect_total': confirmedTotalIncorrect,
    'gated_uncertain': gatedUncertain,
    'spurious_confirmed_neg': spuriousNegSpeech,
    'spurious_any_neg': spuriousNegGateSpeech,
    'coin_fp_count': dets.where((d) => d.isCoin).length,
    'top_conf': notes.isNotEmpty ? notes.first.confidence : 0.0,
    'min_margin': notes.isNotEmpty
        ? notes.map((d) => d.classMargin).reduce((a, b) => a < b ? a : b)
        : 1.0,
  };
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 4M On-Device Candidate Validation (Nothing Phone 3a Pro)', () {
    late CurrencyModelService service;
    const evalDirPath = '/data/user/0/com.visionassistant.vision_assistant.candidate/files/phase4m_eval';
    final Map<String, dynamic> fullReport = {
      'phase': '4M',
      'device': 'Nothing Phone (3a) Pro (A059P, Snapdragon 7s Gen 3)',
      'timestamp': DateTime.now().toIso8601String(),
    };

    setUpAll(() {
      service = CurrencyModelService();
    });

    tearDownAll(() async {
      // Restore default candidate mode before disposing
      await service.loadModel(useCandidate: true);
      await service.dispose();
      print('[PHASE4M_DEVICE_REPORT_BEGIN]');
      print(jsonEncode(fullReport));
      print('[PHASE4M_DEVICE_REPORT_END]');
    });

    testWidgets('1. Candidate vs Production Dual Suite on Hardware', (tester) async {
      // A) Candidate Initialization & Bundled Coin Regression Check
      final swInit = Stopwatch()..start();
      await service.loadModel(useCandidate: true);
      swInit.stop();
      expect(service.isLoaded, isTrue);
      expect(service.isCandidateMode, isTrue);

      fullReport['candidate_init_ms'] = swInit.elapsedMilliseconds;

      // Verify existing production coin model works in candidate app
      final coinChecks = <String, dynamic>{};
      for (final item in [
        {'file': 'coin_1_rupee_IMG_0422JPG.jpg', 'cls': 'INR_1_COIN'},
        {'file': 'coin_2_rupee_IMG_E1291JPG.jpg', 'cls': 'INR_2_COIN'},
        {'file': 'coin_5_rupee_IMG_0445JPG.jpg', 'cls': 'INR_5_COIN'},
        {'file': 'coin_10_rupee_005JPG.jpg', 'cls': 'INR_10_COIN'},
      ]) {
        final bd = await rootBundle.load('assets/test_images/dev_samples/${item['file']}');
        final res = await service.runImageInference(bd.buffer.asUint8List(), source: item['file']!);
        final ok = res.detections.any((d) => d.denomination == item['cls']);
        coinChecks[item['cls']!] = ok;
        expect(ok, isTrue, reason: 'Production coin regression failed for ${item['cls']}');
      }
      fullReport['coin_regression_in_candidate'] = coinChecks;

      // B) Load pushed 12-category real-world evaluation suite
      final manifestFile = File('$evalDirPath/phase4m_eval_manifest.json');
      expect(manifestFile.existsSync(), isTrue, reason: 'Missing $evalDirPath/phase4m_eval_manifest.json');
      final manifest = jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
      final items = (manifest['items'] as List<dynamic>).cast<Map<String, dynamic>>();
      final movingSeq = (manifest['moving_sequence'] as List<dynamic>).cast<Map<String, dynamic>>();

      Future<Map<String, dynamic>> evaluateMode({required bool candidateMode}) async {
        await service.loadModel(
          useCandidate: candidateMode,
          forceProductionBaseline: !candidateMode,
        );

        final perCategory = <String, Map<String, dynamic>>{};
        final sampleLogs = <Map<String, dynamic>>[];
        final noteInferMs = <double>[];
        final totalNativeMs = <double>[];
        final e2eMs = <double>[];

        for (final item in items) {
          final cat = item['category'] as String;
          final fname = item['file'] as String;
          final gtClasses = (item['gt_classes'] as List<dynamic>).cast<int>();
          final gtTotal = item['gt_total_inr'] as int;
          final bytes = await File('$evalDirPath/images/$fname').readAsBytes();

          final sw = Stopwatch()..start();
          final res = await service.runImageInference(
            bytes,
            source: fname,
            banknoteConfThreshold: candidateMode ? 0.30 : 0.25,
          );
          sw.stop();

          final roundtripMs = sw.elapsedMilliseconds.toDouble();
          noteInferMs.add(res.banknoteInferenceTimeMs);
          totalNativeMs.add(res.totalTimeMs);
          e2eMs.add(roundtripMs);

          final scored = _scoreBanknoteDetections(
            res.detections,
            gtClasses,
            gtTotal,
            candidateMode,
            res,
          );
          scored['file'] = fname;
          scored['category'] = cat;
          scored['native_note_ms'] = res.banknoteInferenceTimeMs;
          scored['native_total_ms'] = res.totalTimeMs;
          scored['e2e_ms'] = roundtripMs;
          sampleLogs.add(scored);

          final bucket = perCategory.putIfAbsent(cat, () => {
            'scenes': 0,
            'gt_notes': 0,
            'missed': 0,
            'wrong_denom': 0,
            'dup_or_extra': 0,
            'cross_class_dup': 0,
            'raw_incorrect_totals': 0,
            'confirmed_incorrect_totals': 0,
            'gated_uncertain': 0,
            'spurious_confirmed_speech': 0,
            'spurious_any_neg': 0,
            'coin_fps': 0,
          });
          bucket['scenes'] = (bucket['scenes'] as int) + 1;
          bucket['gt_notes'] = (bucket['gt_notes'] as int) + gtClasses.length;
          bucket['missed'] = (bucket['missed'] as int) + (scored['missed'] as int);
          bucket['wrong_denom'] = (bucket['wrong_denom'] as int) + (scored['wrong_denom'] as int);
          bucket['dup_or_extra'] = (bucket['dup_or_extra'] as int) + (scored['dup_or_extra'] as int);
          bucket['cross_class_dup'] = (bucket['cross_class_dup'] as int) + (scored['cross_class_dup'] as int);
          bucket['raw_incorrect_totals'] = (bucket['raw_incorrect_totals'] as int) + ((scored['raw_incorrect_total'] as bool) ? 1 : 0);
          bucket['confirmed_incorrect_totals'] = (bucket['confirmed_incorrect_totals'] as int) + ((scored['confirmed_incorrect_total'] as bool) ? 1 : 0);
          bucket['gated_uncertain'] = (bucket['gated_uncertain'] as int) + ((scored['gated_uncertain'] as bool) ? 1 : 0);
          bucket['spurious_confirmed_speech'] = (bucket['spurious_confirmed_speech'] as int) + ((scored['spurious_confirmed_neg'] as bool) ? 1 : 0);
          bucket['spurious_any_neg'] = (bucket['spurious_any_neg'] as int) + ((scored['spurious_any_neg'] as bool) ? 1 : 0);
          bucket['coin_fps'] = (bucket['coin_fps'] as int) + (scored['coin_fp_count'] as int);
        }

        // C) Run 9-frame moving camera YUV420 live-stream tracker sequence
        const nativeChannel = MethodChannel('visionmission/currency_detector');
        final tracker = BanknoteTracker(candidateMode: candidateMode);
        final seqLogs = <Map<String, dynamic>>[];

        for (final step in movingSeq) {
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
            'coinConfThreshold': 0.25,
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

          final tr = tracker.updateWithSafety(parsed.where((d) => !d.isCoin).toList());
          seqLogs.add({
            'stage': step['stage'],
            'gt_classes': step['gt_classes'],
            'gt_total_inr': step['gt_total_inr'],
            'raw_note_count': parsed.where((d) => !d.isCoin).length,
            'tracked_count': tr.activeDetections.length,
            'tracked_classes': tr.activeDetections.map((d) => d.denomination).toList(),
            'is_total_confirmed': tr.assessment.isTotalConfirmed,
            'confirmed_total': tr.assessment.confirmedTotalRupees,
            'visible_sum': tr.assessment.visibleDetectedSumRupees,
            'status': tr.assessment.status.name,
            'spoken': tr.assessment.spokenMessage,
            'retained_missing': tr.retainedMissingCount,
            'yuv_e2e_ms': sw.elapsedMilliseconds,
            'native_total_ms': (resMap?['totalTimeMs'] as num?)?.toDouble() ?? 0.0,
          });
        }

        double avg(List<double> v) => v.isEmpty ? 0.0 : v.reduce((a, b) => a + b) / v.length;
        return {
          'mean_note_infer_ms': double.parse(avg(noteInferMs).toStringAsFixed(2)),
          'mean_native_total_ms': double.parse(avg(totalNativeMs).toStringAsFixed(2)),
          'mean_e2e_ms': double.parse(avg(e2eMs).toStringAsFixed(2)),
          'per_category': perCategory,
          'moving_sequence': seqLogs,
          'samples': sampleLogs,
        };
      }

      fullReport['candidate_mode'] = await evaluateMode(candidateMode: true);
      fullReport['production_baseline'] = await evaluateMode(candidateMode: false);
    });
  });
}

