// ignore_for_file: avoid_print
// Phase 4O.2 replay of the three recorded Phase 4O.1 physical live-camera scenarios.
//
// Input: the actual per-frame raw detections recorded in [LIVE-AUDIT] logcat lines
// (class, confidence, class margin). The coin/banknote models and NMS are unchanged in
// Phase 4O.2, so these raw sequences are valid inputs for the changed tracker + safety logic.
//
// LIMITATIONS (reported, not hidden):
// - [LIVE-AUDIT] does not log boxes. Boxes are approximated from the saved screenshots
//   (screen -> 720x1280 camera-frame mapping), constant per physical object.
// - Raw per-detection states in the log came from the OLD native screening, so they are
//   ignored; Dart CurrencySafetyEvaluator (mirrors native rules) re-screens every frame.
// - Per-detection suppressed-conflict confidence is not logged. If a frame's reasons list
//   contains CROSS_CLASS_CONFLICT, ALL coins in that frame are conservatively given a
//   suppressed conflict (0.30), which can only make confirmation harder.
// - top2 class identity is not logged (top2ClassId = -1).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vision_assistant/services/banknote_tracker.dart';
import 'package:vision_assistant/services/currency_model_service.dart';

const _dir = r'C:\VisionMission\experiments\phase4o\live_camera_4o1';
const int _w = 720;
const int _h = 1280;

class _Raw {
  final String cls;
  final double conf;
  final double margin;
  _Raw(this.cls, this.conf, this.margin);
}

class _Frame {
  final int idx;
  final String time;
  final List<_Raw> raw;
  final List<String> oldReasons;
  final String oldStatus;
  final String oldConfTot;
  final String oldSpeech;
  _Frame(this.idx, this.time, this.raw, this.oldReasons, this.oldStatus,
      this.oldConfTot, this.oldSpeech);
}

List<_Frame> _parse(String file) {
  final lines = File('$_dir\\$file').readAsLinesSync();
  final frames = <_Frame>[];
  final rawEntry = RegExp(r'(INR_\w+?):([\d.]+)\(m=([\d.]+),(\w+)\)');
  for (final l in lines) {
    if (!l.contains('[LIVE-AUDIT]')) continue;
    final idx = int.parse(RegExp(r'\[LIVE-AUDIT\] #(\d+)').firstMatch(l)!.group(1)!);
    final time = l.substring(6, 18);
    final rawPart = RegExp(r'raw=\[(.*?)\] trk=').firstMatch(l)!.group(1)!;
    final raw = rawEntry
        .allMatches(rawPart)
        .map((m) => _Raw(m.group(1)!, double.parse(m.group(2)!), double.parse(m.group(3)!)))
        .toList();
    final reasons = RegExp(r'reasons=\[(.*?)\]').firstMatch(l)!.group(1)!
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final status = RegExp(r'status=(\w+)').firstMatch(l)!.group(1)!;
    final confTot = RegExp(r'confTot=(\w+)').firstMatch(l)!.group(1)!;
    final speech = RegExp(r'speech="(.*)"').firstMatch(l)?.group(1) ?? '';
    frames.add(_Frame(idx, time, raw, reasons, status, confTot, speech));
  }
  return frames;
}

int _classId(String cls) => CurrencyModelService.classNames.indexOf(cls);

CurrencyDetection _det(_Raw r, List<double> box, bool crossClass) {
  final id = _classId(r.cls);
  final isCoin = r.cls.contains('COIN');
  return CurrencyDetection(
    classId: id,
    denomination: r.cls,
    value: CurrencyModelService.denominationValues[id],
    confidence: r.conf,
    x1: box[0],
    y1: box[1],
    x2: box[2],
    y2: box[3],
    type: isCoin ? 'coin' : 'banknote',
    classMargin: r.margin,
    top2Confidence: (r.conf - r.margin).clamp(0.0, 1.0),
    suppressedConflictConfidence: (isCoin && crossClass) ? 0.30 : 0.0,
    suppressedConflictCount: (isCoin && crossClass) ? 1 : 0,
  );
}

// Approximate camera-frame boxes (720x1280) derived from the saved screenshots.
const _s1Note = [70.6, 382.0, 648.5, 763.0]; // INR_20, ~23.9% frame
const _s1Coin5 = [182.6, 563.0, 311.9, 694.0]; // left brass Rs5, ~1.8%
const _s1Coin2 = [480.0, 547.0, 602.0, 672.0]; // right steel Rs2 over seal, ~1.7%
const _s2Top = [249.8, 359.7, 515.4, 624.0]; // top coin (physical Rs1), ~7.6%
const _s2Bottom = [208.0, 761.6, 511.0, 1065.6]; // bottom coin (physical Rs2), ~10%
const _s3Note = [70.6, 316.8, 648.5, 1136.0]; // INR_20, ~51.4% (< 72% wrapper cap)
const _s3Coin2 = [359.9, 453.0, 541.0, 624.0]; // Rs2 over RBI seal, ~3.4%
const _s3Coin2Dup = [372.0, 462.0, 548.0, 630.0]; // co-located duplicate box in #94/#95

List<CurrencyDetection> _mapS1(_Frame f) {
  final cc = f.oldReasons.contains('CROSS_CLASS_CONFLICT');
  return f.raw.map((r) {
    if (!r.cls.contains('COIN')) return _det(r, _s1Note, cc);
    // brass coin -> INR_5; steel coin over seal -> INR_2 / INR_1 confusions
    return _det(r, r.cls == 'INR_5_COIN' ? _s1Coin5 : _s1Coin2, cc);
  }).toList();
}

List<CurrencyDetection> _mapS2(_Frame f) {
  final cc = f.oldReasons.contains('CROSS_CLASS_CONFLICT');
  final coins = f.raw.where((r) => r.cls.contains('COIN')).toList();
  if (coins.isEmpty) return [];
  if (coins.length == 1) return [_det(coins.first, _s2Bottom, cc)];
  // Heuristic identity: an INR_1 prediction, else the lower-margin prediction, is the top (physical Rs1) coin.
  int topIdx;
  final i1 = coins.indexWhere((r) => r.cls == 'INR_1_COIN');
  if (i1 >= 0) {
    topIdx = i1;
  } else {
    topIdx = coins[0].margin <= coins[1].margin ? 0 : 1;
  }
  return [
    _det(coins[topIdx], _s2Top, cc),
    _det(coins[1 - topIdx], _s2Bottom, cc),
  ];
}

List<CurrencyDetection> _mapS3(_Frame f) {
  final cc = f.oldReasons.contains('CROSS_CLASS_CONFLICT');
  final out = <CurrencyDetection>[];
  int coinN = 0;
  for (final r in f.raw) {
    if (!r.cls.contains('COIN')) {
      out.add(_det(r, _s3Note, cc));
    } else {
      out.add(_det(r, coinN == 0 ? _s3Coin2 : _s3Coin2Dup, cc));
      coinN++;
    }
  }
  return out;
}

Map<String, dynamic> _replay(String name, String file, int gtTotal,
    List<CurrencyDetection> Function(_Frame) mapper) {
  final frames = _parse(file);
  final tracker = BanknoteTracker(candidateMode: true);
  // Replica of main.dart _handleRealtimeSpeech signature gate (candidate: 3 frames).
  String pendingSig = '';
  int pendingCount = 0;
  String lastSpokenSig = '';
  final spoken = <Map<String, dynamic>>[];
  final perFrame = <Map<String, dynamic>>[];
  int confirmedFrames = 0;
  int correctConfirmedFrames = 0;
  int wrongConfirmedFrames = 0;
  int wrongSpoken = 0;

  for (final f in frames) {
    final dets = mapper(f);
    final r = tracker.updateWithSafety(dets, imageWidth: _w, imageHeight: _h);
    final a = r.assessment;
    if (a.isTotalConfirmed) {
      confirmedFrames++;
      if (a.confirmedTotalRupees == gtTotal) {
        correctConfirmedFrames++;
      } else {
        wrongConfirmedFrames++;
      }
    }

    String? spokeNow;
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
          spokeNow = a.spokenMessage;
          lastSpokenSig = sig;
          spoken.add({
            'frame': f.idx,
            'time': f.time,
            'status': a.status.name,
            'confirmed_total': a.confirmedTotalRupees,
            'speech': a.spokenMessage,
          });
          if (a.isTotalConfirmed && a.confirmedTotalRupees != gtTotal) wrongSpoken++;
        }
      }
    }

    perFrame.add({
      'frame': f.idx,
      'time': f.time,
      'raw': f.raw.map((x) => '${x.cls}:${x.conf.toStringAsFixed(2)}(m=${x.margin.toStringAsFixed(2)})').toList(),
      'old_status': f.oldStatus,
      'old_confTot': f.oldConfTot,
      'new_tracked': r.activeDetections
          .map((d) => '${d.denomination}:${d.confidence.toStringAsFixed(2)}[${d.confirmationState.name},v=${d.framesVisible}]')
          .toList(),
      'new_status': a.status.name,
      'new_confTot': a.confirmedTotalRupees,
      'new_visSum': a.visibleDetectedSumRupees,
      'new_reasons': a.reasons.toList(),
      'spoken_this_frame': spokeNow,
    });
  }

  final oldConfirmedFrames = frames.where((f) => f.oldConfTot != 'null').length;
  final oldCorrect = frames.where((f) => f.oldConfTot == '$gtTotal').length;
  return {
    'scenario': name,
    'gt_total': gtTotal,
    'frames': frames.length,
    'old_confirmed_frames': oldConfirmedFrames,
    'old_correct_confirmed_frames': oldCorrect,
    'new_confirmed_frames': confirmedFrames,
    'new_correct_confirmed_frames': correctConfirmedFrames,
    'new_wrong_confirmed_frames': wrongConfirmedFrames,
    'new_spoken': spoken,
    'new_wrong_spoken_totals': wrongSpoken,
    'per_frame': perFrame,
  };
}

void main() {
  test('Phase 4O.2 replay of recorded Phase 4O.1 live scenarios', () {
    final results = [
      _replay('S1_rs20_note_rs5_rs2_on_note', 'scenario_01_logcat.txt', 27, _mapS1),
      _replay('S2_handheld_rs1_rs2', 'scenario_02_logcat.txt', 3, _mapS2),
      _replay('S3_rs2_on_rbi_seal_rs20_note', 'scenario_03_logcat.txt', 22, _mapS3),
    ];
    final out = File(r'C:\VisionMission\experiments\phase4o\phase4o2\hardware\live_scenario_replay_4o2.json');
    out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(results));
    for (final r in results) {
      print('[REPLAY] ${r['scenario']} gt=${r['gt_total']} frames=${r['frames']} '
          'old_conf=${r['old_confirmed_frames']}(correct ${r['old_correct_confirmed_frames']}) '
          'new_conf=${r['new_confirmed_frames']}(correct ${r['new_correct_confirmed_frames']}, wrong ${r['new_wrong_confirmed_frames']}) '
          'wrong_spoken=${r['new_wrong_spoken_totals']} spoken=${jsonEncode(r['new_spoken'])}');
    }
    // Safety acceptance: no wrong confirmed total may ever be spoken.
    for (final r in results) {
      expect(r['new_wrong_spoken_totals'], 0, reason: '${r['scenario']} spoke a wrong total');
    }
  }, skip: !File('$_dir\\scenario_01_logcat.txt').existsSync() ||
      !File('$_dir\\scenario_02_logcat.txt').existsSync() ||
      !File('$_dir\\scenario_03_logcat.txt').existsSync()
      ? 'Requires local Phase 4O physical-device logcat fixtures, which are not distributed in the public source repository.'
      : false);

  test('Phase 4O.3.1 replay of Phase 4O.3 Scene 4 isolated coin (#383-#404)', () {
    final lines = File(r'C:\VisionMission\experiments\phase4o\live_camera_4o3\logs\scene4_raw.log')
        .readAsLinesSync();
    final rawEntry = RegExp(r'(INR_\w+?):([\d.]+)\(m=([\d.]+),(\w+)\)');
    final tracker = BanknoteTracker(candidateMode: true);
    int confirmedTwoCount = 0;
    int incompleteCount = 0;
    int wrongConfirmed = 0;

    for (final l in lines) {
      if (!l.contains('[LIVE-AUDIT]')) continue;
      final idx = int.parse(RegExp(r'\[LIVE-AUDIT\] #(\d+)').firstMatch(l)!.group(1)!);
      if (idx < 383 || idx > 404) continue;
      final rawPart = RegExp(r'raw=\[(.*?)\] trk=').firstMatch(l)!.group(1)!;
      final dets = rawEntry.allMatches(rawPart).map((m) {
        final cls = m.group(1)!;
        final conf = double.parse(m.group(2)!);
        final margin = double.parse(m.group(3)!);
        final isCoin = cls.endsWith('_COIN');
        final clsIdx = CurrencyModelService.classNames.indexOf(cls);
        return CurrencyDetection(
          classId: clsIdx,
          denomination: cls,
          value: CurrencyModelService.denominationValues[clsIdx],
          confidence: conf,
          x1: isCoin ? 200 : 50,
          y1: isCoin ? 500 : 900,
          x2: isCoin ? 520 : 680,
          y2: isCoin ? 820 : 1200,
          type: isCoin ? 'coin' : 'banknote',
          top2Confidence: (conf - margin).clamp(0.0, 1.0),
          classMargin: margin,
        );
      }).toList();

      final res = tracker.updateWithSafety(dets, imageWidth: _w, imageHeight: _h);
      if (res.assessment.reasons.contains('INCOMPLETE_SCENE')) {
        incompleteCount++;
      }
      if (res.assessment.isTotalConfirmed) {
        if (res.assessment.confirmedTotalRupees == 2) {
          confirmedTwoCount++;
        } else {
          wrongConfirmed++;
        }
      }
    }

    print('[REPLAY-4O3-S4] frames=22 confirmed_rs2=$confirmedTwoCount incomplete=$incompleteCount wrong=$wrongConfirmed');
    expect(incompleteCount, 0);
    expect(wrongConfirmed, 0);
    expect(confirmedTwoCount, greaterThanOrEqualTo(15));
  }, skip: !File(r'C:\VisionMission\experiments\phase4o\live_camera_4o3\logs\scene4_raw.log').existsSync()
      ? 'Requires local Phase 4O.3 physical-device logcat fixture, which is not distributed in the public source repository.'
      : false);
}

