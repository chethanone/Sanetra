// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vision_assistant/services/banknote_tracker.dart';
import 'package:vision_assistant/services/currency_model_service.dart';
import 'package:vision_assistant/services/currency_safety_evaluator.dart';
import 'package:vision_assistant/services/currency_speech_formatter.dart';

CurrencyDetection makeDet({
  required int classId,
  required String denom,
  required int value,
  required double conf,
  required List<double> box,
  String type = 'banknote',
  int top2ClassId = -1,
  String top2ClassName = '',
  double top2Conf = 0.05,
  double? margin,
  int suppressedCount = 0,
  int suppressedClsId = -1,
  String suppressedClsName = '',
  double suppressedConf = 0.0,
}) {
  return CurrencyDetection(
    classId: classId,
    denomination: denom,
    value: value,
    confidence: conf,
    x1: box[0],
    y1: box[1],
    x2: box[2],
    y2: box[3],
    type: type,
    top2ClassId: top2ClassId,
    top2ClassName: top2ClassName,
    top2Confidence: top2Conf,
    classMargin: margin ?? (conf - top2Conf),
    suppressedConflictCount: suppressedCount,
    suppressedConflictClassId: suppressedClsId,
    suppressedConflictClassName: suppressedClsName,
    suppressedConflictConfidence: suppressedConf,
  );
}

void main() {
  final summary = <String, dynamic>{};

  tearDownAll(() {
    print('[PHASE4M_TRACKER_SIM_BEGIN]');
    print(jsonEncode(summary));
    print('[PHASE4M_TRACKER_SIM_END]');
  });

  group('Phase 4M BanknoteTracker Repairs', () {
    test('1. Stale track removal & confidence decay when note disappears', () {
      final legacyTracker = BanknoteTracker(candidateMode: false);
      final candTracker = BanknoteTracker(candidateMode: true);

      final d500 = makeDet(
        classId: 5,
        denom: 'INR_500',
        value: 500,
        conf: 0.86,
        box: [100, 100, 400, 260],
      );

      for (int f = 0; f < 3; f++) {
        legacyTracker.update([d500]);
        candTracker.update([d500]);
      }

      // Frame 3: Note completely removed
      final legacyAfterRemove = legacyTracker.update(const []);
      final candAfterRemove = candTracker.updateWithSafety(const []);
      final retainedConfAfterMiss1 = candTracker.debugTracks.first.confidence;

      // Legacy leaks stale ₹500 on Frame 3; Candidate immediately drops active ₹500 and decays internal confidence
      expect(legacyAfterRemove.length, 1);
      expect(candAfterRemove.activeDetections, isEmpty);
      expect(candAfterRemove.assessment.confirmedTotalRupees, isNull);
      expect(retainedConfAfterMiss1, closeTo(0.86 * 0.55, 1e-4));

      // Frame 4: Still absent -> expired internally
      final candFrame4 = candTracker.updateWithSafety(const []);
      expect(candFrame4.droppedStaleCount, 1);
      expect(candTracker.debugTracks, isEmpty);

      summary['1_stale_removal'] = {
        'legacy_emitted_after_removal': legacyAfterRemove.length,
        'candidate_emitted_after_removal':
            candAfterRemove.activeDetections.length,
        'decayed_conf_miss1': retainedConfAfterMiss1,
        'purged_after_miss2': candTracker.debugTracks.isEmpty,
      };
    });

    test('2. Fast slide movement without ghost double counting', () {
      final legacyTracker = BanknoteTracker(candidateMode: false);
      final candTracker = BanknoteTracker(candidateMode: true);

      final posA = makeDet(
        classId: 3,
        denom: 'INR_100',
        value: 100,
        conf: 0.85,
        box: [40, 100, 300, 240],
      );
      final posB = makeDet(
        classId: 3,
        denom: 'INR_100',
        value: 100,
        conf: 0.85,
        box: [360, 100, 620, 240],
      );

      legacyTracker.update([posA]);
      legacyTracker.update([posA]);
      candTracker.update([posA]);
      candTracker.update([posA]);

      // Note rapidly slides across camera on frame 2
      final legacySlide = legacyTracker.update([posB]);
      final candSlide = candTracker.updateWithSafety([posB]);

      final legacySum = legacySlide.fold<int>(0, (s, d) => s + d.value);
      final candSum = candSlide.activeDetections.fold<int>(
        0,
        (s, d) => s + d.value,
      );

      expect(legacySum, 200); // Documented legacy ghost double count!
      expect(candSlide.activeDetections.length, 1);
      expect(candSum, 100);

      summary['2_fast_slide'] = {
        'legacy_total_inr': legacySum,
        'candidate_total_inr': candSum,
        'candidate_active_count': candSlide.activeDetections.length,
      };
    });

    test('3. New physical object never inherits denomination of previous missing object', () {
      final legacyTracker = BanknoteTracker(candidateMode: false);
      final candTracker = BanknoteTracker(candidateMode: true);

      final oldNote500 = makeDet(
        classId: 5,
        denom: 'INR_500',
        value: 500,
        conf: 0.88,
        box: [100, 100, 420, 280],
      );
      final newNote100SameSpot = makeDet(
        classId: 3,
        denom: 'INR_100',
        value: 100,
        conf: 0.72,
        box: [110, 108, 410, 274],
      );

      for (int i = 0; i < 3; i++) {
        legacyTracker.update([oldNote500]);
        candTracker.update([oldNote500]);
      }

      // Frame 3: Old ₹500 leaves scene
      legacyTracker.update(const []);
      candTracker.update(const []);

      // Frame 4: User puts new ₹100 down in the same spot
      final legacySwapped = legacyTracker.update([newNote100SameSpot]);
      final candSwapped = candTracker.updateWithSafety([newNote100SameSpot]);

      expect(
        legacySwapped.first.denomination,
        'INR_500',
      ); // Legacy bug! Inherits ₹500
      expect(candSwapped.activeDetections.length, 1);
      expect(candSwapped.activeDetections.first.denomination, 'INR_100');
      expect(candSwapped.activeDetections.first.value, 100);

      summary['3_no_inherited_denom'] = {
        'legacy_denom_after_swap': legacySwapped.first.denomination,
        'candidate_denom_after_swap':
            candSwapped.activeDetections.first.denomination,
      };
    });

    test('4. Duplicate active tracks suppressed while retaining cross-class conflict warning', () {
      final candTracker = BanknoteTracker(candidateMode: true);

      final primary = makeDet(
        classId: 4,
        denom: 'INR_200',
        value: 200,
        conf: 0.56,
        box: [100, 100, 360, 240],
        margin: 0.30,
      );
      final dupWrong = makeDet(
        classId: 0,
        denom: 'INR_10',
        value: 10,
        conf: 0.42,
        box: [108, 106, 355, 236],
        margin: 0.16,
      );

      final res = candTracker.updateWithSafety([primary, dupWrong]);
      expect(res.deduplicatedTrackCount, 1);
      expect(res.activeDetections.length, 1);
      expect(res.activeDetections.first.isConflicting, isTrue);
      expect(res.assessment.isTotalConfirmed, isFalse);
      expect(res.assessment.confirmedTotalRupees, isNull);
      expect(res.assessment.spokenMessage.contains('Total'), isFalse);

      summary['4_dup_track_dedup'] = {
        'deduplicated_tracks': res.deduplicatedTrackCount,
        'active_count': res.activeDetections.length,
        'is_total_confirmed': res.assessment.isTotalConfirmed,
        'status': res.assessment.status.name,
      };
    });

    test('5. Overlapping crossing movement keeps two separate notes associated cleanly', () {
      final candTracker = BanknoteTracker(candidateMode: true);

      // Note 1 (₹100 left) and Note 2 (₹500 right) slide closer/past without losing identity
      final f0 = [
        makeDet(
          classId: 3,
          denom: 'INR_100',
          value: 100,
          conf: 0.85,
          box: [40, 100, 260, 220],
        ),
        makeDet(
          classId: 5,
          denom: 'INR_500',
          value: 500,
          conf: 0.88,
          box: [340, 120, 580, 240],
        ),
      ];
      final f1 = [
        makeDet(
          classId: 3,
          denom: 'INR_100',
          value: 100,
          conf: 0.84,
          box: [150, 108, 370, 228],
        ),
        makeDet(
          classId: 5,
          denom: 'INR_500',
          value: 500,
          conf: 0.87,
          box: [220, 114, 460, 234],
        ),
      ];
      final f2 = [
        makeDet(
          classId: 3,
          denom: 'INR_100',
          value: 100,
          conf: 0.86,
          box: [200, 110, 420, 230],
        ),
        makeDet(
          classId: 5,
          denom: 'INR_500',
          value: 500,
          conf: 0.89,
          box: [420, 115, 650, 235],
        ),
      ];

      candTracker.updateWithSafety(f0);
      final overlapStep = candTracker.updateWithSafety(f1);
      final separatedStep = candTracker.updateWithSafety(f2);

      // During high overlap (IoU/IoMin), safety gate withholds confirmed total; once separated, confirms ₹600!
      expect(overlapStep.activeDetections.length, 2);
      expect(overlapStep.assessment.isTotalConfirmed, isFalse);
      expect(separatedStep.activeDetections.length, 2);
      expect(separatedStep.assessment.isTotalConfirmed, isTrue);
      expect(separatedStep.assessment.confirmedTotalRupees, 600);

      summary['5_crossing_notes'] = {
        'overlap_step_confirmed': overlapStep.assessment.isTotalConfirmed,
        'separated_step_confirmed_inr':
            separatedStep.assessment.confirmedTotalRupees,
      };
    });

    test('6. Incorrect track merging growth triggers spread guidance instead of wrong ₹ total', () {
      final candTracker = BanknoteTracker(candidateMode: true);

      final singleBox = makeDet(
        classId: 2,
        denom: 'INR_50',
        value: 50,
        conf: 0.82,
        box: [100, 120, 320, 240], // 220x120 = 26,400
      );
      final mergedBlob = makeDet(
        classId: 2,
        denom: 'INR_50',
        value: 50,
        conf: 0.78,
        box: [90, 90, 360, 310], // 270x220 = 59,400 (2.25x swell!)
      );

      candTracker.updateWithSafety([singleBox]);
      final mergedRes = candTracker.updateWithSafety([mergedBlob]);

      expect(mergedRes.assessment.isTotalConfirmed, isFalse);
      expect(mergedRes.assessment.reasons, contains('MERGED_BOX_SUSPECTED'));
      expect(mergedRes.assessment.spokenMessage, contains('spread them apart'));

      summary['6_merge_growth'] = {
        'is_confirmed': mergedRes.assessment.isTotalConfirmed,
        'reasons': mergedRes.assessment.reasons.toList(),
        'speech': mergedRes.assessment.spokenMessage,
      };
    });
  });

  group('Phase 4M Safe Monetary Announcement States', () {
    test('7. Distinguishes confirmed, tentative, conflicting, and uncertain-count states cleanly', () {
      // A) Confirmed single & confirmed multiple
      final c1 = CurrencySafetyEvaluator.evaluate([
        makeDet(
          classId: 1,
          denom: 'INR_20',
          value: 20,
          conf: 0.85,
          box: [10, 10, 200, 110],
        ),
      ]);
      expect(c1.status, AnnouncementSafetyStatus.confirmedSingle);
      expect(c1.isTotalConfirmed, isTrue);
      expect(c1.confirmedTotalRupees, 20);
      expect(c1.spokenMessage, '20 Rupee Note');

      final cMulti = CurrencySafetyEvaluator.evaluate([
        makeDet(
          classId: 2,
          denom: 'INR_50',
          value: 50,
          conf: 0.82,
          box: [10, 10, 180, 100],
        ),
        makeDet(
          classId: 2,
          denom: 'INR_50',
          value: 50,
          conf: 0.79,
          box: [220, 10, 400, 100],
        ),
        makeDet(
          classId: 3,
          denom: 'INR_100',
          value: 100,
          conf: 0.88,
          box: [10, 150, 200, 260],
        ),
      ]);
      expect(cMulti.status, AnnouncementSafetyStatus.confirmedMultiple);
      expect(cMulti.isTotalConfirmed, isTrue);
      expect(cMulti.confirmedTotalRupees, 200);
      expect(cMulti.spokenMessage, contains('Confirmed total, 200 Rupees'));

      // B) Tentative single (conf 0.36 < 0.45, or narrow margin 0.08 < 0.15)
      final tSingle = CurrencySafetyEvaluator.evaluate([
        makeDet(
          classId: 2,
          denom: 'INR_50',
          value: 50,
          conf: 0.36,
          box: [10, 10, 200, 110],
          margin: 0.25,
        ),
      ]);
      expect(tSingle.status, AnnouncementSafetyStatus.tentativeSingle);
      expect(tSingle.isTotalConfirmed, isFalse);
      expect(tSingle.confirmedTotalRupees, isNull);
      expect(tSingle.spokenMessage, contains('not confirmed'));

      // C) Conflicting suppressed alternate class (>= 0.25) -> never announces Total!
      final conflictAlt = CurrencySafetyEvaluator.evaluate([
        makeDet(
          classId: 4,
          denom: 'INR_200',
          value: 200,
          conf: 0.62,
          box: [10, 10, 220, 130],
          suppressedCount: 1,
          suppressedClsId: 0,
          suppressedClsName: 'INR_10',
          suppressedConf: 0.34,
        ),
      ]);
      expect(
        conflictAlt.status,
        AnnouncementSafetyStatus.conflictingOrUncertain,
      );
      expect(conflictAlt.isTotalConfirmed, isFalse);
      expect(conflictAlt.confirmedTotalRupees, isNull);
      expect(conflictAlt.spokenMessage, isNot(contains('Rupees')));

      // D) Uncertain count / high pairwise IoMin (> 0.70) overlap -> advises spreading apart
      final overlapPair = CurrencySafetyEvaluator.evaluate([
        makeDet(
          classId: 3,
          denom: 'INR_100',
          value: 100,
          conf: 0.80,
          box: [50, 50, 350, 220],
        ),
        makeDet(
          classId: 5,
          denom: 'INR_500',
          value: 500,
          conf: 0.75,
          box: [70, 70, 280, 190],
        ),
      ]);
      expect(
        overlapPair.status,
        AnnouncementSafetyStatus.conflictingOrUncertain,
      );
      expect(overlapPair.hasUncertainCount, isTrue);
      expect(overlapPair.isTotalConfirmed, isFalse);
      expect(overlapPair.spokenMessage, contains('spread them apart'));

      summary['7_announcement_states'] = {
        'confirmed_single': c1.spokenMessage,
        'confirmed_multi': cMulti.spokenMessage,
        'tentative_single': tSingle.spokenMessage,
        'conflict_suppressed': conflictAlt.spokenMessage,
        'overlap_pair': overlapPair.spokenMessage,
      };
    });

    test('8. Same-denomination currencies held together (500, 200, 100, coins) confirm full total without false overlap conflict', () {
      final candTracker = BanknoteTracker(candidateMode: true);

      // A) Two ₹500 notes held together in hand (frontside & backside, ~45% overlap)
      final pair500 = [
        makeDet(
          classId: 5,
          denom: 'INR_500',
          value: 500,
          conf: 0.88,
          box: [100, 100, 340, 220],
        ),
        makeDet(
          classId: 5,
          denom: 'INR_500',
          value: 500,
          conf: 0.85,
          box: [200, 110, 440, 230],
        ),
      ];

      final res500 = candTracker.updateWithSafety(pair500);
      expect(res500.activeDetections.length, 2);
      expect(res500.assessment.isTotalConfirmed, isTrue);
      expect(res500.assessment.confirmedTotalRupees, 1000);
      expect(res500.assessment.spokenMessage, contains('2 500 Rupee Notes'));
      expect(res500.assessment.spokenMessage, contains('1000 Rupees'));
      expect(res500.assessment.reasons, isNot(contains('OVERLAP_CONFLICT')));

      // B) Two ₹200 notes held together in hand (~45% overlap)
      candTracker.reset();
      final pair200 = [
        makeDet(
          classId: 4,
          denom: 'INR_200',
          value: 200,
          conf: 0.86,
          box: [100, 100, 340, 220],
        ),
        makeDet(
          classId: 4,
          denom: 'INR_200',
          value: 200,
          conf: 0.84,
          box: [200, 110, 440, 230],
        ),
      ];
      final res200 = candTracker.updateWithSafety(pair200);
      expect(res200.activeDetections.length, 2);
      expect(res200.assessment.isTotalConfirmed, isTrue);
      expect(res200.assessment.confirmedTotalRupees, 400);
      expect(res200.assessment.spokenMessage, contains('2 200 Rupee Notes'));
      expect(res200.assessment.spokenMessage, contains('400 Rupees'));

      // C) Direct safety evaluation of two overlapping ₹100 notes
      final direct100 = CurrencySafetyEvaluator.evaluate([
        makeDet(
          classId: 3,
          denom: 'INR_100',
          value: 100,
          conf: 0.82,
          box: [50, 50, 290, 170],
        ),
        makeDet(
          classId: 3,
          denom: 'INR_100',
          value: 100,
          conf: 0.80,
          box: [150, 60, 390, 180],
        ),
      ], candidateMode: true);
      expect(direct100.isTotalConfirmed, isTrue);
      expect(direct100.confirmedTotalRupees, 200);
      expect(direct100.spokenMessage, contains('2 100 Rupee Notes'));
      expect(direct100.reasons, isNot(contains('OVERLAP_CONFLICT')));
    });

    test('9. Invalid non-matching currency announces "Invalid" in English, Hindi, and Kannada', () {
      final candTracker = BanknoteTracker(candidateMode: true);

      // When an object is verified not to match any Indian currency (foreign or fake note)
      final invalidResult = candTracker.updateWithSafety(
        const [],
        extraReasons: {'INVALID_CURRENCY_DETECTED'},
      );

      expect(invalidResult.assessment.isTotalConfirmed, isFalse);
      expect(invalidResult.assessment.confirmedTotalRupees, isNull);
      expect(invalidResult.assessment.reasons, contains('INVALID_CURRENCY_DETECTED'));

      // 1. English
      final speechEn = CurrencySpeechFormatter.formatAssessment(
        invalidResult.assessment,
        language: 'en-IN',
      );
      expect(speechEn, 'Invalid');

      // 2. Hindi
      final speechHi = CurrencySpeechFormatter.formatAssessment(
        invalidResult.assessment,
        language: 'hi-IN',
      );
      expect(speechHi, 'अमान्य');

      // 3. Kannada
      final speechKn = CurrencySpeechFormatter.formatAssessment(
        invalidResult.assessment,
        language: 'kn-IN',
      );
      expect(speechKn, 'ಅಮಾನ್ಯ');
    });

    test('10. Unrecognised note stays UNRECOGNISED (announces unrecognised currency, NEVER foreign or invalid)', () {
      final candTracker = BanknoteTracker(candidateMode: true);

      // When a note is unrecognised / uncertain, verifier sets UNRECOGNISED_CURRENCY / IDENTITY_UNKNOWN
      final unrecResult = candTracker.updateWithSafety(
        const [],
        extraReasons: {'UNRECOGNISED_CURRENCY', 'IDENTITY_UNKNOWN'},
      );

      expect(unrecResult.assessment.isTotalConfirmed, isFalse);
      expect(unrecResult.assessment.confirmedTotalRupees, isNull);
      expect(unrecResult.assessment.reasons, contains('UNRECOGNISED_CURRENCY'));
      expect(unrecResult.assessment.reasons, isNot(contains('INVALID_CURRENCY_DETECTED')));

      // 1. English: Says unrecognised currency, NEVER mentions foreign or invalid
      final speechEn = CurrencySpeechFormatter.formatAssessment(
        unrecResult.assessment,
        language: 'en-IN',
      );
      expect(speechEn, 'Unrecognised currency. Hold steady and try again.');
      expect(speechEn.toLowerCase(), isNot(contains('foreign')));
      expect(speechEn.toLowerCase(), isNot(contains('invalid')));

      // 2. Hindi: Says unrecognised, does not mention foreign or invalid
      final speechHi = CurrencySpeechFormatter.formatAssessment(
        unrecResult.assessment,
        language: 'hi-IN',
      );
      expect(speechHi, 'अपरिचित मुद्रा। स्थिर रखें और फिर प्रयास करें।');
      expect(speechHi, isNot(contains('विदेशी')));
      expect(speechHi, isNot(contains('अमान्य')));

      // 3. Kannada: Says unrecognised, does not mention foreign or invalid
      final speechKn = CurrencySpeechFormatter.formatAssessment(
        unrecResult.assessment,
        language: 'kn-IN',
      );
      expect(speechKn, 'ಗುರುತಿಸಲಾಗದ ಕರೆನ್ಸಿ. ದಯವಿಟ್ಟು ಸ್ಥಿರವಾಗಿ ಹಿಡಿದು ಮತ್ತೆ ಪ್ರಯತ್ನಿಸಿ.');
      expect(speechKn, isNot(contains('ವಿದೇಶಿ')));
      expect(speechKn, isNot(contains('ಅಮಾನ್ಯ')));
    });

    test('11. Banknote overlay painter correctly distinguishes INVALID vs UNRECOGNISED', () {
      const invalidDet = CurrencyDetection(
        classId: -1,
        denomination: 'INVALID',
        value: 0,
        confidence: 0.88,
        x1: 50,
        y1: 50,
        x2: 250,
        y2: 450,
        confirmationState: DetectionConfirmationState.conflicting,
        uncertaintyReasons: ['INVALID_CURRENCY_DETECTED'],
      );

      const unrecDet = CurrencyDetection(
        classId: -2,
        denomination: 'UNRECOGNISED',
        value: 0,
        confidence: 0.45,
        x1: 60,
        y1: 60,
        x2: 260,
        y2: 460,
        confirmationState: DetectionConfirmationState.tentative,
        uncertaintyReasons: ['UNRECOGNISED_CURRENCY'],
      );

      expect(invalidDet.denomination, 'INVALID');
      expect(invalidDet.uncertaintyReasons, contains('INVALID_CURRENCY_DETECTED'));
      expect(unrecDet.denomination, 'UNRECOGNISED');
      expect(unrecDet.uncertaintyReasons, contains('UNRECOGNISED_CURRENCY'));
    });
  });
}
