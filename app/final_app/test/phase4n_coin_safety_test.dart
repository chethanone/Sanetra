import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vision_assistant/services/banknote_tracker.dart';
import 'package:vision_assistant/services/currency_model_service.dart';
import 'package:vision_assistant/services/currency_safety_evaluator.dart';

CurrencyDetection _coin({
  int classId = 8,
  String denomination = 'INR_5_COIN',
  int value = 5,
  required double confidence,
  double classMargin = 0.65,
  double x1 = 400,
  double y1 = 250,
  double x2 = 520,
  double y2 = 370,
  double suppressedConflictConfidence = 0.0,
  int suppressedConflictClassId = -1,
  String suppressedConflictClassName = '',
  double interBoxMaxIoU = 0.0,
  double interBoxMaxIoMin = 0.0,
  DetectionConfirmationState confirmationState =
      DetectionConfirmationState.confirmed,
  List<String> uncertaintyReasons = const [],
}) {
  return CurrencyDetection(
    classId: classId,
    denomination: denomination,
    value: value,
    confidence: confidence,
    x1: x1,
    y1: y1,
    x2: x2,
    y2: y2,
    type: 'coin',
    classMargin: classMargin,
    suppressedConflictConfidence: suppressedConflictConfidence,
    suppressedConflictClassId: suppressedConflictClassId,
    suppressedConflictClassName: suppressedConflictClassName,
    interBoxMaxIoU: interBoxMaxIoU,
    interBoxMaxIoMin: interBoxMaxIoMin,
    confirmationState: confirmationState,
    uncertaintyReasons: uncertaintyReasons,
  );
}

CurrencyDetection _note({
  int classId = 0,
  String denomination = 'INR_10',
  int value = 10,
  required double confidence,
  double classMargin = 0.70,
  double x1 = 100,
  double y1 = 100,
  double x2 = 500,
  double y2 = 350,
}) {
  return CurrencyDetection(
    classId: classId,
    denomination: denomination,
    value: value,
    confidence: confidence,
    x1: x1,
    y1: y1,
    x2: x2,
    y2: y2,
    type: 'banknote',
    classMargin: classMargin,
  );
}

void main() {
  group('Phase 4N Candidate Coin Safety Screening', () {
    test('rejects low-confidence (<0.60) and narrow-margin (<0.15) coin candidates', () {
      final lowConfCoin = _coin(confidence: 0.55, classMargin: 0.50);
      final resLowConf = CurrencySafetyEvaluator.evaluate(
        [lowConfCoin],
        candidateMode: true,
        imageWidth: 1280,
        imageHeight: 720,
      );
      expect(resLowConf.isTotalConfirmed, isFalse);
      expect(resLowConf.confirmedTotalRupees, isNull);
      expect(resLowConf.reasons, contains('LOW_CONFIDENCE'));
      expect(
        resLowConf.screenedDetections.first.confirmationState,
        DetectionConfirmationState.tentative,
      );

      final narrowMarginCoin = _coin(confidence: 0.85, classMargin: 0.10);
      final resMargin = CurrencySafetyEvaluator.evaluate(
        [narrowMarginCoin],
        candidateMode: true,
        imageWidth: 1280,
        imageHeight: 720,
      );
      expect(resMargin.isTotalConfirmed, isFalse);
      expect(resMargin.confirmedTotalRupees, isNull);
      expect(resMargin.reasons, contains('NARROW_CLASS_MARGIN'));
      expect(
        resMargin.screenedDetections.first.confirmationState,
        DetectionConfirmationState.tentative,
      );
    });

    test('flags coin-coin OVERLAP_CONFLICT and suppressed CROSS_CLASS_CONFLICT', () {
      final c1 = _coin(
        denomination: 'INR_5_COIN',
        value: 5,
        confidence: 0.88,
        x1: 300,
        y1: 200,
        x2: 430,
        y2: 330,
      );
      final c2 = _coin(
        classId: 9,
        denomination: 'INR_10_COIN',
        value: 10,
        confidence: 0.86,
        x1: 320,
        y1: 210,
        x2: 450,
        y2: 340,
      );
      final overlapRes = CurrencySafetyEvaluator.evaluate(
        [c1, c2],
        candidateMode: true,
        imageWidth: 1280,
        imageHeight: 720,
      );
      expect(overlapRes.isTotalConfirmed, isFalse);
      expect(overlapRes.reasons, contains('OVERLAP_CONFLICT'));
      expect(overlapRes.conflictingCount, 2);

      final supRes = CurrencySafetyEvaluator.evaluate(
        [
          _coin(
            confidence: 0.84,
            classMargin: 0.45,
            suppressedConflictConfidence: 0.36,
            suppressedConflictClassId: 7,
            suppressedConflictClassName: 'INR_2_COIN',
          ),
        ],
        candidateMode: true,
        imageWidth: 1280,
        imageHeight: 720,
      );
      expect(supRes.isTotalConfirmed, isFalse);
      expect(supRes.reasons, contains('CROSS_CLASS_CONFLICT'));
      expect(
        supRes.screenedDetections.first.confirmationState,
        DetectionConfirmationState.conflicting,
      );
    });

    test('blocks CROSS_MODEL_BANKNOTE_CONFLICT on 3x INR_10 + 2x spurious INR_10_COIN', () {
      // Simulates Phase 4M failure where printed "10" / seal on notes triggers coin FPs
      final notes = [
        _note(confidence: 0.90, x1: 80, y1: 100, x2: 460, y2: 320),
        _note(confidence: 0.88, x1: 480, y1: 100, x2: 860, y2: 320),
        _note(confidence: 0.89, x1: 880, y1: 100, x2: 1240, y2: 320),
      ];
      // Even with artificially high coin confidence (>=0.75), containment + small area flags conflict
      final fakeCoins = [
        _coin(
          classId: 9,
          denomination: 'INR_10_COIN',
          value: 10,
          confidence: 0.80,
          x1: 350,
          y1: 200,
          x2: 420,
          y2: 270, // 70x70 = 4900px / (1280*720=921600) = 0.0053 < 0.035, inside note 1
        ),
        _coin(
          classId: 9,
          denomination: 'INR_10_COIN',
          value: 10,
          confidence: 0.78,
          x1: 750,
          y1: 200,
          x2: 820,
          y2: 270, // inside note 2
        ),
      ];
      final res = CurrencySafetyEvaluator.evaluate(
        [...notes, ...fakeCoins],
        candidateMode: true,
        imageWidth: 1280,
        imageHeight: 720,
      );
      expect(res.isTotalConfirmed, isFalse);
      expect(res.confirmedTotalRupees, isNull);
      expect(res.reasons, contains('CROSS_MODEL_BANKNOTE_CONFLICT'));
      expect(res.status, AnnouncementSafetyStatus.conflictingOrUncertain);
    });

    test('flags COIN_EXTREME_ASPECT_RATIO and SMALL_COIN_AREA when frame dims known', () {
      final stretched = _coin(
        confidence: 0.85,
        classMargin: 0.50,
        x1: 300,
        y1: 200,
        x2: 350,
        y2: 350, // AR = 50 / 150 = 0.333 < 0.60
      );
      final arRes = CurrencySafetyEvaluator.evaluate(
        [stretched],
        candidateMode: true,
        imageWidth: 1280,
        imageHeight: 720,
      );
      expect(arRes.isTotalConfirmed, isFalse);
      expect(arRes.reasons, contains('COIN_EXTREME_ASPECT_RATIO'));

      final tiny = _coin(
        confidence: 0.85,
        classMargin: 0.50,
        x1: 300,
        y1: 200,
        x2: 330,
        y2: 230, // 900 / 921600 = 0.000977 < 0.002
      );
      final tinyRes = CurrencySafetyEvaluator.evaluate(
        [tiny],
        candidateMode: true,
        imageWidth: 1280,
        imageHeight: 720,
      );
      expect(tinyRes.isTotalConfirmed, isFalse);
      expect(tinyRes.reasons, contains('SMALL_COIN_AREA'));
    });

    test('allows high-confidence clean coin through safety + tracker when >=0.60 and clear', () {
      final cleanCoin = _coin(
        classId: 9,
        denomination: 'INR_10_COIN',
        value: 10,
        confidence: 0.84,
        classMargin: 0.55,
        x1: 400,
        y1: 220,
        x2: 540,
        y2: 360, // 140x140 = 19600 / 921600 = 0.0213 >= 0.005, AR = 1.0
      );
      final evalRes = CurrencySafetyEvaluator.evaluate(
        [cleanCoin],
        candidateMode: true,
        imageWidth: 1280,
        imageHeight: 720,
      );
      expect(evalRes.isTotalConfirmed, isTrue);
      expect(evalRes.confirmedTotalRupees, 10);
      expect(evalRes.status, AnnouncementSafetyStatus.confirmedSingle);

      final tracker = BanknoteTracker(candidateMode: true);
      final t1 = tracker.updateWithSafety([cleanCoin], imageWidth: 1280, imageHeight: 720);
      final t2 = tracker.updateWithSafety([cleanCoin], imageWidth: 1280, imageHeight: 720);
      expect(t1.assessment.isTotalConfirmed, isTrue);
      expect(t2.assessment.confirmedTotalRupees, 10);
    });

    test('preserves production baseline behavior completely when candidateMode is false', () {
      final lowMarginWeakCoin = _coin(
        confidence: 0.52,
        classMargin: 0.05,
        x1: 100,
        y1: 100,
        x2: 120,
        y2: 170, // tiny & distorted, would fail candidate screening
      );
      final prodRes = CurrencySafetyEvaluator.evaluate(
        [lowMarginWeakCoin],
        candidateMode: false,
        imageWidth: 1280,
        imageHeight: 720,
      );
      expect(prodRes.isTotalConfirmed, isTrue);
      expect(prodRes.confirmedTotalRupees, 5);
      expect(prodRes.reasons, isEmpty);
    });

    test('replays all 31 reproduced coin FPs across all 20 Phase 4M scenes with 0 confirmed', () {
      final fixtureFile = File(
        r'C:\VisionMission\experiments\phase4n\phase4n_20scenes_replay_fixture.json',
      );
      expect(fixtureFile.existsSync(), isTrue);
      final scenes = jsonDecode(fixtureFile.readAsStringSync()) as List<dynamic>;
      expect(scenes.length, 20);

      int totalCoinFpsReplayed = 0;
      int confirmedCoinsCount = 0;
      int coinInflatedEvalScenes = 0;
      int coinInflatedTrackerScenes = 0;

      for (final rawScene in scenes) {
        final scene = rawScene as Map<String, dynamic>;
        final imgW = scene['imageWidth'] as int;
        final imgH = scene['imageHeight'] as int;
        final notes = (scene['banknotes'] as List<dynamic>).map((n) {
          final m = n as Map<String, dynamic>;
          final bx = (m['box'] as List<dynamic>).cast<num>();
          return CurrencyDetection(
            classId: m['classId'] as int,
            denomination: m['denomination'] as String,
            value: m['value'] as int,
            confidence: (m['confidence'] as num).toDouble(),
            x1: bx[0].toDouble(),
            y1: bx[1].toDouble(),
            x2: bx[2].toDouble(),
            y2: bx[3].toDouble(),
            type: 'banknote',
            top2ClassId: m['top2ClassId'] as int,
            top2ClassName: m['top2ClassName'] as String,
            top2Confidence: (m['top2Confidence'] as num).toDouble(),
            classMargin: (m['classMargin'] as num).toDouble(),
            suppressedConflictCount: m['suppressedConflictCount'] as int,
            suppressedConflictClassId: m['suppressedConflictClassId'] as int,
            suppressedConflictClassName: m['suppressedConflictClassName'] as String,
            suppressedConflictConfidence:
                (m['suppressedConflictConfidence'] as num).toDouble(),
          );
        }).toList();

        final coins = (scene['recordedCoinFps'] as List<dynamic>).map((c) {
          final m = c as Map<String, dynamic>;
          final bx = (m['box'] as List<dynamic>).cast<num>();
          return CurrencyDetection(
            classId: m['classId'] as int,
            denomination: m['denomination'] as String,
            value: m['value'] as int,
            confidence: (m['confidence'] as num).toDouble(),
            x1: bx[0].toDouble(),
            y1: bx[1].toDouble(),
            x2: bx[2].toDouble(),
            y2: bx[3].toDouble(),
            type: 'coin',
            top2ClassId: m['top2ClassId'] as int,
            top2ClassName: m['top2ClassName'] as String,
            top2Confidence: (m['top2Confidence'] as num).toDouble(),
            classMargin: (m['classMargin'] as num).toDouble(),
            suppressedConflictCount: m['suppressedConflictCount'] as int,
            suppressedConflictClassId: m['suppressedConflictClassId'] as int,
            suppressedConflictClassName: m['suppressedConflictClassName'] as String,
            suppressedConflictConfidence:
                (m['suppressedConflictConfidence'] as num).toDouble(),
          );
        }).toList();

        totalCoinFpsReplayed += coins.length;
        final evalRes = CurrencySafetyEvaluator.evaluate(
          [...notes, ...coins],
          candidateMode: true,
          imageWidth: imgW,
          imageHeight: imgH,
        );

        final screenedCoins =
            evalRes.screenedDetections.where((d) => d.isCoin).toList();
        expect(screenedCoins.length, coins.length);
        for (final sc in screenedCoins) {
          if (sc.isConfirmed) {
            confirmedCoinsCount++;
          }
          expect(sc.isConfirmed, isFalse, reason: 'Coin FP confirmed in ${scene['file']}');
        }
        if (evalRes.isTotalConfirmed) {
          coinInflatedEvalScenes++;
        }

        // Also test multi-frame BanknoteTracker temporal stability with the coin FPs present
        final tracker = BanknoteTracker(candidateMode: true);
        TrackerUpdateResult? lastRes;
        for (int f = 0; f < 3; f++) {
          lastRes = tracker.updateWithSafety(
            [...notes, ...coins],
            imageWidth: imgW,
            imageHeight: imgH,
          );
        }
        if (lastRes!.assessment.isTotalConfirmed) {
          coinInflatedTrackerScenes++;
        }
      }

      expect(totalCoinFpsReplayed, 31);
      expect(confirmedCoinsCount, 0);
      expect(coinInflatedEvalScenes, 0);
      expect(coinInflatedTrackerScenes, 0);
    });
  });

  group('Phase 4O.1 Targeted Forensic Regressions (Case A & Case B)', () {
    test('Case A: blocks small/weak RBI-seal coin FP inside banknote while keeping genuine adjacent coin safe', () {
      // Banknote with interior tiny RBI-seal FP at 0.49% frame area (< 1.2% genuine coin-on-note floor)
      const int w = 1000;
      const int h = 1000;
      final note50 = _note(
        classId: 2,
        denomination: 'INR_50',
        value: 50,
        confidence: 0.80,
        x1: 240,
        y1: 200,
        x2: 980,
        y2: 800, // 44.4% frame area
      );
      final interiorSealFp = _coin(
        classId: 8,
        denomination: 'INR_5_COIN',
        value: 5,
        confidence: 0.70,
        x1: 600,
        y1: 350,
        x2: 670,
        y2: 420, // 70x70 = 0.49% frame area (< 1.2%), IoMin=1.0 inside note50
      );
      final interiorRes = CurrencySafetyEvaluator.evaluate(
        [note50, interiorSealFp],
        candidateMode: true,
        imageWidth: w,
        imageHeight: h,
      );
      expect(interiorRes.isTotalConfirmed, isFalse);
      expect(interiorRes.confirmedTotalRupees, isNull);
      expect(interiorRes.reasons, contains('CROSS_MODEL_BANKNOTE_CONFLICT'));
      expect(
        interiorRes.screenedDetections.where((d) => d.isCoin).first.confirmationState,
        DetectionConfirmationState.conflicting,
      );

      // Genuine mixed scene: adjacent coin lying beside tilted note (IoMin < 0.70) must remain confirmed
      final adjacentGenuineCoin = _coin(
        classId: 8,
        denomination: 'INR_5_COIN',
        value: 5,
        confidence: 0.70,
        x1: 120,
        y1: 450,
        x2: 290,
        y2: 620, // IoMin with note50 ~ 50*170 / 28900 = 0.294 < 0.70
      );
      final mixedRes = CurrencySafetyEvaluator.evaluate(
        [note50, adjacentGenuineCoin],
        candidateMode: true,
        imageWidth: w,
        imageHeight: h,
      );
      expect(mixedRes.isTotalConfirmed, isTrue);
      expect(mixedRes.confirmedTotalRupees, 55);
    });

    test('Case B: blocks spurious oversized INR_20 + INR_10_COIN combined Rs 30 total and preserves standalone Rs 10 coin', () {
      // Exact geometry from 020_single_coins_coin_10_rupee_IMG_E0380JPG.jpg (scaled 256x256 -> 1000x1000)
      const int w = 256;
      const int h = 256;
      final genuineTenCoin = _coin(
        classId: 9,
        denomination: 'INR_10_COIN',
        value: 10,
        confidence: 0.8234,
        classMargin: 0.8218,
        x1: 89.5,
        y1: 118.8,
        x2: 137.4,
        y2: 168.6, // 3.64% of frame
      );
      final spuriousFullNote20 = _note(
        classId: 1,
        denomination: 'INR_20',
        value: 20,
        confidence: 0.7544,
        classMargin: 0.7512,
        x1: 9.4,
        y1: 0.8,
        x2: 254.9,
        y2: 206.1, // 76.88% of frame, swallows coin completely (IoMin = 1.0)
      );

      // Even if a >=72% banknote survives into Dart safety evaluation, Rs 30 confirmation MUST be blocked
      final safetyRes = CurrencySafetyEvaluator.evaluate(
        [spuriousFullNote20, genuineTenCoin],
        candidateMode: true,
        imageWidth: w,
        imageHeight: h,
      );
      expect(safetyRes.isTotalConfirmed, isFalse);
      expect(safetyRes.confirmedTotalRupees, isNull);
      expect(safetyRes.reasons, contains('CROSS_MODEL_BANKNOTE_CONFLICT'));

      // Multi-frame tracker regression check across 3 frames: never emit confirmed Rs 30
      final tracker = BanknoteTracker(candidateMode: true);
      late TrackerUpdateResult trkRes;
      for (int f = 0; f < 3; f++) {
        trkRes = tracker.updateWithSafety(
          [spuriousFullNote20, genuineTenCoin],
          imageWidth: w,
          imageHeight: h,
        );
      }
      expect(trkRes.assessment.isTotalConfirmed, isFalse);
      expect(trkRes.assessment.confirmedTotalRupees, isNull);

      // Once native wrapper filter suppresses the spurious INR_20, standalone genuine INR_10_COIN confirms cleanly at Rs 10
      final standaloneRes = CurrencySafetyEvaluator.evaluate(
        [genuineTenCoin],
        candidateMode: true,
        imageWidth: w,
        imageHeight: h,
      );
      expect(standaloneRes.isTotalConfirmed, isTrue);
      expect(standaloneRes.confirmedTotalRupees, 10);
    });
  });

  group('Phase 4O.2 Coin Stability & Note-Coin Overlap Regressions', () {
    test('Scenario 1 & 3: confirms genuine coins placed on a normal banknote (Rs 27 and Rs 22) while blocking weak/tiny seal FPs', () {
      const int w = 720;
      const int h = 1280;
      final note20 = _note(
        classId: 1,
        denomination: 'INR_20',
        value: 20,
        confidence: 0.85,
        classMargin: 0.85,
        x1: 40,
        y1: 350,
        x2: 680,
        y2: 750, // 27.8% of frame (< 72% wrapper cap)
      );
      final coin5OnNote = _coin(
        classId: 8,
        denomination: 'INR_5_COIN',
        value: 5,
        confidence: 0.68,
        classMargin: 0.63,
        x1: 130,
        y1: 500,
        x2: 290,
        y2: 660, // 2.78% of frame, IoMin=1.0 inside note20
      );
      final coin2OnSeal = _coin(
        classId: 7,
        denomination: 'INR_2_COIN',
        value: 2,
        confidence: 0.78,
        classMargin: 0.72,
        x1: 450,
        y1: 480,
        x2: 620,
        y2: 650, // 3.14% of frame, IoMin=1.0 inside note20 over RBI seal
      );

      // Scenario 3: Rs 20 note + Rs 2 coin over RBI seal => Rs 22 confirmed
      final s3 = CurrencySafetyEvaluator.evaluate(
        [note20, coin2OnSeal],
        candidateMode: true,
        imageWidth: w,
        imageHeight: h,
      );
      expect(s3.isTotalConfirmed, isTrue);
      expect(s3.confirmedTotalRupees, 22);

      // Scenario 1: Rs 20 note + Rs 5 coin + Rs 2 coin => Rs 27 confirmed
      final s1 = CurrencySafetyEvaluator.evaluate(
        [note20, coin5OnNote, coin2OnSeal],
        candidateMode: true,
        imageWidth: w,
        imageHeight: h,
      );
      expect(s1.isTotalConfirmed, isTrue);
      expect(s1.confirmedTotalRupees, 27);

      // Narrow-margin coin-like seal inside note must still be blocked
      final weakMarginSeal = _coin(
        classId: 7,
        denomination: 'INR_2_COIN',
        value: 2,
        confidence: 0.65,
        classMargin: 0.18, // < 0.25 coin-on-note margin floor
        x1: 450,
        y1: 480,
        x2: 620,
        y2: 650,
      );
      final blocked = CurrencySafetyEvaluator.evaluate(
        [note20, weakMarginSeal],
        candidateMode: true,
        imageWidth: w,
        imageHeight: h,
      );
      expect(blocked.isTotalConfirmed, isFalse);
      expect(blocked.reasons, contains('CROSS_MODEL_BANKNOTE_CONFLICT'));
    });

    test('Scenario 2: temporal coin tracker resists wrong-total lock-in during oscillation and stabilizes Rs 1 + Rs 2 => Rs 3', () {
      const int w = 720;
      const int h = 1280;
      final tracker = BanknoteTracker(candidateMode: true);

      CurrencyDetection bottomCoin2(double conf) => _coin(
            classId: 7,
            denomination: 'INR_2_COIN',
            value: 2,
            confidence: conf,
            classMargin: 0.65,
            x1: 220,
            y1: 760,
            x2: 460,
            y2: 1000,
          );

      CurrencyDetection topCoin(int clsId, String denom, int val, double conf, double margin) => _coin(
            classId: clsId,
            denomination: denom,
            value: val,
            confidence: conf,
            classMargin: margin,
            x1: 230,
            y1: 360,
            x2: 470,
            y2: 600,
          );

      // Oscillating top coin (INR_1_COIN vs INR_2_COIN) must stay unconfirmed (never confirm Rs 4)
      final oscSeq = [
        [topCoin(7, 'INR_2_COIN', 2, 0.79, 0.28), bottomCoin2(0.75)],
        [topCoin(6, 'INR_1_COIN', 1, 0.76, 0.35), bottomCoin2(0.84)],
        [topCoin(7, 'INR_2_COIN', 2, 0.78, 0.28), bottomCoin2(0.76)],
        [topCoin(6, 'INR_1_COIN', 1, 0.78, 0.40), bottomCoin2(0.72)],
      ];
      for (int f = 0; f < oscSeq.length; f++) {
        final res = tracker.updateWithSafety(oscSeq[f], imageWidth: w, imageHeight: h);
        if (f >= 1) {
          expect(res.assessment.isTotalConfirmed, isFalse);
          expect(res.assessment.confirmedTotalRupees, isNull);
          expect(res.assessment.reasons, contains('CLASS_OSCILLATION'));
        }
      }

      // Now a genuine Rs 1 coin stabilizes after a single 1-frame weak flicker -> confirms Rs 3 without ghosting
      tracker.reset();
      late TrackerUpdateResult stableRes;
      final cleanSeq = [
        [topCoin(6, 'INR_1_COIN', 1, 0.80, 0.65), bottomCoin2(0.82)],
        [topCoin(6, 'INR_1_COIN', 1, 0.82, 0.68), bottomCoin2(0.84)],
        [topCoin(6, 'INR_1_COIN', 1, 0.83, 0.70), bottomCoin2(0.81)],
        [topCoin(7, 'INR_2_COIN', 2, 0.48, 0.16), bottomCoin2(0.80)], // brief flicker
        [topCoin(6, 'INR_1_COIN', 1, 0.81, 0.68), bottomCoin2(0.83)],
        [topCoin(6, 'INR_1_COIN', 1, 0.84, 0.72), bottomCoin2(0.85)],
      ];
      for (final frame in cleanSeq) {
        stableRes = tracker.updateWithSafety(frame, imageWidth: w, imageHeight: h);
      }
      expect(stableRes.assessment.isTotalConfirmed, isTrue);
      expect(stableRes.assessment.confirmedTotalRupees, 3);

      // Brief 1-frame miss of bottom coin does not emit ghost coin, and empty scene clears tracks cleanly
      final miss1 = tracker.updateWithSafety(
        [topCoin(6, 'INR_1_COIN', 1, 0.83, 0.70)],
        imageWidth: w,
        imageHeight: h,
      );
      expect(miss1.activeTrackCount, 1);
      final recovered = tracker.updateWithSafety(
        [topCoin(6, 'INR_1_COIN', 1, 0.83, 0.70), bottomCoin2(0.84)],
        imageWidth: w,
        imageHeight: h,
      );
      expect(recovered.assessment.isTotalConfirmed, isTrue);
      expect(recovered.assessment.confirmedTotalRupees, 3);
      expect(recovered.activeDetections.where((d) => d.denomination == 'INR_2_COIN').first.framesVisible, greaterThanOrEqualTo(7));
    });
  });

  group('Phase 4O.3 Scene Completeness & Partial Announcement Prevention', () {
    test('prevents partial banknote announcement when a previously visible coin briefly disappears, while keeping single-item scenes prompt', () {
      const int w = 720;
      const int h = 1280;

      // 1. Genuinely single-banknote scene confirms immediately without delay
      final singleNoteTracker = BanknoteTracker(candidateMode: true);
      final note50 = _note(
        classId: 2,
        denomination: 'INR_50',
        value: 50,
        confidence: 0.88,
        classMargin: 0.88,
        x1: 60,
        y1: 350,
        x2: 660,
        y2: 750,
      );
      final singleNoteRes = singleNoteTracker.updateWithSafety([note50], imageWidth: w, imageHeight: h);
      expect(singleNoteRes.assessment.isTotalConfirmed, isTrue);
      expect(singleNoteRes.assessment.confirmedTotalRupees, 50);

      // 2. Genuinely single-coin scene confirms immediately without delay
      final singleCoinTracker = BanknoteTracker(candidateMode: true);
      final coin5 = _coin(
        classId: 8,
        denomination: 'INR_5_COIN',
        value: 5,
        confidence: 0.82,
        classMargin: 0.70,
        x1: 260,
        y1: 500,
        x2: 420,
        y2: 660,
      );
      final singleCoinRes = singleCoinTracker.updateWithSafety([coin5], imageWidth: w, imageHeight: h);
      expect(singleCoinRes.assessment.isTotalConfirmed, isTrue);
      expect(singleCoinRes.assessment.confirmedTotalRupees, 5);

      // 3. Multi-object scene (Rs 20 note + Rs 5 coin): coin disappears for 3 frames -> never confirms partial Rs 20 or ghosts Rs 5
      final multiTracker = BanknoteTracker(candidateMode: true);
      final note20 = _note(
        classId: 1,
        denomination: 'INR_20',
        value: 20,
        confidence: 0.86,
        classMargin: 0.86,
        x1: 60,
        y1: 380,
        x2: 650,
        y2: 760,
      );
      final coin5OnNote = _coin(
        classId: 8,
        denomination: 'INR_5_COIN',
        value: 5,
        confidence: 0.72,
        classMargin: 0.65,
        x1: 180,
        y1: 540,
        x2: 330,
        y2: 690,
      );
      final initial1 = multiTracker.updateWithSafety([note20, coin5OnNote], imageWidth: w, imageHeight: h);
      expect(initial1.assessment.isTotalConfirmed, isTrue);
      final initial = multiTracker.updateWithSafety([note20, coin5OnNote], imageWidth: w, imageHeight: h);
      expect(initial.assessment.isTotalConfirmed, isTrue);
      expect(initial.assessment.confirmedTotalRupees, 25);

      for (int miss = 0; miss < 3; miss++) {
        final partial = multiTracker.updateWithSafety([note20], imageWidth: w, imageHeight: h);
        expect(partial.activeTrackCount, 1); // Never emits ghost coin
        expect(partial.assessment.isTotalConfirmed, isFalse);
        expect(partial.assessment.confirmedTotalRupees, isNull);
        expect(partial.assessment.reasons, contains('INCOMPLETE_SCENE'));
      }

      // 4. Empty scene clears all tracks and incomplete-scene cooldown immediately
      final emptyRes = multiTracker.updateWithSafety([], imageWidth: w, imageHeight: h);
      expect(emptyRes.activeTrackCount, 0);
      expect(emptyRes.assessment.status, AnnouncementSafetyStatus.empty);

      final freshNoteRes = multiTracker.updateWithSafety([note50], imageWidth: w, imageHeight: h);
      expect(freshNoteRes.assessment.isTotalConfirmed, isTrue);
      expect(freshNoteRes.assessment.confirmedTotalRupees, 50);
    });
  });

  group('Phase 4O.3.1 Scene-Completeness Cooldown State Machine (A-G)', () {
    const int w = 720;
    const int h = 1280;

    final note20 = _note(
      classId: 1,
      denomination: 'INR_20',
      value: 20,
      confidence: 0.88,
      classMargin: 0.85,
      x1: 60,
      y1: 380,
      x2: 650,
      y2: 760,
    );
    final coin5 = _coin(
      classId: 8,
      denomination: 'INR_5_COIN',
      value: 5,
      confidence: 0.80,
      classMargin: 0.70,
      x1: 180,
      y1: 540,
      x2: 330,
      y2: 690,
    );
    final coin2 = _coin(
      classId: 7,
      denomination: 'INR_2_COIN',
      value: 2,
      confidence: 0.85,
      classMargin: 0.78,
      x1: 280,
      y1: 540,
      x2: 430,
      y2: 690,
    );
    final spuriousNote50 = _note(
      classId: 2,
      denomination: 'INR_50',
      value: 50,
      confidence: 0.31,
      classMargin: 0.31,
      x1: 50,
      y1: 900,
      x2: 680,
      y2: 1200,
    );

    test('A. Stable two-object scene -> one object expires after 4 frames and confirms remaining object', () {
      final t = BanknoteTracker(candidateMode: true);
      t.updateWithSafety([note20, coin5], imageWidth: w, imageHeight: h);
      t.updateWithSafety([note20, coin5], imageWidth: w, imageHeight: h);

      for (int f = 0; f < 4; f++) {
        final res = t.updateWithSafety([note20], imageWidth: w, imageHeight: h);
        expect(res.activeTrackCount, 1);
        expect(res.assessment.isTotalConfirmed, isFalse, reason: 'cooldown frame $f');
        expect(res.assessment.confirmedTotalRupees, isNull);
        expect(res.assessment.reasons, contains('INCOMPLETE_SCENE'));
      }

      // Frame 5: cooldown expires, genuine single note confirms without needing empty frame
      final recovered = t.updateWithSafety([note20], imageWidth: w, imageHeight: h);
      expect(recovered.assessment.reasons, isNot(contains('INCOMPLETE_SCENE')));
      expect(recovered.assessment.isTotalConfirmed, isTrue);
      expect(recovered.assessment.confirmedTotalRupees, 20);
      expect(recovered.assessment.spokenMessage, '20 Rupee Note');
    });

    test('B. Stable two-object scene -> one object -> second object returns clears incomplete state immediately', () {
      final t = BanknoteTracker(candidateMode: true);
      t.updateWithSafety([note20, coin5], imageWidth: w, imageHeight: h);
      t.updateWithSafety([note20, coin5], imageWidth: w, imageHeight: h);

      final drop = t.updateWithSafety([note20], imageWidth: w, imageHeight: h);
      expect(drop.assessment.reasons, contains('INCOMPLETE_SCENE'));
      expect(drop.assessment.isTotalConfirmed, isFalse);

      final restored = t.updateWithSafety([note20, coin5], imageWidth: w, imageHeight: h);
      expect(restored.assessment.reasons, isNot(contains('INCOMPLETE_SCENE')));
      expect(restored.assessment.isTotalConfirmed, isTrue);
      expect(restored.assessment.confirmedTotalRupees, 25);
    });

    test('C. One-frame false detection followed by one stable coin never latches INCOMPLETE_SCENE', () {
      final t = BanknoteTracker(candidateMode: true);
      t.updateWithSafety([spuriousNote50, coin2], imageWidth: w, imageHeight: h);

      for (int f = 0; f < 6; f++) {
        final res = t.updateWithSafety([coin2], imageWidth: w, imageHeight: h);
        expect(res.assessment.reasons, isNot(contains('INCOMPLETE_SCENE')));
        expect(res.assessment.isTotalConfirmed, isTrue);
        expect(res.assessment.confirmedTotalRupees, 2);
        expect(res.assessment.spokenMessage, '2 Rupee Coin');
      }
    });

    test('D & E. Empty scene clears state; two-frame loss does not emit premature partial announcement', () {
      final t = BanknoteTracker(candidateMode: true);
      t.updateWithSafety([note20, coin5], imageWidth: w, imageHeight: h);
      t.updateWithSafety([note20, coin5], imageWidth: w, imageHeight: h);

      for (int f = 0; f < 2; f++) {
        final res = t.updateWithSafety([note20], imageWidth: w, imageHeight: h);
        expect(res.assessment.isTotalConfirmed, isFalse);
        expect(res.assessment.confirmedTotalRupees, isNull);
        expect(res.assessment.reasons, contains('INCOMPLETE_SCENE'));
      }

      final empty = t.updateWithSafety([], imageWidth: w, imageHeight: h);
      expect(empty.activeTrackCount, 0);
      expect(empty.assessment.confirmedTotalRupees, isNull);
      expect(empty.assessment.reasons, isEmpty);
    });

    test('F. Genuine single note and genuine single coin confirm promptly without cooldown delay', () {
      final tNote = BanknoteTracker(candidateMode: true);
      final nRes = tNote.updateWithSafety([note20], imageWidth: w, imageHeight: h);
      expect(nRes.assessment.isTotalConfirmed, isTrue);
      expect(nRes.assessment.confirmedTotalRupees, 20);

      final tCoin = BanknoteTracker(candidateMode: true);
      final cRes = tCoin.updateWithSafety([coin2], imageWidth: w, imageHeight: h);
      expect(cRes.assessment.isTotalConfirmed, isTrue);
      expect(cRes.assessment.confirmedTotalRupees, 2);
    });

    test('G. Repeated missing-object and recovery cycles + reset() arm, expire, and re-arm cleanly', () {
      final t = BanknoteTracker(candidateMode: true);
      // Cycle 1: stabilize 2 objects -> drop -> expire -> confirm 1 object
      t.updateWithSafety([note20, coin5], imageWidth: w, imageHeight: h);
      t.updateWithSafety([note20, coin5], imageWidth: w, imageHeight: h);
      for (int f = 0; f < 4; f++) {
        expect(t.updateWithSafety([note20], imageWidth: w, imageHeight: h).assessment.reasons,
            contains('INCOMPLETE_SCENE'));
      }
      expect(t.updateWithSafety([note20], imageWidth: w, imageHeight: h).assessment.confirmedTotalRupees, 20);

      // Cycle 2: 2 objects return for 2 frames -> re-arms -> drop triggers cooldown again
      t.updateWithSafety([note20, coin5], imageWidth: w, imageHeight: h);
      t.updateWithSafety([note20, coin5], imageWidth: w, imageHeight: h);
      final drop2 = t.updateWithSafety([note20], imageWidth: w, imageHeight: h);
      expect(drop2.assessment.reasons, contains('INCOMPLETE_SCENE'));
      expect(drop2.assessment.isTotalConfirmed, isFalse);

      // reset() clears everything immediately
      t.reset();
      final postReset = t.updateWithSafety([coin2], imageWidth: w, imageHeight: h);
      expect(postReset.assessment.reasons, isNot(contains('INCOMPLETE_SCENE')));
      expect(postReset.assessment.isTotalConfirmed, isTrue);
      expect(postReset.assessment.confirmedTotalRupees, 2);
    });
  });
}
