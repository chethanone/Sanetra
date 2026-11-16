import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:vision_assistant/services/bisaya_number_normalizer.dart';
import 'package:vision_assistant/services/bisaya_speech_assembler.dart';
import 'package:vision_assistant/services/currency_language_controller.dart';
import 'package:vision_assistant/services/currency_model_service.dart';
import 'package:vision_assistant/services/currency_safety_evaluator.dart';
import 'package:vision_assistant/services/currency_speech_formatter.dart';
import 'package:vision_assistant/services/speech_service.dart';

class _FakeFlutterTts extends FlutterTts {
  final List<String> spoken = [];
  final List<String> setLanguages = [];
  int stopCalls = 0;

  @override
  Future<dynamic> awaitSpeakCompletion(bool awaitCompletion) async => 1;

  @override
  Future<dynamic> setVolume(double volume) async => 1;

  @override
  Future<dynamic> setPitch(double pitch) async => 1;

  @override
  Future<dynamic> setSpeechRate(double rate) async => 1;

  @override
  Future<dynamic> get getDefaultEngine async => 'com.google.android.tts';

  @override
  Future<dynamic> get getVoices async => [
    {'name': 'en-in-x-enc-local', 'locale': 'en-IN', 'network_required': 'false'},
    {'name': 'kn-in-x-knd-local', 'locale': 'kn-IN', 'network_required': 'false'},
    {'name': 'hi-in-x-hia-local', 'locale': 'hi-IN', 'network_required': 'false'},
  ];

  @override
  Future<dynamic> isLanguageAvailable(String language) async =>
      language == 'en-IN' || language == 'kn-IN' || language == 'hi-IN' ? 1 : 0;

  @override
  Future<dynamic> setLanguage(String language) async {
    setLanguages.add(language);
    return 1;
  }

  @override
  Future<dynamic> setVoice(Map<String, String> voice) async => 1;

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    spoken.add(text);
    return 1;
  }

  @override
  Future<dynamic> stop() async {
    stopCalls++;
    return 1;
  }
}

CurrencyDetection _det(
  String denom,
  int val, {
  int slot = 0,
  double conf = 0.92,
  double margin = 0.85,
}) {
  final double x1 = 10.0 + slot * 120.0;
  return CurrencyDetection(
    classId: 0,
    denomination: denom,
    value: val,
    confidence: conf,
    classMargin: margin,
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
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BisayaNumberNormalizer', () {
    test('Converts all Indian Rupee numbers without digits or Filipino', () {
      expect(BisayaNumberNormalizer.numberToCebuanoWords(0), 'wala');
      expect(BisayaNumberNormalizer.numberToCebuanoWords(1), 'usa');
      expect(BisayaNumberNormalizer.numberToCebuanoWords(2), 'duha');
      expect(BisayaNumberNormalizer.numberToCebuanoWords(5), 'lima');
      expect(BisayaNumberNormalizer.numberToCebuanoWords(10), 'napulo');
      expect(BisayaNumberNormalizer.numberToCebuanoWords(20), 'kawhaan');
      expect(BisayaNumberNormalizer.numberToCebuanoWords(27), 'kawhaan ug pito');
      expect(BisayaNumberNormalizer.numberToCebuanoWords(50), 'kalim-an');
      expect(BisayaNumberNormalizer.numberToCebuanoWords(100), 'usa ka gatos');
      expect(BisayaNumberNormalizer.numberToCebuanoWords(200), 'duha ka gatos');
      expect(BisayaNumberNormalizer.numberToCebuanoWords(400), 'upat ka gatos');
      expect(BisayaNumberNormalizer.numberToCebuanoWords(500), 'lima ka gatos');
      expect(BisayaNumberNormalizer.numberToCebuanoWords(620), 'unom ka gatos ug kawhaan');
      expect(BisayaNumberNormalizer.numberToCebuanoWords(1005), 'usa ka libo ug lima');

      // Ensure 200 never becomes 2000 ("duha ka libo")
      expect(BisayaNumberNormalizer.numberToCebuanoWords(200).contains('libo'), isFalse);
    });

    test('Formats all currency safety states and mixed totals cleanly', () {
      final empty = _assess([]);
      expect(
        CurrencySpeechFormatter.formatAssessment(empty, language: 'ceb-PH'),
        'Walay kwarta nga nakita. Palihug ipaduol pa gamay.',
      );

      final single200 = _assess([('INR_200', 200)]);
      expect(
        CurrencySpeechFormatter.formatAssessment(single200, language: 'ceb-PH'),
        'Usa ka duha ka gatos ka rupee nga papel.',
      );

      final single5Coin = _assess([('COIN_5', 5)]);
      expect(
        CurrencySpeechFormatter.formatAssessment(single5Coin, language: 'ceb-PH'),
        'Usa ka lima ka rupee nga sensilyo.',
      );

      final two200 = _assess([('INR_200', 200), ('INR_200', 200)]);
      expect(
        CurrencySpeechFormatter.formatAssessment(two200, language: 'ceb-PH'),
        'Duha ka duha ka gatos ka rupee nga papel. Kinatibuk-an, upat ka gatos ka rupee.',
      );

      final twentyFiveTwo = _assess([
        ('INR_20', 20),
        ('COIN_5', 5),
        ('COIN_2', 2),
      ]);
      final spoken27 = CurrencySpeechFormatter.formatAssessment(
        twentyFiveTwo,
        language: 'ceb-PH',
      );
      expect(spoken27, contains('Kinatibuk-an, kawhaan ug pito ka rupee.'));
      expect(RegExp(r'\d').hasMatch(spoken27), isFalse);

      final tentative = CurrencySafetyEvaluator.evaluate(
        [_det('INR_50', 50, conf: 0.36)],
        candidateMode: true,
      );
      expect(
        CurrencySpeechFormatter.formatAssessment(tentative, language: 'ceb-PH'),
        contains('Posibleng usa ka kalim-an ka rupee nga papel, apan dili pa kumpirmado.'),
      );
    });
  });

  group('CurrencyLanguageController with Bisaya', () {
    test('Supports 4 languages in exact order with forward/reverse wraparound', () {
      expect(
        kCurrencyLanguages.map((l) => l.code).toList(),
        ['en-IN', 'kn-IN', 'hi-IN', 'ceb-PH'],
      );
      expect(kCurrencyLanguages.last.label, 'Bisaya');

      String? persisted;
      final ctrl = CurrencyLanguageController(
        initialLanguage: 'en-IN',
        onPreferenceChanged: (code) => persisted = code,
      );

      expect(ctrl.navigateDown().code, 'kn-IN');
      expect(ctrl.navigateDown().code, 'hi-IN');
      expect(ctrl.navigateDown().code, 'ceb-PH');
      expect(persisted, 'ceb-PH');
      expect(ctrl.navigateDown().code, 'en-IN');
      expect(ctrl.navigateUp().code, 'ceb-PH');

      final restored = CurrencyLanguageController(initialLanguage: 'ceb-PH');
      expect(restored.selectedCode, 'ceb-PH');
      expect(restored.selectedOption.label, 'Bisaya');
    });
  });

  group('SpeechService Bisaya lazy ONNX integration', () {
    test('Lazy-loads Bisaya only on first ceb-PH request and never falls back on failure', () async {
      final fakeTts = _FakeFlutterTts();
      int initCalls = 0;
      int speakCalls = 0;
      int stopCalls = 0;

      final svc = SpeechService(
        tts: fakeTts,
        bisayaInitFn: () async {
          initCalls++;
          return {'status': 'initialized', 'sampleRate': 16000};
        },
        bisayaSpeakFn: (text, rate) async {
          speakCalls++;
          return 1;
        },
        bisayaStopFn: () async {
          stopCalls++;
          return 1;
        },
      );

      await svc.initialize();
      expect(initCalls, 0);
      expect(svc.languageAvailability.containsKey('ceb-PH'), isFalse);

      await svc.speakText('Usa ka napulo ka rupee nga papel.', language: 'ceb-PH');
      expect(initCalls, 1);
      expect(speakCalls, 1);
      expect(fakeTts.spoken, isEmpty);
      expect(svc.selectedVoices['ceb-PH']?['network_required'], 'false');
      expect(svc.selectedVoices['ceb-PH']?['locale'], 'ceb-PH');

      await svc.stop();
      expect(stopCalls, 1);

      // Missing/failed Bisaya init must not substitute Filipino/English into FlutterTts
      final failTts = _FakeFlutterTts();
      final failSvc = SpeechService(
        tts: failTts,
        bisayaInitFn: () async => null,
      );
      await failSvc.initialize();
      await failSvc.speakText('Bisaya', language: 'ceb-PH');
      expect(failSvc.languageAvailability['ceb-PH'], isFalse);
      expect(failTts.setLanguages.contains('fil-PH'), isFalse);
    });

    test('BisayaSpeechAssembler builds exact clip sequences without synthesis delay', () {
      expect(BisayaSpeechAssembler.clipsForNumber(200), [
        'num_2',
        'part_ka',
        'unit_gatos',
      ]);
      expect(BisayaSpeechAssembler.clipsForNumber(27), [
        'tens_20',
        'conj_ug',
        'num_7',
      ]);
      expect(
        BisayaSpeechAssembler.clipsForAssessment(_assess([])),
        ['prompt_empty'],
      );
      final mixed = _assess([('INR_20', 20), ('COIN_5', 5), ('COIN_2', 2)]);
      final seq = BisayaSpeechAssembler.clipsForAssessment(mixed);
      expect(seq, containsAllInOrder(['prefix_total', 'tens_20', 'conj_ug', 'num_7', 'unit_rupee']));

      // Multiple banknotes + correct total (₹500 + ₹100 + ₹100 = 700)
      final multiNotes = _assess([('INR_500', 500), ('INR_100', 100), ('INR_100', 100)]);
      expect(
        CurrencySpeechFormatter.formatAssessment(multiNotes, language: 'ceb-PH'),
        contains('Kinatibuk-an, pito ka gatos ka rupee.'),
      );
      expect(
        BisayaSpeechAssembler.clipsForAssessment(multiNotes),
        containsAllInOrder(['prefix_total', 'num_7', 'part_ka', 'unit_gatos', 'unit_rupee']),
      );

      // Conflicting / uncertain detection
      final conflict = CurrencySafetyEvaluator.evaluate(
        [_det('INR_50', 50), _det('INR_100', 100, slot: 0)], // overlapping box conflict
        candidateMode: true,
      );
      expect(
        BisayaSpeechAssembler.clipsForAssessment(conflict),
        anyOf(equals(['warn_conflict']), equals(['warn_overlap'])),
      );
    });
  });
}
