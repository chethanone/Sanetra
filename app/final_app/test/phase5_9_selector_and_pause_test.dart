import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:vision_assistant/services/currency_language_controller.dart';
import 'package:vision_assistant/services/currency_safety_evaluator.dart';
import 'package:vision_assistant/services/currency_model_service.dart';
import 'package:vision_assistant/services/speech_service.dart';

class _FakeFlutterTts extends Fake implements FlutterTts {
  @override
  VoidCallback? startHandler;
  @override
  VoidCallback? completionHandler;
  @override
  VoidCallback? cancelHandler;
  @override
  void Function(dynamic)? errorHandler;

  final List<String> spokenTexts = [];
  final List<String> spokenLangs = [];
  final List<String> appliedVoices = [];
  int stopCalls = 0;
  int concurrentSpeakCount = 0;
  int maxConcurrentSpeaks = 0;

  String _currentLang = 'en-IN';
  Completer<int>? _activeSpeakCompleter;
  bool holdSpeakUntilStopped = true;

  @override
  Future<dynamic> awaitSpeakCompletion(bool awaitCompletion) async => 1;

  @override
  Future<dynamic> setVolume(double volume) async => 1;

  @override
  Future<dynamic> setPitch(double pitch) async => 1;

  @override
  Future<dynamic> setSpeechRate(double rate) async => 1;

  @override
  void setStartHandler(VoidCallback callback) => startHandler = callback;

  @override
  void setCompletionHandler(VoidCallback callback) =>
      completionHandler = callback;

  @override
  void setCancelHandler(VoidCallback callback) => cancelHandler = callback;

  @override
  void setErrorHandler(void Function(dynamic) handler) => errorHandler = handler;

  @override
  Future<dynamic> get getDefaultEngine async => 'com.google.android.tts';

  @override
  Future<dynamic> get getVoices async => [
        {
          'name': 'en-in-x-enc-local',
          'locale': 'en-IN',
          'network_required': 'false',
        },
        {
          'name': 'kn-in-x-knd-local',
          'locale': 'kn-IN',
          'network_required': 'false',
        },
        {
          'name': 'hi-in-x-hia-local',
          'locale': 'hi-IN',
          'network_required': 'false',
        },
      ];

  @override
  Future<dynamic> isLanguageAvailable(String language) async => 1;

  @override
  Future<dynamic> setLanguage(String language) async {
    _currentLang = language;
    return 1;
  }

  @override
  Future<dynamic> setVoice(Map<String, String> voice) async {
    appliedVoices.add('${voice['locale']}:${voice['name']}');
    return 1;
  }

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    concurrentSpeakCount++;
    if (concurrentSpeakCount > maxConcurrentSpeaks) {
      maxConcurrentSpeaks = concurrentSpeakCount;
    }
    spokenTexts.add(text);
    spokenLangs.add(_currentLang);
    final c = Completer<int>();
    _activeSpeakCompleter = c;

    startHandler?.call();

    if (!holdSpeakUntilStopped) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      if (!c.isCompleted) {
        completionHandler?.call();
        c.complete(1);
      }
    }

    final res = await c.future;
    concurrentSpeakCount--;
    return res;
  }

  @override
  Future<dynamic> stop() async {
    stopCalls++;
    final c = _activeSpeakCompleter;
    _activeSpeakCompleter = null;
    if (c != null && !c.isCompleted) {
      cancelHandler?.call();
      c.complete(0);
    }
    return 1;
  }

  void finishCurrentSpeak() {
    final c = _activeSpeakCompleter;
    _activeSpeakCompleter = null;
    if (c != null && !c.isCompleted) {
      completionHandler?.call();
      c.complete(1);
    }
  }
}

CurrencySafetyAssessment _dummyAssessment() {
  const det = CurrencyDetection(
    classId: 5,
    denomination: 'INR_500',
    value: 500,
    confidence: 0.95,
    x1: 72,
    y1: 128,
    x2: 360,
    y2: 640,
    type: 'banknote',
  );
  return CurrencySafetyEvaluator.evaluate(
    const [det],
    candidateMode: true,
    imageWidth: 720,
    imageHeight: 1280,
  );
}

void main() {
  group('Phase 5.9 Instant Preemptive Language Selector & Currency Pause', () {
    test('Currency speech is blocked while selector is open and resumes after close',
        () async {
      final fakeTts = _FakeFlutterTts()..holdSpeakUntilStopped = false;
      final speech = SpeechService(tts: fakeTts);
      await speech.initialize();

      final assessment = _dummyAssessment();
      await speech.speakCurrencyAssessment(assessment, language: 'en-IN');
      expect(fakeTts.spokenTexts.length, 1);

      // Open selector: active/future currency & OCR speech must be blocked.
      speech.setSelectorOpen(true);
      await speech.speakCurrencyAssessment(assessment, language: 'en-IN');
      await speech.speakText('OCR background text', language: 'en-IN');
      expect(fakeTts.spokenTexts.length, 1);

      // Close selector: ordinary currency speech resumes cleanly.
      speech.setSelectorOpen(false);
      await speech.speakCurrencyAssessment(assessment, language: 'kn-IN');
      expect(fakeTts.spokenTexts.length, 2);
      expect(fakeTts.spokenLangs.last, 'kn-IN');
    });

    test('Kannada -> Hindi -> English rapid preemptive navigation: latest wins, zero overlap',
        () async {
      final fakeTts = _FakeFlutterTts()..holdSpeakUntilStopped = true;
      final speech = SpeechService(tts: fakeTts);
      await speech.initialize();

      String persisted = 'en-IN';
      final ctrl = CurrencyLanguageController(
        initialLanguage: 'en-IN',
        onPreemptSpeak: (
          text, {
          required language,
          required generationId,
          int keyAgeMs = 0,
          int? stateUpdateOffsetMs,
        }) =>
            speech.announceSelectorLanguage(
          text,
          language: language,
          generationId: generationId,
          keyAgeMs: keyAgeMs,
          stateUpdateOffsetMs: stateUpdateOffsetMs,
        ),
        onStopSpeech: () => speech.stop(),
        onPreferenceChanged: (code) => persisted = code,
      );

      speech.setSelectorOpen(true);

      // 1. Press Volume Down -> Kannada
      final kn = ctrl.navigateDown();
      expect(kn.code, 'kn-IN');
      expect(ctrl.selectedCode, 'kn-IN');
      expect(persisted, 'kn-IN');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // 2. Before Kannada finishes, press Volume Down -> Hindi (must interrupt Kannada!)
      final hi = ctrl.navigateDown();
      expect(hi.code, 'hi-IN');
      expect(ctrl.selectedCode, 'hi-IN');
      expect(persisted, 'hi-IN');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // 3. Before Hindi finishes, press Volume Down -> Bisaya -> English
      final ceb = ctrl.navigateDown();
      expect(ceb.code, 'ceb-PH');
      final en = ctrl.navigateDown();
      expect(en.code, 'en-IN');
      expect(ctrl.selectedCode, 'en-IN');
      expect(persisted, 'en-IN');
      await Future<void>.delayed(const Duration(milliseconds: 25));

      // Latest language (English) must be active and spoken last, with zero overlap.
      expect(fakeTts.maxConcurrentSpeaks, 1);
      expect(fakeTts.spokenLangs.last, 'en-IN');
      expect(fakeTts.spokenTexts.last, 'English');
      expect(fakeTts.stopCalls, greaterThanOrEqualTo(2));

      // Stale completion does not deadlock or roll back selected language.
      fakeTts.finishCurrentSpeak();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(ctrl.selectedCode, 'en-IN');
      expect(speech.isSpeaking, isFalse);

      // Verify approved voice identities were preserved.
      expect(
        speech.selectedVoices['en-IN']?['name'],
        'en-in-x-enc-local',
      );
      expect(
        speech.selectedVoices['kn-IN']?['name'],
        'kn-in-x-knd-local',
      );
      expect(
        speech.selectedVoices['hi-IN']?['name'],
        'hi-in-x-hia-local',
      );
    });

    test('Very rapid burst skips intermediate stale generations and speaks only final selection',
        () async {
      final fakeTts = _FakeFlutterTts()..holdSpeakUntilStopped = false;
      final speech = SpeechService(tts: fakeTts);
      await speech.initialize();

      final ctrl = CurrencyLanguageController(
        initialLanguage: 'en-IN',
        onPreemptSpeak: (
          text, {
          required language,
          required generationId,
          int keyAgeMs = 0,
          int? stateUpdateOffsetMs,
        }) =>
            speech.announceSelectorLanguage(
          text,
          language: language,
          generationId: generationId,
          keyAgeMs: keyAgeMs,
          stateUpdateOffsetMs: stateUpdateOffsetMs,
        ),
      );

      speech.setSelectorOpen(true);

      // Synchronous burst: en -> kn -> hi -> ceb -> en -> kn (final = kn-IN)
      ctrl.navigateDown();
      ctrl.navigateDown();
      ctrl.navigateDown();
      ctrl.navigateDown();
      ctrl.navigateDown();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(ctrl.selectedCode, 'kn-IN');
      expect(fakeTts.maxConcurrentSpeaks, 1);
      expect(fakeTts.spokenLangs.last, 'kn-IN');
      expect(fakeTts.spokenTexts.last, 'ಕನ್ನಡ');
      // Only the winning latest generation ran instead of queuing all 4!
      expect(fakeTts.spokenTexts.length, 1);

      speech.setSelectorOpen(false);
    });
  });
}
