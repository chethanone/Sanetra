import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:vision_assistant/services/mode_transition_controller.dart';

/// Mirrors MainActivity.kt Volume Up double-press (450 ms) & 2-second hold (2000 ms)
/// state machine for deterministic automated testing.
class NativeVolUpMirror {
  NativeVolUpMirror({
    required this.onLongPress,
    required this.onDoublePress,
    required this.onAdjustVolume,
  });

  final void Function() onLongPress;
  final void Function() onDoublePress;
  final void Function() onAdjustVolume;

  bool isOcrModeActive = false;
  bool isLanguagePopupOpen = false;
  bool volUpPressed = false;
  bool volUpLongTriggered = false;
  bool volUpAwaitingSecondTap = false;
  bool volUpSecondTapDown = false;

  Timer? _longTimer;
  Timer? _singleTapTimer;

  void onKeyDown({int repeatCount = 0}) {
    if (repeatCount > 0 || volUpPressed) return;
    volUpPressed = true;
    volUpLongTriggered = false;
    if (isLanguagePopupOpen) return;

    if (isOcrModeActive && volUpAwaitingSecondTap) {
      _singleTapTimer?.cancel();
      volUpAwaitingSecondTap = false;
      volUpSecondTapDown = true;
    } else {
      volUpSecondTapDown = false;
    }
    _longTimer = Timer(const Duration(milliseconds: 2000), () {
      if (volUpPressed && !volUpLongTriggered && !isLanguagePopupOpen) {
        volUpLongTriggered = true;
        volUpAwaitingSecondTap = false;
        volUpSecondTapDown = false;
        _singleTapTimer?.cancel();
        onLongPress();
      }
    });
  }

  void onKeyUp() {
    _longTimer?.cancel();
    final wasTriggered = volUpLongTriggered;
    final wasPopup = isLanguagePopupOpen;
    final wasSecondTap = volUpSecondTapDown;
    volUpPressed = false;
    volUpLongTriggered = false;
    volUpSecondTapDown = false;
    if (!wasTriggered && !wasPopup) {
      if (wasSecondTap && isOcrModeActive) {
        onDoublePress();
      } else if (isOcrModeActive) {
        volUpAwaitingSecondTap = true;
        _singleTapTimer?.cancel();
        _singleTapTimer = Timer(const Duration(milliseconds: 450), () {
          if (volUpAwaitingSecondTap) {
            volUpAwaitingSecondTap = false;
            onAdjustVolume();
          }
        });
      } else {
        onAdjustVolume();
      }
    }
  }

  void dispose() {
    _longTimer?.cancel();
    _singleTapTimer?.cancel();
  }
}

void main() {
  test('1-4: Single short press preserves volume after 450ms; double press triggers 1 reread without volume change', () async {
    int rereads = 0;
    int volumes = 0;
    late ModeTransitionController modeCtrl;
    final native = NativeVolUpMirror(
      onLongPress: () => modeCtrl.toggleMode(),
      onDoublePress: () => modeCtrl.requestOcrReread(),
      onAdjustVolume: () => volumes++,
    );
    modeCtrl = ModeTransitionController(
      initialCurrencyMode: false,
      onTriggerRereadOcr: (_) => rereads++,
    );
    native.isOcrModeActive = true;

    // 1. First short press does not immediately trigger OCR or volume
    native.onKeyDown();
    native.onKeyUp();
    expect(rereads, 0);
    expect(volumes, 0);

    // 3. After 450ms window, normal volume adjustment happens once
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(rereads, 0);
    expect(volumes, 1);

    // 2 & 4. Two short presses within 450ms trigger 1 reread and 0 volume changes
    native.onKeyDown();
    native.onKeyUp();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    native.onKeyDown();
    native.onKeyUp();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(rereads, 1);
    expect(volumes, 1); // unchanged!
    expect(modeCtrl.isCurrencyMode, isFalse);

    native.dispose();
    modeCtrl.dispose();
  });

  test('5-6: 2-second Volume Up hold switches OCR back to Currency and never counts as double press', () async {
    int rereads = 0;
    int stopOcrCalls = 0;
    int volumes = 0;
    late ModeTransitionController modeCtrl;
    final native = NativeVolUpMirror(
      onLongPress: () {
        modeCtrl.toggleMode();
        nativeIsOcrSync(modeCtrl);
      },
      onDoublePress: () => modeCtrl.requestOcrReread(),
      onAdjustVolume: () => volumes++,
    );
    modeCtrl = ModeTransitionController(
      initialCurrencyMode: false,
      onTriggerRereadOcr: (_) => rereads++,
      onStopOcr: (_) => stopOcrCalls++,
    );
    native.isOcrModeActive = true;

    // Hold for > 2000ms
    native.onKeyDown();
    await Future<void>.delayed(const Duration(milliseconds: 2050));
    native.onKeyUp();

    expect(modeCtrl.isCurrencyMode, isTrue);
    expect(stopOcrCalls, 1);
    expect(rereads, 0);
    expect(volumes, 0);

    native.dispose();
    modeCtrl.dispose();
  });

  test('7: Repeated Android key-down events do not trigger duplicate captures', () async {
    int rereads = 0;
    int volumes = 0;
    late ModeTransitionController modeCtrl;
    final native = NativeVolUpMirror(
      onLongPress: () => modeCtrl.toggleMode(),
      onDoublePress: () => modeCtrl.requestOcrReread(),
      onAdjustVolume: () => volumes++,
    );
    modeCtrl = ModeTransitionController(
      initialCurrencyMode: false,
      onTriggerRereadOcr: (_) => rereads++,
    );
    native.isOcrModeActive = true;

    native.onKeyDown(repeatCount: 0);
    native.onKeyDown(repeatCount: 1);
    native.onKeyDown(repeatCount: 2);
    native.onKeyUp();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(rereads, 0);
    expect(volumes, 1);

    native.dispose();
    modeCtrl.dispose();
  });

  test('8-11: Double press during recognition/speech invalidates older gen, interrupts speech, keeps OCR mode & currency paused', () async {
    final spoken = <String>[];
    final cancelledGens = <int>[];
    final triggeredGens = <int>[];
    late ModeTransitionController modeCtrl;

    Future<void> runSimulatedOcr(int gen, String label) async {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      if (!modeCtrl.isOcrGenerationValid(gen)) {
        cancelledGens.add(gen);
        return;
      }
      // Simulate speech start
      spoken.add('start:$gen:$label');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (!modeCtrl.isOcrGenerationValid(gen)) {
        cancelledGens.add(gen);
        return;
      }
      spoken.add('end:$gen:$label');
    }

    modeCtrl = ModeTransitionController(
      initialCurrencyMode: true,
      onTriggerAutoOcr: (gen) {
        triggeredGens.add(gen);
        unawaited(runSimulatedOcr(gen, 'entry'));
      },
      onTriggerRereadOcr: (gen) {
        triggeredGens.add(gen);
        unawaited(runSimulatedOcr(gen, 'reread'));
      },
    );

    // Enter OCR mode (gen 1)
    final gen1 = modeCtrl.setMode(false)!;
    expect(modeCtrl.isCurrencyMode, isFalse);
    // Currency inference must remain paused throughout OCR mode
    bool currencyInferenceAllowed() => modeCtrl.isCurrencyMode;
    expect(currencyInferenceAllowed(), isFalse);

    // Double press during gen 1 recognition -> invalidates gen 1 immediately
    await Future<void>.delayed(const Duration(milliseconds: 15));
    final gen2 = modeCtrl.requestOcrReread()!;
    expect(modeCtrl.isOcrGenerationValid(gen1), isFalse);
    expect(modeCtrl.isOcrGenerationValid(gen2), isTrue);
    expect(currencyInferenceAllowed(), isFalse);

    // Wait for gen 2 to start speaking, then double-press again during speech (gen 3)
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final gen3 = modeCtrl.requestOcrReread()!;
    expect(modeCtrl.isOcrGenerationValid(gen2), isFalse);
    expect(modeCtrl.isOcrGenerationValid(gen3), isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 160));
    expect(triggeredGens, [gen1, gen2, gen3]);
    expect(cancelledGens, containsAll([gen1, gen2]));
    expect(spoken, contains('end:$gen3:reread'));
    expect(spoken, isNot(contains('end:$gen1:entry')));
    expect(spoken, isNot(contains('end:$gen2:reread')));
    expect(modeCtrl.isCurrencyMode, isFalse);
    expect(currencyInferenceAllowed(), isFalse);

    modeCtrl.dispose();
  });
}

void nativeIsOcrSync(ModeTransitionController _) {}
