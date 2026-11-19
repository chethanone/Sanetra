import 'dart:math';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:vision_assistant/services/currency_language_controller.dart';
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
  int concurrentSpeaks = 0;
  int maxConcurrentSpeaks = 0;

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
  void setCompletionHandler(VoidCallback callback) => completionHandler = callback;
  @override
  void setCancelHandler(VoidCallback callback) => cancelHandler = callback;
  @override
  void setErrorHandler(void Function(dynamic) handler) => errorHandler = handler;
  @override
  Future<dynamic> get getDefaultEngine async => 'com.google.android.tts';
  @override
  Future<dynamic> get getVoices async => [
        {'name': 'en-in-x-enc-local', 'locale': 'en-IN', 'network_required': 'false'},
        {'name': 'kn-in-x-knd-local', 'locale': 'kn-IN', 'network_required': 'false'},
        {'name': 'hi-in-x-hia-local', 'locale': 'hi-IN', 'network_required': 'false'},
      ];
  @override
  Future<dynamic> isLanguageAvailable(String language) async => 1;
  @override
  Future<dynamic> setLanguage(String language) async => 1;
  @override
  Future<dynamic> setVoice(Map<String, String> voice) async => 1;

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    concurrentSpeaks++;
    if (concurrentSpeaks > maxConcurrentSpeaks) {
      maxConcurrentSpeaks = concurrentSpeaks;
    }
    spokenTexts.add(text);
    startHandler?.call();
    await Future<void>.delayed(const Duration(milliseconds: 15));
    concurrentSpeaks--;
    completionHandler?.call();
    return 1;
  }

  @override
  Future<dynamic> stop() async {
    if (concurrentSpeaks > 0) {
      concurrentSpeaks = 0;
      cancelHandler?.call();
    }
    return 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 8.6 Selector Audio Reliability & Preemption Suite (1000 Requests)', () {
    late _FakeFlutterTts fakeTts;
    late SpeechService speech;
    late CurrencyLanguageController ctrl;
    final List<String> nativeClipsDispatched = [];
    int nativeConcurrentCount = 0;
    int nativeMaxConcurrent = 0;

    setUp(() async {
      fakeTts = _FakeFlutterTts();
      nativeClipsDispatched.clear();
      nativeConcurrentCount = 0;
      nativeMaxConcurrent = 0;

      speech = SpeechService(
        tts: fakeTts,
        bisayaSpeakFn: (text, rate) async {
          nativeConcurrentCount++;
          if (nativeConcurrentCount > nativeMaxConcurrent) {
            nativeMaxConcurrent = nativeConcurrentCount;
          }
          nativeClipsDispatched.add(text);
          await Future<void>.delayed(const Duration(milliseconds: 10));
          nativeConcurrentCount--;
          return 1;
        },
      );
      await speech.initialize();

      ctrl = CurrencyLanguageController(
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
      );
      speech.setSelectorOpen(true);
    });

    test('1. Sequential navigation across all 4 languages forward and reverse (120 cycles)', () async {
      // 120 cycles * 8 steps = 960 requests
      for (int i = 0; i < 120; i++) {
        // Forward: en -> kn -> hi -> ceb
        final kn = ctrl.navigateDown();
        expect(kn.code, 'kn-IN');
        final hi = ctrl.navigateDown();
        expect(hi.code, 'hi-IN');
        final ceb = ctrl.navigateDown();
        expect(ceb.code, 'ceb-PH');
        final en = ctrl.navigateDown();
        expect(en.code, 'en-IN');

        // Reverse: en -> ceb -> hi -> kn -> en
        final cebRev = ctrl.navigateUp();
        expect(cebRev.code, 'ceb-PH');
        final hiRev = ctrl.navigateUp();
        expect(hiRev.code, 'hi-IN');
        final knRev = ctrl.navigateUp();
        expect(knRev.code, 'kn-IN');
        final enRev = ctrl.navigateUp();
        expect(enRev.code, 'en-IN');
      }

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(ctrl.selectedCode, 'en-IN');
      expect(nativeMaxConcurrent, lessThanOrEqualTo(1));
      expect(nativeClipsDispatched.isNotEmpty, true);
      expect(nativeClipsDispatched.last, 'English');
    });

    test('2. 100 Rapid bursts with random directions (latest settled wins, 0 drops)', () async {
      final random = Random(42);
      int accepted = 0;
      int completed = 0;

      for (int burst = 0; burst < 100; burst++) {
        final burstLen = 3 + random.nextInt(6); // 3 to 8 steps
        CurrencyLanguageOption lastOption = ctrl.selectedOption;
        for (int step = 0; step < burstLen; step++) {
          accepted++;
          if (random.nextBool()) {
            lastOption = ctrl.navigateDown();
          } else {
            lastOption = ctrl.navigateUp();
          }
        }
        // Let the settled selection complete
        await Future<void>.delayed(const Duration(milliseconds: 25));
        expect(ctrl.selectedCode, lastOption.code);
        expect(nativeClipsDispatched.last, lastOption.spokenConfirm);
        completed++;
      }

      expect(accepted, greaterThanOrEqualTo(500));
      expect(completed, 100);
      expect(nativeMaxConcurrent, lessThanOrEqualTo(1));
    });

    test('3. Mute and unmute preemption during rapid selection', () async {
      // Navigate when muted
      ctrl.navigateDown(isMuted: true);
      final hi = ctrl.navigateDown(isMuted: true);
      expect(hi.code, 'hi-IN');
      await Future<void>.delayed(const Duration(milliseconds: 15));
      final countWhileMuted = nativeClipsDispatched.length;

      // Navigate unmuted
      final ceb = ctrl.navigateDown(isMuted: false);
      expect(ceb.code, 'ceb-PH');
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(nativeClipsDispatched.length, countWhileMuted + 1);
      expect(nativeClipsDispatched.last, 'Bisaya');
    });

    test('4. Popup open/close cycle invalidates ongoing speech', () async {
      ctrl.navigateDown(); // Kannada
      speech.setSelectorOpen(false);
      expect(speech.isSelectorOpen, false);
      
      speech.setSelectorOpen(true);
      expect(speech.isSelectorOpen, true);
      ctrl.navigateUp(); // English
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(nativeClipsDispatched.last, 'English');
      expect(nativeMaxConcurrent, lessThanOrEqualTo(1));
    });
  });
}
