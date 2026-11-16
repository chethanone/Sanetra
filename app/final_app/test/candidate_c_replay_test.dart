// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vision_assistant/services/banknote_tracker.dart';
import 'package:vision_assistant/services/currency_model_service.dart';
import 'package:vision_assistant/services/currency_safety_evaluator.dart';

const _inJson =
    r'C:\VisionMission\experiments\phase4o5_1\evaluation\android_kotlin_replay_inputs.json';
const _outJson =
    r'C:\VisionMission\experiments\phase4o5_1\evaluation\android_dart_replay_results.json';

CurrencyDetection _fromJson(Map<String, dynamic> m) {
  final box = (m['box'] as List).map((v) => (v as num).toDouble()).toList();
  return CurrencyDetection(
    classId: m['classId'] as int,
    denomination: m['denomination'] as String,
    value: m['value'] as int,
    confidence: (m['confidence'] as num).toDouble(),
    x1: box[0],
    y1: box[1],
    x2: box[2],
    y2: box[3],
    type: m['type'] as String,
    top2ClassId: m['top2ClassId'] as int,
    top2ClassName: m['top2ClassName'] as String,
    top2Confidence: (m['top2Confidence'] as num).toDouble(),
    classMargin: (m['classMargin'] as num).toDouble(),
    suppressedConflictCount: m['suppressedConflictCount'] as int,
    suppressedConflictClassId: m['suppressedConflictClassId'] as int,
    suppressedConflictClassName: m['suppressedConflictClassName'] as String,
    suppressedConflictConfidence:
        (m['suppressedConflictConfidence'] as num).toDouble(),
    interBoxMaxIoU: (m['interBoxMaxIoU'] as num).toDouble(),
    interBoxMaxIoMin: (m['interBoxMaxIoMin'] as num).toDouble(),
    confirmationState: parseConfirmationState(m['confirmationState'] as String?),
    uncertaintyReasons:
        (m['uncertaintyReasons'] as List).map((e) => e.toString()).toList(),
  );
}

Map<String, dynamic> _runSteadyReplay(Map<String, dynamic> sc) {
  final frames = sc['frame_outputs'] as List;
  // For single-image scenes, simulate 3 steady camera frames so BanknoteTracker
  // and the 3-frame speech signature gate evaluate full confirmation & TTS.
  final simFrames = frames.length == 1 ? [frames[0], frames[0], frames[0]] : frames;

  final tracker = BanknoteTracker(candidateMode: true);
  String pendingSig = '';
  int pendingCount = 0;
  String lastSpokenSig = '';
  final spokenEvents = <Map<String, dynamic>>[];

  CurrencySafetyAssessment? lastAssessment;
  List<CurrencyDetection> lastTracked = [];

  for (int i = 0; i < simFrames.length; i++) {
    final fo = simFrames[i] as Map<String, dynamic>;
    final w = fo['image_width'] as int;
    final h = fo['image_height'] as int;
    final dets = (fo['detections'] as List)
        .map((e) => _fromJson(e as Map<String, dynamic>))
        .toList();

    final tr = tracker.updateWithSafety(dets, imageWidth: w, imageHeight: h);
    final a = tr.assessment;
    lastAssessment = a;
    lastTracked = tr.activeDetections;

    if (a.screenedDetections.isEmpty || a.status.name == 'empty') {
      pendingSig = '';
      pendingCount = 0;
      lastSpokenSig = '';
    } else {
      final sig = a.isTotalConfirmed
          ? 'CONFIRMED|${(a.screenedDetections.map((d) => '${d.denomination}:confirmed').toList()..sort()).join(',')}'
          : 'UNCERTAIN|${a.status.name}|${a.spokenMessage}';
      if (sig != lastSpokenSig) {
        if (sig == pendingSig) {
          pendingCount++;
        } else {
          pendingSig = sig;
          pendingCount = 1;
        }
        if (pendingCount >= 3) {
          lastSpokenSig = sig;
          spokenEvents.add({
            'frame': i + 1,
            'status': a.status.name,
            'confirmed_total': a.confirmedTotalRupees,
            'speech': a.spokenMessage,
          });
        }
      }
    }
  }

  final f0 = frames[0] as Map<String, dynamic>;
  final aFinal = lastAssessment!;
  final screened = aFinal.screenedDetections;
  final coinsInScreened = screened.where((d) => d.isCoin).toList();
  final confirmedCoins = coinsInScreened.where((d) => d.isConfirmed).toList();
  final notesInScreened = screened.where((d) => !d.isCoin).toList();

  return {
    'id': sc['id'],
    'category': sc['category'],
    'gt_coin_total': sc['gt_coin_total'],
    'gt_desc': sc['gt_desc'],
    'raw_coins_conf10': f0['raw_coins_conf10'],
    'post_nms_coins_count': (f0['post_nms_coins'] as List).length,
    'post_nms_notes_count': (f0['post_nms_notes'] as List).length,
    'final_status': aFinal.status.name,
    'is_total_confirmed': aFinal.isTotalConfirmed,
    'confirmed_total_inr': aFinal.confirmedTotalRupees,
    'visible_sum_inr': aFinal.visibleDetectedSumRupees,
    'reasons': aFinal.reasons.toList()..sort(),
    'spoken_message': aFinal.spokenMessage,
    'spoken_events': spokenEvents,
    'screened_coins': coinsInScreened
        .map((c) => {
              'cls': c.denomination,
              'conf': double.parse(c.confidence.toStringAsFixed(4)),
              'margin': double.parse(c.classMargin.toStringAsFixed(4)),
              'state': c.confirmationState.name,
              'reasons': c.uncertaintyReasons,
              'framesVisible': c.framesVisible,
            })
        .toList(),
    'screened_notes': notesInScreened
        .map((n) => {
              'cls': n.denomination,
              'conf': double.parse(n.confidence.toStringAsFixed(4)),
              'state': n.confirmationState.name,
            })
        .toList(),
    'confirmed_coin_count': confirmedCoins.length,
    'tracked_count': lastTracked.length,
  };
}

void main() {
  test('Phase 4O.5.1 Candidate C full Android Dart safety + tracker replay', () {
    final raw = jsonDecode(File(_inJson).readAsStringSync()) as Map<String, dynamic>;
    final byModel = raw['results_by_model'] as Map<String, dynamic>;

    final outByModel = <String, dynamic>{};
    for (final entry in byModel.entries) {
      final mname = entry.key;
      final scList = entry.value as List;
      outByModel[mname] = scList
          .map((sc) => _runSteadyReplay(sc as Map<String, dynamic>))
          .toList();
      print('[DART-REPLAY] Completed $mname (${scList.length} scenarios)');
    }

    File(_outJson).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'models': raw['models'],
        'banknote_model': raw['banknote_model'],
        'results_by_model': outByModel,
      }),
    );
    print('[DART-REPLAY] Saved results to $_outJson');
  });
}

