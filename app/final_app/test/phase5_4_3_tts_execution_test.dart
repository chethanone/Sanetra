import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:vision_assistant/services/currency_model_service.dart';
import 'package:vision_assistant/services/currency_safety_evaluator.dart';
import 'package:vision_assistant/services/ocr/ocr_result.dart';
import 'package:vision_assistant/services/speech_service.dart';

class FakeFlutterTts implements FlutterTts {
  bool throwOnInit = false;
  bool throwOnGetVoices = false;
  bool throwOnSetLanguage = false;
  bool throwOnSetVoice = false;
  bool throwOnSpeakOnce = false;
  bool hangSpeakOnStop = false;
  bool triggerErrorOnSpeak = false;
  Duration speakDelay = const Duration(milliseconds: 5);

  VoidCallback? _startHandler;
  VoidCallback? _completionHandler;
  VoidCallback? _cancelHandler;
  ErrorHandler? _errorHandler;

  final List<String> calls = [];
  final List<({String text, String? lang, String? voice})> spoken = [];
  String? currentLanguage;
  String? currentVoice;
  int activeSpeakCount = 0;
  int maxConcurrentSpeaks = 0;

  List<Map<String, String>> voices = [
    {'name': 'en-us-x-tpc-local', 'locale': 'en-US', 'network_required': 'false'},
    {'name': 'en-in-x-enc-local', 'locale': 'en-IN', 'network_required': 'false'},
    {'name': 'kn-in-x-knc-local', 'locale': 'kn-IN', 'network_required': 'false'},
    {'name': 'kn-in-x-knd-local', 'locale': 'kn-IN', 'network_required': 'false'},
    {'name': 'hi-in-x-hia-local', 'locale': 'hi-IN', 'network_required': 'false'},
  ];

  @override
  Future<dynamic> awaitSpeakCompletion(bool awaitCompletion) async {
    if (throwOnInit) throw StateError('TTS init failed');
    calls.add('awaitSpeakCompletion($awaitCompletion)');
    return 1;
  }

  @override
  Future<dynamic> setVolume(double volume) async {
    calls.add('setVolume($volume)');
    return 1;
  }

  @override
  Future<dynamic> setPitch(double pitch) async {
    calls.add('setPitch($pitch)');
    return 1;
  }

  @override
  Future<dynamic> setSpeechRate(double rate) async {
    calls.add('setSpeechRate($rate)');
    return 1;
  }

  @override
  void setStartHandler(VoidCallback callback) => _startHandler = callback;

  @override
  void setCompletionHandler(VoidCallback callback) => _completionHandler = callback;

  @override
  void setCancelHandler(VoidCallback callback) => _cancelHandler = callback;

  @override
  void setErrorHandler(ErrorHandler callback) => _errorHandler = callback;

  @override
  Future<dynamic> get getDefaultEngine async => 'com.google.android.tts';

  @override
  Future<dynamic> get getVoices async {
    if (throwOnGetVoices) throw StateError('getVoices failed');
    return voices;
  }

  @override
  Future<dynamic> isLanguageAvailable(String language) async => true;

  @override
  Future<dynamic> setLanguage(String language) async {
    if (throwOnSetLanguage) throw StateError('setLanguage failed');
    currentLanguage = language;
    calls.add('setLanguage($language)');
    return 1;
  }

  @override
  Future<dynamic> setVoice(Map<String, String> voice) async {
    if (throwOnSetVoice) throw StateError('setVoice failed');
    currentVoice = voice['name'];
    calls.add('setVoice(${voice['name']})');
    return 1;
  }

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    if (throwOnSpeakOnce) {
      throwOnSpeakOnce = false;
      throw StateError('speak transient failure');
    }
    activeSpeakCount++;
    if (activeSpeakCount > maxConcurrentSpeaks) {
      maxConcurrentSpeaks = activeSpeakCount;
    }
    _startHandler?.call();
    spoken.add((text: text, lang: currentLanguage, voice: currentVoice));

    if (triggerErrorOnSpeak) {
      triggerErrorOnSpeak = false;
      activeSpeakCount--;
      _errorHandler?.call('SYNTH_ERROR');
      return 0;
    }

    if (hangSpeakOnStop) {
      // Simulate flutter_tts Android bug where speak() Future never resolves when stopped
      await Completer<void>().future;
      return 0;
    }

    await Future<void>.delayed(speakDelay);
    activeSpeakCount--;
    _completionHandler?.call();
    return 1;
  }

  @override
  Future<dynamic> stop() async {
    calls.add('stop()');
    if (activeSpeakCount > 0) {
      activeSpeakCount = 0;
    }
    _cancelHandler?.call();
    return 1;
  }

  @override
  Future<dynamic> synthesizeToFile(String text, String fileName, [bool isFullPath = false]) async => 1;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('Phase 5.4.3 SpeechService Execution, Queue & Recovery', () {
    test('TTS initialization failure is handled safely and recovers on retry', () async {
      final fake = FakeFlutterTts()..throwOnInit = true;
      final svc = SpeechService(tts: fake);

      await svc.initialize();
      expect(svc.isInitialized, isFalse);

      // Retry succeeds once engine recovers
      fake.throwOnInit = false;
      await svc.initialize();
      expect(svc.isInitialized, isTrue);
      expect(svc.selectedVoices['en-IN']?['name'], 'en-in-x-enc-local');
    });

    test('Voice selection failure (getVoices throws) still initializes and speaks', () async {
      final fake = FakeFlutterTts()..throwOnGetVoices = true;
      final svc = SpeechService(tts: fake);

      await svc.initialize();
      expect(svc.isInitialized, isFalse);

      fake.throwOnGetVoices = false;
      fake.voices = [];
      await svc.initialize();
      expect(svc.isInitialized, isTrue);
      expect(svc.selectedVoices, isEmpty);

      await svc.speakText('Hello', language: 'en-IN');
      expect(fake.spoken.map((s) => s.text), ['Hello']);
    });

    test('setLanguage failure aborts utterance cleanly and recovers for next request', () async {
      final fake = FakeFlutterTts();
      final svc = SpeechService(tts: fake);
      await svc.initialize();

      fake.throwOnSetLanguage = true;
      await svc.speakText('Will fail', language: 'kn-IN');
      expect(fake.spoken, isEmpty);
      expect(svc.isSpeaking, isFalse);

      fake.throwOnSetLanguage = false;
      await svc.speakText('Recovers', language: 'en-IN');
      expect(fake.spoken.map((s) => s.text), ['Recovers']);
      expect(svc.isSpeaking, isFalse);
    });

    test('setVoice failure warns safely and still speaks via locale', () async {
      final fake = FakeFlutterTts()..throwOnSetVoice = true;
      final svc = SpeechService(tts: fake);
      await svc.initialize();

      await svc.speakText('Still speaks', language: 'en-IN');
      expect(fake.spoken.map((s) => s.text), ['Still speaks']);
      expect(svc.isSpeaking, isFalse);
    });

    test('Successful speech request triggers onStart/onDone and restores English voice', () async {
      final fake = FakeFlutterTts();
      final svc = SpeechService(tts: fake);
      await svc.initialize();

      await svc.speakText('ಕನ್ನಡ', language: 'kn-IN');
      expect(fake.spoken, [
        (text: 'ಕನ್ನಡ', lang: 'kn-IN', voice: 'kn-in-x-knd-local'),
      ]);
      expect(svc.isSpeaking, isFalse);
      // After temporary Kannada utterance, English locale + voice are restored
      expect(fake.currentLanguage, 'en-IN');
      expect(fake.currentVoice, 'en-in-x-enc-local');
    });

    test('TTS onError unblocks caller and queue recovers for subsequent speech', () async {
      final fake = FakeFlutterTts();
      final svc = SpeechService(tts: fake);
      await svc.initialize();

      fake.triggerErrorOnSpeak = true;
      await svc.speakText('Error utterance', language: 'en-IN');
      expect(svc.isSpeaking, isFalse);

      await svc.speakText('Next utterance', language: 'en-IN');
      expect(fake.spoken.map((s) => s.text), ['Error utterance', 'Next utterance']);
      expect(svc.isSpeaking, isFalse);
    });

    test('Speech cancellation unblocks hung speak() future immediately', () async {
      final fake = FakeFlutterTts()..hangSpeakOnStop = true;
      final svc = SpeechService(tts: fake);
      await svc.initialize();

      final firstFuture = svc.speakText('Hung speech', language: 'en-IN');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // stop() must unblock firstFuture immediately even though fake speak() never resolves
      await svc.stop();
      await firstFuture.timeout(const Duration(milliseconds: 200));
      expect(svc.isSpeaking, isFalse);

      fake.hangSpeakOnStop = false;
      await svc.speakText('After stop', language: 'en-IN');
      expect(fake.spoken.last.text, 'After stop');
    });

    test('Rapid language switching serializes without overlap and speaks latest', () async {
      final fake = FakeFlutterTts()..speakDelay = const Duration(milliseconds: 15);
      final svc = SpeechService(tts: fake);
      await svc.initialize();

      final f1 = svc.speakText('English', language: 'en-IN', interrupt: true);
      final f2 = svc.speakText('ಕನ್ನಡ', language: 'kn-IN', interrupt: true);
      final f3 = svc.speakText('हिन्दी', language: 'hi-IN', interrupt: true);
      await Future.wait([f1, f2, f3]);

      expect(fake.maxConcurrentSpeaks, 1);
      expect(fake.spoken.last.text, 'हिन्दी');
      expect(fake.spoken.last.lang, 'hi-IN');
      expect(fake.spoken.last.voice, 'hi-in-x-hia-local');
      expect(fake.currentLanguage, 'en-IN');
      expect(fake.currentVoice, 'en-in-x-enc-local');
    });

    test('Queue recovers after transient speak exception', () async {
      final fake = FakeFlutterTts()..throwOnSpeakOnce = true;
      final svc = SpeechService(tts: fake);
      await svc.initialize();

      await svc.speakText('Transient error', language: 'en-IN');
      await svc.speakText('Recovered', language: 'en-IN');
      expect(fake.spoken.map((s) => s.text), ['Recovered']);
    });

    test('Currency speech and OCR speech execute cleanly across languages', () async {
      final fake = FakeFlutterTts();
      final svc = SpeechService(tts: fake);
      await svc.initialize();

      const det1 = CurrencyDetection(
        classId: 4,
        denomination: 'INR_200',
        value: 200,
        confidence: 0.95,
        x1: 0,
        y1: 0,
        x2: 100,
        y2: 100,
      );
      const det2 = CurrencyDetection(
        classId: 4,
        denomination: 'INR_200',
        value: 200,
        confidence: 0.95,
        x1: 120,
        y1: 0,
        x2: 220,
        y2: 100,
      );
      final assessment = CurrencySafetyEvaluator.evaluate(
        const [det1, det2],
        candidateMode: true,
      );

      await svc.speakCurrencyAssessment(assessment, language: 'en-IN');
      expect(
        fake.spoken.last.text,
        'Two 200-rupee notes. Total four hundred rupees.',
      );

      const poly = OcrPolygon(
        topLeft: OcrPoint(0, 0),
        topRight: OcrPoint(10, 0),
        bottomRight: OcrPoint(10, 10),
        bottomLeft: OcrPoint(0, 10),
        score: 0.9,
      );
      await svc.speakOcrLines([
        const OcrLineResult(
          text: 'Hello',
          language: 'en-IN',
          confidence: 0.9,
          polygon: poly,
          lineIndex: 0,
        ),
        const OcrLineResult(
          text: 'ಬೆಂಗಳೂರು',
          language: 'kn-IN',
          confidence: 0.9,
          polygon: poly,
          lineIndex: 1,
        ),
      ]);
      expect(fake.spoken.map((s) => s.text).toList(), [
        'Two 200-rupee notes. Total four hundred rupees.',
        'Hello',
        'ಬೆಂಗಳೂರು',
      ]);
      expect(fake.currentLanguage, 'en-IN');
      expect(fake.currentVoice, 'en-in-x-enc-local');
    });
  });
}
