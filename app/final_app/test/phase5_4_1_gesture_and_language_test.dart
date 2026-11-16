import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vision_assistant/services/currency_language_controller.dart';

void main() {
  group('Phase 5.4.1 Volume Gesture 2000ms Timing', () {
    test('1999 ms hold does not trigger Volume Up or Volume Down long-press', () async {
      var modeToggles = 0;
      var popupToggles = 0;
      var sysVolUp = 0;
      var sysVolDown = 0;

      final sm = VolumeGestureStateMachine(
        longPressDuration: const Duration(milliseconds: 2000),
        onVolumeUpLongPress: () => modeToggles++,
        onVolumeDownLongPress: () => popupToggles++,
        onSystemVolumeUp: () => sysVolUp++,
        onSystemVolumeDown: () => sysVolDown++,
      );

      // Hold Volume Up for 1999 ms (simulated via delayed release before 2000ms)
      sm.onVolumeUpDown();
      await Future<void>.delayed(const Duration(milliseconds: 1950));
      sm.onVolumeUpUp();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(modeToggles, 0);
      expect(sysVolUp, 1);

      // Hold Volume Down for < 2000 ms
      sm.onVolumeDownDown();
      await Future<void>.delayed(const Duration(milliseconds: 1950));
      sm.onVolumeDownUp();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(popupToggles, 0);
      expect(sysVolDown, 1);
      sm.cancelAll();
    });

    test('2000 ms hold triggers exactly once and longer holds do not repeat', () async {
      var modeToggles = 0;
      var popupToggles = 0;
      var sysVolUp = 0;

      final sm = VolumeGestureStateMachine(
        longPressDuration: const Duration(milliseconds: 2000),
        onVolumeUpLongPress: () => modeToggles++,
        onVolumeDownLongPress: () => popupToggles++,
        onSystemVolumeUp: () => sysVolUp++,
      );

      sm.onVolumeUpDown();
      // Simulate OS repeat events while key is still held down
      sm.onVolumeUpDown(repeatCount: 1);
      sm.onVolumeUpDown(repeatCount: 2);
      await Future<void>.delayed(const Duration(milliseconds: 2600));
      expect(modeToggles, 1);
      expect(sysVolUp, 0);

      // Release key
      sm.onVolumeUpUp();
      expect(modeToggles, 1);
      expect(sysVolUp, 0);

      // Volume Down 2000 ms hold triggers once even when held longer
      sm.onVolumeDownDown();
      sm.onVolumeDownDown(repeatCount: 1);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(popupToggles, 1);
      sm.onVolumeDownUp();
      sm.cancelAll();
    });

    test('Key release resets the gesture so a second hold triggers again', () async {
      var modeToggles = 0;
      final sm = VolumeGestureStateMachine(
        longPressDuration: const Duration(milliseconds: 200),
        onVolumeUpLongPress: () => modeToggles++,
      );

      // First hold
      sm.onVolumeUpDown();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(modeToggles, 1);
      sm.onVolumeUpUp();

      // Second hold after release
      sm.onVolumeUpDown();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(modeToggles, 2);
      sm.onVolumeUpUp();
      sm.cancelAll();
    });

    test('Long-press Volume Down closes the selector when it is open', () async {
      var popupOpen = false;
      var popupToggles = 0;
      var popupVolDownSteps = 0;
      var sysVolDown = 0;

      late final VolumeGestureStateMachine sm;
      sm = VolumeGestureStateMachine(
        longPressDuration: const Duration(milliseconds: 200),
        onVolumeDownLongPress: () {
          popupToggles++;
          popupOpen = !popupOpen;
          sm.isLanguagePopupOpen = popupOpen;
        },
        onPopupVolumeDown: () => popupVolDownSteps++,
        onSystemVolumeDown: () => sysVolDown++,
      );

      // Long-press Volume Down to open
      sm.onVolumeDownDown();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      sm.onVolumeDownUp();
      expect(popupOpen, isTrue);
      expect(popupToggles, 1);
      expect(popupVolDownSteps, 0);
      expect(sysVolDown, 0);

      // Long-press Volume Down while open closes selector
      sm.onVolumeDownDown();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      sm.onVolumeDownUp();
      expect(popupOpen, isFalse);
      expect(popupToggles, 2);
      expect(popupVolDownSteps, 0);
      expect(sysVolDown, 0);
      sm.cancelAll();
    });

    test('Short volume presses inside popup navigate without changing system volume', () {
      var popupUp = 0;
      var popupDown = 0;
      var sysUp = 0;
      var sysDown = 0;

      final sm = VolumeGestureStateMachine(
        longPressDuration: const Duration(milliseconds: 2000),
        onPopupVolumeUp: () => popupUp++,
        onPopupVolumeDown: () => popupDown++,
        onSystemVolumeUp: () => sysUp++,
        onSystemVolumeDown: () => sysDown++,
      )..isLanguagePopupOpen = true;

      sm.onVolumeUpDown();
      sm.onVolumeUpUp();
      sm.onVolumeDownDown();
      sm.onVolumeDownUp();

      expect(popupUp, 1);
      expect(popupDown, 1);
      expect(sysUp, 0);
      expect(sysDown, 0);
      sm.cancelAll();
    });
  });

  group('Phase 5.4.1 Language Navigation & Immediate Speech', () {
    test('Visual language order remains English, Kannada, Hindi', () {
      expect(
        kCurrencyLanguages.map((l) => l.code).toList(),
        const ['en-IN', 'kn-IN', 'hi-IN'],
      );
      expect(
        kCurrencyLanguages.map((l) => l.spokenConfirm).toList(),
        const ['English', 'ಕನ್ನಡ', 'हिन्दी'],
      );
    });

    test('Volume Up moves to previous item and wraps English -> Hindi', () {
      final controller = CurrencyLanguageController(initialLanguage: 'en-IN');

      // English -> Hindi (wraparound)
      expect(controller.navigateUp().code, 'hi-IN');
      expect(controller.selectedCode, 'hi-IN');

      // Hindi -> Kannada
      expect(controller.navigateUp().code, 'kn-IN');
      expect(controller.selectedCode, 'kn-IN');

      // Kannada -> English
      expect(controller.navigateUp().code, 'en-IN');
      expect(controller.selectedCode, 'en-IN');
    });

    test('Volume Down moves to next item and wraps Hindi -> English', () {
      final controller = CurrencyLanguageController(initialLanguage: 'en-IN');

      // English -> Kannada
      expect(controller.navigateDown().code, 'kn-IN');
      expect(controller.selectedCode, 'kn-IN');

      // Kannada -> Hindi
      expect(controller.navigateDown().code, 'hi-IN');
      expect(controller.selectedCode, 'hi-IN');

      // Hindi -> English (wraparound)
      expect(controller.navigateDown().code, 'en-IN');
      expect(controller.selectedCode, 'en-IN');
    });

    test('Language preference updates and announcement starts immediately without debounce', () async {
      final prefUpdates = <String>[];
      final spoken = <({String text, String language, bool interrupt})>[];

      final controller = CurrencyLanguageController(
        initialLanguage: 'en-IN',
        onPreferenceChanged: prefUpdates.add,
        onStopSpeech: () async {},
        onSpeak: (text, {required language, required interrupt}) async {
          spoken.add((text: text, language: language, interrupt: interrupt));
        },
      );

      controller.navigateDown();
      // Synchronous preference update before any timer or async wait
      expect(controller.selectedCode, 'kn-IN');
      expect(prefUpdates, ['kn-IN']);

      // Microtask completes immediate stop + speak without any debounce delay
      await Future<void>.delayed(Duration.zero);
      expect(spoken, [
        (text: 'ಕನ್ನಡ', language: 'kn-IN', interrupt: true),
      ]);
    });

    test('Rapid navigation cancels outdated announcements and prevents overlapping speech', () async {
      final prefUpdates = <String>[];
      final spoken = <({String text, String language})>[];
      var stopCalls = 0;
      var activeSpeakCalls = 0;
      var maxConcurrentSpeak = 0;
      final firstStopCompleter = Completer<void>();

      final controller = CurrencyLanguageController(
        initialLanguage: 'en-IN',
        onPreferenceChanged: prefUpdates.add,
        onStopSpeech: () async {
          stopCalls++;
          if (stopCalls == 1) {
            await firstStopCompleter.future;
          }
        },
        onSpeak: (text, {required language, required interrupt}) async {
          activeSpeakCalls++;
          if (activeSpeakCalls > maxConcurrentSpeak) {
            maxConcurrentSpeak = activeSpeakCalls;
          }
          spoken.add((text: text, language: language));
          await Future<void>.delayed(const Duration(milliseconds: 10));
          activeSpeakCalls--;
        },
      );

      // Rapid presses: English -> Kannada -> Hindi -> English
      controller.navigateDown(); // kn-IN (outdated)
      controller.navigateDown(); // hi-IN (outdated)
      controller.navigateDown(); // en-IN (latest)

      // Preference changed immediately on every step
      expect(prefUpdates, ['kn-IN', 'hi-IN', 'en-IN']);
      expect(controller.selectedCode, 'en-IN');

      // Release the first stop() call; outdated epochs must bail out without speaking
      firstStopCompleter.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(stopCalls, 3);
      expect(maxConcurrentSpeak, 1);
      expect(spoken, [(text: 'English', language: 'en-IN')]);
    });
  });
}
