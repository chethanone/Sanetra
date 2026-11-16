import 'package:flutter_test/flutter_test.dart';
import 'package:vision_assistant/services/mode_transition_controller.dart';

void main() {
  group('Phase 5.10 Language Selector 4-Second Timing', () {
    test('Popup remains open for at least 4 seconds and closes after 4s inactivity',
        () async {
      var timedOut = 0;
      final ctrl = ModeTransitionController(
        selectorInactivityTimeout: const Duration(seconds: 4),
        onSelectorTimeout: () => timedOut++,
      );

      ctrl.openSelector();
      expect(ctrl.isSelectorOpen, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 2200));
      expect(ctrl.isSelectorOpen, isTrue);
      expect(timedOut, 0);

      await Future<void>.delayed(const Duration(milliseconds: 1600));
      expect(ctrl.isSelectorOpen, isTrue);
      expect(timedOut, 0);

      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(ctrl.isSelectorOpen, isFalse);
      expect(timedOut, 1);
      ctrl.dispose();
    });

    test('Navigation resets the 4-second timer and rapid navigation keeps popup open',
        () async {
      var timedOut = 0;
      final ctrl = ModeTransitionController(
        selectorInactivityTimeout: const Duration(seconds: 4),
        onSelectorTimeout: () => timedOut++,
      );

      ctrl.openSelector();
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(ctrl.isSelectorOpen, isTrue);

      // Simulate rapid navigation presses resetting the 4s timer
      ctrl.resetSelectorTimer();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      ctrl.resetSelectorTimer();
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(ctrl.isSelectorOpen, isTrue);
      expect(timedOut, 0);

      // Explicit 2-second Volume Down close works immediately
      ctrl.closeSelector();
      expect(ctrl.isSelectorOpen, isFalse);
      expect(timedOut, 0);
      ctrl.dispose();
    });
  });

  group('Phase 5.10 Automatic One-Shot OCR Read Mode', () {
    test('Currency -> OCR triggers exactly one auto capture; duplicate calls ignored',
        () {
      final triggeredGens = <int>[];
      final stoppedGens = <int>[];
      final ctrl = ModeTransitionController(
        onTriggerAutoOcr: triggeredGens.add,
        onStopOcr: stoppedGens.add,
      );

      expect(ctrl.isCurrencyMode, isTrue);

      // First 2s Volume Up hold: Currency -> OCR
      final g1 = ctrl.toggleMode();
      expect(g1, isNotNull);
      expect(ctrl.isCurrencyMode, isFalse);
      expect(triggeredGens, [g1]);
      expect(ctrl.isOcrGenerationValid(g1!), isTrue);

      // Duplicate setMode(false) does NOT trigger a second capture
      final dup = ctrl.setMode(false);
      expect(dup, isNull);
      expect(triggeredGens.length, 1);

      // Second 2s Volume Up hold: OCR -> Currency cancels active OCR & invalidates stale results
      final g2 = ctrl.toggleMode();
      expect(g2, isNotNull);
      expect(ctrl.isCurrencyMode, isTrue);
      expect(stoppedGens, [g2]);
      expect(ctrl.isOcrGenerationValid(g1), isFalse);

      // Re-entering OCR triggers one new capture with a fresh generation ID
      final g3 = ctrl.toggleMode();
      expect(g3, isNotNull);
      expect(ctrl.isCurrencyMode, isFalse);
      expect(triggeredGens, [g1, g3]);
      expect(ctrl.isOcrGenerationValid(g3!), isTrue);
      expect(ctrl.isOcrGenerationValid(g1), isFalse);

      ctrl.dispose();
    });
  });
}
