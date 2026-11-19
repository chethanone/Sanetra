import 'package:flutter_test/flutter_test.dart';
import 'package:vision_assistant/services/currency_model_service.dart';
import 'package:vision_assistant/services/currency_region.dart';
import 'package:vision_assistant/services/currency_safety_evaluator.dart';
import 'package:vision_assistant/services/php_currency_speech_formatter.dart';

CurrencyDetection _det(String denom, int val, {int slot = 0, double conf = 0.92}) {
  final double x1 = 10.0 + slot * 120.0;
  return CurrencyDetection(
    classId: 0,
    denomination: denom,
    value: val,
    confidence: conf,
    classMargin: 0.85,
    x1: x1,
    y1: 10,
    x2: x1 + 90,
    y2: 100,
    type: denom.contains('COIN') ? 'coin' : 'banknote',
  );
}

CurrencySafetyAssessment _phpAssessment(
  List<CurrencyDetection> dets, {
  AnnouncementSafetyStatus status = AnnouncementSafetyStatus.confirmedMultiple,
  Set<String> reasons = const {},
}) {
  return CurrencySafetyAssessment(
    status: dets.length == 1 && status == AnnouncementSafetyStatus.confirmedMultiple
        ? AnnouncementSafetyStatus.confirmedSingle
        : status,
    screenedDetections: dets,
    confirmedCount: status == AnnouncementSafetyStatus.confirmedSingle ||
            status == AnnouncementSafetyStatus.confirmedMultiple
        ? dets.length
        : 0,
    tentativeCount: status == AnnouncementSafetyStatus.tentativeSingle ? 1 : 0,
    conflictingCount: status == AnnouncementSafetyStatus.conflictingOrUncertain ? dets.length : 0,
    hasUncertainCount: status == AnnouncementSafetyStatus.conflictingOrUncertain,
    isTotalConfirmed: status == AnnouncementSafetyStatus.confirmedSingle ||
        status == AnnouncementSafetyStatus.confirmedMultiple,
    visibleDetectedSumRupees: 0,
    confirmedTotalRupees: null,
    reasons: reasons,
    bannerHeadline: '',
    bannerSubtitle: '',
    spokenMessage: '',
  );
}

void main() {
  group('Phase 8.5 CurrencyRegion & Cross-Currency Isolation', () {
    test('Maps languages to INR vs PHP regions and symbols cleanly', () {
      expect(currencyRegionForLanguage('en-IN'), CurrencyRegion.inr);
      expect(currencyRegionForLanguage('kn-IN'), CurrencyRegion.inr);
      expect(currencyRegionForLanguage('hi-IN'), CurrencyRegion.inr);
      expect(currencyRegionForLanguage('ceb-PH'), CurrencyRegion.php);

      expect(currencySymbolForRegion(CurrencyRegion.inr), '₹');
      expect(currencySymbolForRegion(CurrencyRegion.php), '₱');
    });

    test('Region switch increments epoch and invalidates stale async results', () {
      final ctrl = CurrencyRegionController(initialLanguage: 'en-IN');
      expect(ctrl.region, CurrencyRegion.inr);
      final inrEpoch = ctrl.regionEpoch;

      // Same region switch (en-IN -> hi-IN) does not bump epoch
      expect(ctrl.updateForLanguage('hi-IN'), isFalse);
      expect(ctrl.regionEpoch, inrEpoch);

      // INR -> PHP bumps epoch and invalidates prior INR result
      expect(ctrl.updateForLanguage('ceb-PH'), isTrue);
      expect(ctrl.region, CurrencyRegion.php);
      expect(ctrl.symbol, '₱');
      expect(
        ctrl.isResultCurrent(capturedEpoch: inrEpoch, capturedRegion: CurrencyRegion.inr),
        isFalse,
      );

      final phpEpoch = ctrl.regionEpoch;
      expect(
        ctrl.isResultCurrent(capturedEpoch: phpEpoch, capturedRegion: CurrencyRegion.php),
        isTrue,
      );

      // PHP -> INR bumps epoch and invalidates prior PHP result
      expect(ctrl.updateForLanguage('en-IN'), isTrue);
      expect(ctrl.region, CurrencyRegion.inr);
      expect(ctrl.symbol, '₹');
      expect(
        ctrl.isResultCurrent(capturedEpoch: phpEpoch, capturedRegion: CurrencyRegion.php),
        isFalse,
      );
    });

    test('Cross-currency negative test matrix rejects unselected currency classes', () {
      final inrNote = _det('INR_500', 500);
      final inrCoin = _det('INR_5_COIN', 5);
      final phpPaper = _det('PHP_PAPER_100', 100);
      final phpPolymer = _det('PHP_POLYMER_500', 500);
      final phpCoin = _det('PHP_COIN_025_SENTIMO', 25);

      // INR in PHP mode -> rejected
      expect(filterDetectionsForRegion([inrNote, inrCoin], CurrencyRegion.php), isEmpty);

      // PHP in INR mode -> rejected
      expect(
        filterDetectionsForRegion([phpPaper, phpPolymer, phpCoin], CurrencyRegion.inr),
        isEmpty,
      );

      // Mixed frame keeps ONLY active region
      final mixed = [inrNote, phpPaper, inrCoin, phpCoin];
      expect(
        filterDetectionsForRegion(mixed, CurrencyRegion.php).map((d) => d.denomination).toList(),
        ['PHP_PAPER_100', 'PHP_COIN_025_SENTIMO'],
      );
      expect(
        filterDetectionsForRegion(mixed, CurrencyRegion.inr).map((d) => d.denomination).toList(),
        ['INR_500', 'INR_5_COIN'],
      );
    });
  });

  group('Phase 8.5 PhpCurrencySpeechFormatter & Integer Sentimo Arithmetic', () {
    test('Exact integer sentimo display and Cebuano wording', () {
      expect(PhpCurrencySpeechFormatter.formatPesoDisplay(100), '₱1');
      expect(PhpCurrencySpeechFormatter.formatPesoDisplay(125), '₱1.25');
      expect(PhpCurrencySpeechFormatter.formatPesoDisplay(250), '₱2.50');
      expect(PhpCurrencySpeechFormatter.formatPesoDisplay(1000), '₱10');

      expect(
        PhpCurrencySpeechFormatter.formatSentimoAmountCebuano(25),
        'kawhaan ug lima ka sentimo',
      );
      expect(
        PhpCurrencySpeechFormatter.formatSentimoAmountCebuano(125),
        'usa ka piso ug kawhaan ug lima ka sentimo',
      );
      expect(
        PhpCurrencySpeechFormatter.formatSentimoAmountCebuano(250),
        'duha ka piso ug kalim-an ka sentimo',
      );
    });

    test('Formats paper, polymer, coins, mixed totals, demonetized, uncertain & foreign', () {
      // 1. One ₱100 polymer note
      expect(
        PhpCurrencySpeechFormatter.formatAssessmentPhp(
          _phpAssessment([_det('PHP_POLYMER_100', 100)]),
        ),
        'Usa ka usa ka gatos ka piso nga polymer nga papel.',
      );

      // 2. One ₱100 paper note
      expect(
        PhpCurrencySpeechFormatter.formatAssessmentPhp(
          _phpAssessment([_det('PHP_PAPER_100', 100)]),
        ),
        'Usa ka usa ka gatos ka piso nga papel.',
      );

      // 3. One ₱500 + two ₱100 (paper + polymer) = ₱700 (no double counting)
      final s700 = PhpCurrencySpeechFormatter.formatAssessmentPhp(
        _phpAssessment([
          _det('PHP_POLYMER_500', 500, slot: 0),
          _det('PHP_PAPER_100', 100, slot: 1),
          _det('PHP_POLYMER_100', 100, slot: 2),
        ]),
      );
      expect(s700, contains('Kinatibuk-an, pito ka gatos ka piso.'));

      // 4. ₱1 coin + 25 sentimo coin = ₱1.25
      final s125 = PhpCurrencySpeechFormatter.formatAssessmentPhp(
        _phpAssessment([
          _det('PHP_COIN_1_PISO', 100, slot: 0),
          _det('PHP_COIN_025_SENTIMO', 25, slot: 1),
        ]),
      );
      expect(s125, contains('Kinatibuk-an, usa ka piso ug kawhaan ug lima ka sentimo.'));

      // 5. Demonetized note excluded from total with warning
      final demonetized = PhpCurrencySpeechFormatter.formatAssessmentPhp(
        _phpAssessment([_det('PHP_OLD_DEMONETIZED', 0)]),
      );
      expect(demonetized, contains('dili na magamit'));

      // 6. Indian currency presented in PHP mode -> rejected
      final foreignInPhp = PhpCurrencySpeechFormatter.formatAssessmentPhp(
        _phpAssessment([_det('INR_500', 500)]),
      );
      expect(foreignInPhp, contains('Dili kini kwarta sa Pilipinas'));
      expect(foreignInPhp.toLowerCase().contains('rupee'), isFalse);

      // 7. Uncertain detection never announces a confirmed total
      final uncertain = PhpCurrencySpeechFormatter.formatAssessmentPhp(
        _phpAssessment(
          [_det('PHP_PAPER_50', 50, conf: 0.4)],
          status: AnnouncementSafetyStatus.conflictingOrUncertain,
        ),
      );
      expect(uncertain.contains('Kinatibuk-an'), isFalse);
    });
  });
}
