import 'package:flutter_test/flutter_test.dart';
import 'package:vision_assistant/services/currency_model_service.dart';
import 'package:vision_assistant/services/currency_safety_evaluator.dart';
import 'package:vision_assistant/services/currency_speech_formatter.dart';
import 'package:vision_assistant/services/kannada_number_normalizer.dart';

CurrencyDetection _det(String denom, int val, {int slot = 0}) {
  final double x1 = 10.0 + slot * 120.0;
  return CurrencyDetection(
    classId: 0,
    denomination: denom,
    value: val,
    confidence: 0.92,
    classMargin: 0.85,
    x1: x1,
    y1: 10,
    x2: x1 + 90,
    y2: 100,
    type: denom.contains('COIN') ? 'coin' : 'banknote',
  );
}

CurrencySafetyAssessment _assess(List<(String, int)> items) =>
    CurrencySafetyEvaluator.evaluate(
      [
        for (int i = 0; i < items.length; i++)
          _det(items[i].$1, items[i].$2, slot: i),
      ],
      candidateMode: true,
    );

void main() {
  group('Phase 5.4 English Currency Speech Formatting (Root-Cause Fix)', () {
    test('1 x ₹200 -> One 200-rupee note', () {
      final a = _assess([('INR_200', 200)]);
      expect(a.confirmedTotalRupees, 200);
      final s = CurrencySpeechFormatter.formatAssessment(a, language: 'en-IN');
      expect(s, 'One 200-rupee note.');
    });

    test('2 x ₹200 -> Two 200-rupee notes. Total four hundred rupees (never 2200)', () {
      final a = _assess([('INR_200', 200), ('INR_200', 200)]);
      expect(a.confirmedTotalRupees, 400);
      final s = CurrencySpeechFormatter.formatAssessment(a, language: 'en-IN');
      expect(s, 'Two 200-rupee notes. Total four hundred rupees.');
      expect(s.contains('2 200'), isFalse);
      expect(s.contains('2200'), isFalse);
      expect(s.toLowerCase().contains('two thousand two hundred'), isFalse);
    });

    test('3 x ₹500 -> Three 500-rupee notes. Total one thousand five hundred rupees', () {
      final a = _assess([
        ('INR_500', 500),
        ('INR_500', 500),
        ('INR_500', 500),
      ]);
      expect(a.confirmedTotalRupees, 1500);
      final s = CurrencySpeechFormatter.formatAssessment(a, language: 'en-IN');
      expect(s, 'Three 500-rupee notes. Total one thousand five hundred rupees.');
      expect(s.contains('3 500'), isFalse);
    });

    test('2 x ₹2,000 -> Two 2,000-rupee notes. Total four thousand rupees', () {
      final a = _assess([('INR_2000', 2000), ('INR_2000', 2000)]);
      expect(a.confirmedTotalRupees, 4000);
      final s = CurrencySpeechFormatter.formatAssessment(a, language: 'en-IN');
      expect(s, 'Two 2,000-rupee notes. Total four thousand rupees.');
      expect(s.contains('2 2000'), isFalse);
    });

    test('2 x ₹200 + 1 x ₹20 -> Two 200-rupee notes and one 20-rupee note. Total four hundred and twenty rupees', () {
      final a = _assess([
        ('INR_200', 200),
        ('INR_200', 200),
        ('INR_20', 20),
      ]);
      expect(a.confirmedTotalRupees, 420);
      final s = CurrencySpeechFormatter.formatAssessment(a, language: 'en-IN');
      expect(
        s,
        'Two 200-rupee notes and one 20-rupee note. Total four hundred and twenty rupees.',
      );
    });

    test('1 x ₹100 + 2 x ₹500 -> One 100-rupee note and two 500-rupee notes. Total one thousand one hundred rupees', () {
      final a = _assess([
        ('INR_100', 100),
        ('INR_500', 500),
        ('INR_500', 500),
      ]);
      expect(a.confirmedTotalRupees, 1100);
      final s = CurrencySpeechFormatter.formatAssessment(a, language: 'en-IN');
      expect(
        s,
        'One 100-rupee note and two 500-rupee notes. Total one thousand one hundred rupees.',
      );
    });

    test('5 x ₹10 -> Five 10-rupee notes. Total fifty rupees', () {
      final a = _assess(List.generate(5, (_) => ('INR_10', 10)));
      expect(a.confirmedTotalRupees, 50);
      final s = CurrencySpeechFormatter.formatAssessment(a, language: 'en-IN');
      expect(s, 'Five 10-rupee notes. Total fifty rupees.');
    });

    test('Mixed note + coins (₹20 + ₹5 coin + ₹2 coin = ₹27)', () {
      final a = _assess([
        ('INR_20', 20),
        ('INR_5_COIN', 5),
        ('INR_2_COIN', 2),
      ]);
      expect(a.confirmedTotalRupees, 27);
      final s = CurrencySpeechFormatter.formatAssessment(a, language: 'en-IN');
      expect(
        s,
        'One 20-rupee note, one 5-rupee coin, and one 2-rupee coin. Total twenty-seven rupees.',
      );
    });
  });

  group('Phase 5.4 Kannada & Hindi Currency Speech Formatting', () {
    test('Kannada normalization preserved for 2 x ₹200 and ₹27', () {
      final a400 = _assess([('INR_200', 200), ('INR_200', 200)]);
      final kn400 = CurrencySpeechFormatter.formatAssessment(a400, language: 'kn-IN');
      expect(kn400, 'ಎರಡು ಇನ್ನೂರು ರೂಪಾಯಿ ನೋಟುಗಳು. ಒಟ್ಟು ನಾಲ್ಕು ನೂರು ರೂಪಾಯಿ.');
      expect(KannadaNumberNormalizer.numberToKannadaWords(27), 'ಇಪ್ಪತ್ತಏಳು');
    });

    test('Hindi formatting separates count and denomination cleanly', () {
      final a1 = _assess([('INR_200', 200)]);
      expect(
        CurrencySpeechFormatter.formatAssessment(a1, language: 'hi-IN'),
        'एक दो सौ रुपये का नोट।',
      );

      final a2 = _assess([('INR_200', 200), ('INR_200', 200)]);
      expect(
        CurrencySpeechFormatter.formatAssessment(a2, language: 'hi-IN'),
        'दो दो सौ रुपये के नोट। कुल चार सौ रुपये।',
      );

      final aMix = _assess([
        ('INR_200', 200),
        ('INR_200', 200),
        ('INR_20', 20),
      ]);
      expect(
        CurrencySpeechFormatter.formatAssessment(aMix, language: 'hi-IN'),
        'दो दो सौ रुपये के नोट और एक बीस रुपये का नोट। कुल चार सौ बीस रुपये।',
      );
    });
  });
}
