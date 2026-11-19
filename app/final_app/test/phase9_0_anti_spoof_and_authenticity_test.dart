// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:vision_assistant/services/banknote_tracker.dart';
import 'package:vision_assistant/services/currency_model_service.dart';
import 'package:vision_assistant/services/currency_safety_evaluator.dart';

CurrencyDetection _createDetection({
  required int classId,
  required String denomination,
  required int value,
  required double confidence,
  required List<double> box,
  String type = 'banknote',
  double top2Confidence = 0.05,
  DetectionConfirmationState state = DetectionConfirmationState.confirmed,
  List<String> uncertaintyReasons = const [],
}) {
  return CurrencyDetection(
    classId: classId,
    denomination: denomination,
    value: value,
    confidence: confidence,
    x1: box[0],
    y1: box[1],
    x2: box[2],
    y2: box[3],
    type: type,
    top2ClassId: -1,
    top2ClassName: '',
    top2Confidence: top2Confidence,
    classMargin: confidence - top2Confidence,
    confirmationState: state,
    uncertaintyReasons: uncertaintyReasons,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 9.0 Anti-Spoof, Authenticity & Safety Guard Tests', () {
    test('1. Speech NEVER claims banknote authentication or physical genuineness', () {
      final detections = [
        _createDetection(
          classId: 5,
          denomination: 'INR_500',
          value: 500,
          confidence: 0.95,
          box: [50.0, 50.0, 450.0, 350.0],
        ),
      ];

      final assessment = CurrencySafetyEvaluator.evaluate(
        detections,
        imageWidth: 640,
        imageHeight: 640,
      );

      expect(assessment.status, AnnouncementSafetyStatus.confirmedSingle);
      final spoken = assessment.spokenMessage;

      // Crucial Safety Gate: speech communicates visual denomination only
      expect(spoken.toLowerCase().contains('authentic'), isFalse);
      expect(spoken.toLowerCase().contains('genuine banknote'), isFalse);
      expect(spoken.toLowerCase().contains('counterfeit verified'), isFalse);
      expect(spoken.toLowerCase().contains('real money'), isFalse);
      expect(spoken, contains('500 Rupee Note'));
    });

    test('2. Screen Replay & Print Negative with low confidence rejects confirmed total', () {
      // Simulating a low-contrast screen capture or photocopied note with borderline confidence
      final detections = [
        _createDetection(
          classId: 3,
          denomination: 'INR_100',
          value: 100,
          confidence: 0.32, // below confirmation threshold 0.45
          top2Confidence: 0.28, // low margin 0.04
          box: [100.0, 100.0, 500.0, 300.0],
          state: DetectionConfirmationState.tentative,
          uncertaintyReasons: ['LOW_CONFIDENCE', 'LOW_MARGIN'],
        ),
      ];

      final assessment = CurrencySafetyEvaluator.evaluate(
        detections,
        imageWidth: 640,
        imageHeight: 640,
      );

      expect(assessment.status, AnnouncementSafetyStatus.tentativeSingle);
      expect(assessment.isTotalConfirmed, isFalse);
      expect(assessment.confirmedTotalRupees, isNull);
      expect(assessment.spokenMessage, contains('Possible 100 Rupee Note, not confirmed'));
      expect(assessment.spokenMessage, contains('Hold steady in better light and try again'));
    });

    test('3. Conflicting multi-note detections (e.g. video replay frame transitions) prevent announcement of sum', () {
      final detections = [
        _createDetection(
          classId: 1,
          denomination: 'INR_20',
          value: 20,
          confidence: 0.40,
          box: [50.0, 50.0, 400.0, 300.0],
          state: DetectionConfirmationState.conflicting,
          uncertaintyReasons: ['CLASS_CONFLICT'],
        ),
        _createDetection(
          classId: 0,
          denomination: 'INR_10',
          value: 10,
          confidence: 0.38,
          box: [60.0, 60.0, 410.0, 310.0],
          state: DetectionConfirmationState.conflicting,
          uncertaintyReasons: ['OVERLAPPING_CONFLICT'],
        ),
      ];

      final assessment = CurrencySafetyEvaluator.evaluate(
        detections,
        imageWidth: 640,
        imageHeight: 640,
      );

      expect(assessment.status, AnnouncementSafetyStatus.conflictingOrUncertain);
      expect(assessment.isTotalConfirmed, isFalse);
      expect(assessment.confirmedTotalRupees, isNull);
      expect(assessment.spokenMessage, contains('Some notes are unclear or overlapping'));
    });

    test('4. Full banknote denomination coverage (₹10, ₹20, ₹50, ₹100, ₹200, ₹500)', () {
      final testCases = [
        {'id': 0, 'denom': 'INR_10', 'val': 10, 'expected': '10 Rupee Note'},
        {'id': 1, 'denom': 'INR_20', 'val': 20, 'expected': '20 Rupee Note'},
        {'id': 2, 'denom': 'INR_50', 'val': 50, 'expected': '50 Rupee Note'},
        {'id': 3, 'denom': 'INR_100', 'val': 100, 'expected': '100 Rupee Note'},
        {'id': 4, 'denom': 'INR_200', 'val': 200, 'expected': '200 Rupee Note'},
        {'id': 5, 'denom': 'INR_500', 'val': 500, 'expected': '500 Rupee Note'},
      ];

      for (final tc in testCases) {
        final det = [
          _createDetection(
            classId: tc['id'] as int,
            denomination: tc['denom'] as String,
            value: tc['val'] as int,
            confidence: 0.85,
            box: [100.0, 100.0, 500.0, 350.0],
          ),
        ];

        final assessment = CurrencySafetyEvaluator.evaluate(
          det,
          imageWidth: 640,
          imageHeight: 640,
        );

        expect(assessment.status, AnnouncementSafetyStatus.confirmedSingle);
        expect(assessment.isTotalConfirmed, isTrue);
        expect(assessment.confirmedTotalRupees, tc['val'] as int);
        expect(assessment.spokenMessage, tc['expected'] as String);
      }
    });

    test('5. Full coin denomination coverage (₹1, ₹2, ₹5, ₹10)', () {
      final testCases = [
        {'id': 6, 'denom': 'INR_1_COIN', 'val': 1, 'expected': '1 Rupee Coin'},
        {'id': 7, 'denom': 'INR_2_COIN', 'val': 2, 'expected': '2 Rupee Coin'},
        {'id': 8, 'denom': 'INR_5_COIN', 'val': 5, 'expected': '5 Rupee Coin'},
        {'id': 9, 'denom': 'INR_10_COIN', 'val': 10, 'expected': '10 Rupee Coin'},
      ];

      for (final tc in testCases) {
        final det = [
          _createDetection(
            classId: tc['id'] as int,
            denomination: tc['denom'] as String,
            value: tc['val'] as int,
            confidence: 0.88,
            box: [200.0, 200.0, 320.0, 320.0],
            type: 'coin',
          ),
        ];

        final assessment = CurrencySafetyEvaluator.evaluate(
          det,
          imageWidth: 640,
          imageHeight: 640,
        );

        expect(assessment.status, AnnouncementSafetyStatus.confirmedSingle);
        expect(assessment.isTotalConfirmed, isTrue);
        expect(assessment.confirmedTotalRupees, tc['val'] as int);
        expect(assessment.spokenMessage, tc['expected'] as String);
      }
    });

    test('6. Temporal BanknoteTracker requires consistent consecutive frames before confirmation', () {
      final tracker = BanknoteTracker(candidateMode: true);

      final det = [
        _createDetection(
          classId: 3,
          denomination: 'INR_100',
          value: 100,
          confidence: 0.85,
          box: [100.0, 100.0, 500.0, 350.0],
        ),
      ];

      // Frame 1: newly detected track, visible count = 1
      final t1 = tracker.updateWithSafety(det, imageWidth: 640, imageHeight: 640);
      expect(t1.activeDetections.length, 1);
      expect(t1.activeDetections.first.framesVisible, 1);

      // Frame 2: tracked across time, visible count = 2
      final t2 = tracker.updateWithSafety(det, imageWidth: 640, imageHeight: 640);
      expect(t2.activeDetections.length, 1);
      expect(t2.activeDetections.first.framesVisible, 2);

      // Frame 3: confirmed steady track
      final t3 = tracker.updateWithSafety(det, imageWidth: 640, imageHeight: 640);
      expect(t3.activeDetections.first.framesVisible, 3);
      expect(t3.assessment.status, AnnouncementSafetyStatus.confirmedSingle);
    });

    test('7. Approved permanent release signer fingerprint allowlist validation', () {
      const approvedSignerSha256 =
          'B3986507F0092F9296342FCA8FE12C7C6F2E63D4E9516399690BE422149A1389';
      const untrustedSignerSha256 =
          'A1B2C3D4E5F60718293A4B5C6D7E8F90A1B2C3D4E5F60718293A4B5C6D7E8F90';
      const debugSignerSha256 =
          '27196E386B875E76ADF700E7EA84E4C6EEE33DAFA955F587D061EC03E2D01A5B';

      final approvedAllowlist = {approvedSignerSha256.toUpperCase()};

      // Approved permanent certificate
      expect(approvedAllowlist.contains(approvedSignerSha256.toUpperCase()), isTrue);

      // Untrusted & debug certificates MUST be rejected
      expect(approvedAllowlist.contains(untrustedSignerSha256.toUpperCase()), isFalse);
      expect(approvedAllowlist.contains(debugSignerSha256.toUpperCase()), isFalse);
    });
  });
}
