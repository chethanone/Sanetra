import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vision_assistant/services/auto_flashlight_controller.dart';

void main() {
  group('Phase 5.14 AutoFlashlightController', () {
    test('Default configuration matches tuned low-light thresholds', () {
      const cfg = AutoFlashlightConfig();
      expect(cfg.lightOnThresholdLux, 3.0);
      expect(cfg.lightOffThresholdLux, 25.0);
      expect(cfg.lowLightConfirmation, const Duration(milliseconds: 2000));
      expect(cfg.brightLightConfirmation, const Duration(milliseconds: 2500));
      expect(cfg.minimumStateHold, const Duration(milliseconds: 6000));
    });

    test('Voice phrases match English, Kannada, and Hindi specifications', () {
      expect(
        AutoFlashlightPhrases.phraseFor(enabled: true, languageCode: 'en-IN'),
        'Flashlight on.',
      );
      expect(
        AutoFlashlightPhrases.phraseFor(enabled: false, languageCode: 'en-IN'),
        'Flashlight off.',
      );
      expect(
        AutoFlashlightPhrases.phraseFor(enabled: true, languageCode: 'kn-IN'),
        'ಫ್ಲ್ಯಾಶ್ಲೈಟ್ ಆನ್ ಆಗಿದೆ.',
      );
      expect(
        AutoFlashlightPhrases.phraseFor(enabled: false, languageCode: 'kn-IN'),
        'ಫ್ಲ್ಯಾಶ್ಲೈಟ್ ಆಫ್ ಆಗಿದೆ.',
      );
      expect(
        AutoFlashlightPhrases.phraseFor(enabled: true, languageCode: 'hi-IN'),
        'फ्लैशलाइट चालू है।',
      );
      expect(
        AutoFlashlightPhrases.phraseFor(enabled: false, languageCode: 'hi-IN'),
        'फ्लैशलाइट बंद है।',
      );
    });

    test('Dim readable room (8 lux) stays OFF; <3 lux for 2s turns ON and announces', () async {
      var now = DateTime(2026, 11, 16, 8, 0, 0);
      final torchCalls = <bool>[];
      final announcements = <(String, String)>[];
      final controllerStream = StreamController<double>.broadcast();

      final controller = AutoFlashlightController(
        onSetTorch: (enabled) async {
          torchCalls.add(enabled);
          return true;
        },
        onAnnounce: (text, {required language}) async {
          announcements.add((text, language));
        },
        getSpeechLanguage: () => 'en-IN',
        ambientLightStream: controllerStream.stream,
        checkLightSensorAvailable: () async => true,
        checkTorchAvailable: () async => true,
        checkExternalTorchOn: () async => false,
        now: () => now,
      );

      await controller.startMonitoring(RecognitionTorchMode.currency);
      for (var i = 0; i < 5; i++) {
        controller.processLuxReading(8.5);
      }
      now = now.add(const Duration(seconds: 5));
      controller.processLuxReading(8.5);
      await Future<void>.delayed(Duration.zero);
      expect(torchCalls, isEmpty);
      expect(controller.controllerOwnsTorch, isFalse);

      // Enter pitch-dark environment (< 3.0 lux)
      for (var i = 0; i < 5; i++) {
        controller.processLuxReading(1.5);
      }
      await Future<void>.delayed(Duration.zero);
      expect(torchCalls, isEmpty); // Not yet 2000ms

      now = now.add(const Duration(milliseconds: 2000));
      controller.processLuxReading(1.5);
      await Future<void>.delayed(Duration.zero);
      expect(torchCalls, [true]);
      expect(controller.controllerOwnsTorch, isTrue);
      expect(announcements, [('Flashlight on.', 'en-IN')]);

      await controller.dispose();
      await controllerStream.close();
    });

    test('Reflection right after torch ON does NOT self-trigger OFF; genuine bright light turns OFF', () async {
      var now = DateTime(2026, 11, 16, 8, 0, 0);
      final torchCalls = <bool>[];
      final announcements = <(String, String)>[];
      final controllerStream = StreamController<double>.broadcast();

      final controller = AutoFlashlightController(
        onSetTorch: (enabled) async {
          torchCalls.add(enabled);
          return true;
        },
        onAnnounce: (text, {required language}) async {
          announcements.add((text, language));
        },
        getSpeechLanguage: () => 'kn-IN',
        ambientLightStream: controllerStream.stream,
        checkLightSensorAvailable: () async => true,
        checkTorchAvailable: () async => true,
        checkExternalTorchOn: () async => false,
        now: () => now,
      );

      await controller.startMonitoring(RecognitionTorchMode.ocr);

      // Sustained pitch dark -> ON
      for (var i = 0; i < 5; i++) {
        controller.processLuxReading(1.0);
      }
      now = now.add(const Duration(milliseconds: 2100));
      controller.processLuxReading(1.0);
      await Future<void>.delayed(Duration.zero);
      expect(torchCalls, [true]);
      expect(announcements.last, ('ಫ್ಲ್ಯಾಶ್ಲೈಟ್ ಆನ್ ಆಗಿದೆ.', 'kn-IN'));

      // Reflected torch light jumps to 78 lux within 1000ms -> calibrates reflection baseline
      now = now.add(const Duration(milliseconds: 800));
      for (var i = 0; i < 5; i++) {
        controller.processLuxReading(78.0);
      }
      now = now.add(const Duration(seconds: 10));
      controller.processLuxReading(78.0);
      await Future<void>.delayed(Duration.zero);
      // Must stay ON because 78 lux is within reflection baseline + headroom (103 lux)
      expect(torchCalls, [true]);
      expect(controller.controllerOwnsTorch, isTrue);

      // Genuine bright room / sunlight (> 103 lux) sustained for 2.5s -> OFF
      for (var i = 0; i < 5; i++) {
        controller.processLuxReading(140.0);
      }
      now = now.add(const Duration(milliseconds: 2500));
      controller.processLuxReading(140.0);
      await Future<void>.delayed(Duration.zero);
      expect(torchCalls, [true, false]);
      expect(controller.controllerOwnsTorch, isFalse);
      expect(announcements.last, ('ಫ್ಲ್ಯಾಶ್ಲೈಟ್ ಆಫ್ ಆಗಿದೆ.', 'kn-IN'));

      await controller.dispose();
      await controllerStream.close();
    });

    test('Mode transition preserves shared monitor and torch state; external torch is never turned off', () async {
      var now = DateTime(2026, 11, 16, 8, 0, 0);
      final torchCalls = <bool>[];
      final announcements = <(String, String)>[];
      final controllerStream = StreamController<double>.broadcast();

      final shared = AutoFlashlightController(
        onSetTorch: (enabled) async {
          torchCalls.add(enabled);
          return true;
        },
        onAnnounce: (text, {required language}) async {
          announcements.add((text, language));
        },
        getSpeechLanguage: () => 'hi-IN',
        ambientLightStream: controllerStream.stream,
        checkLightSensorAvailable: () async => true,
        checkTorchAvailable: () async => true,
        checkExternalTorchOn: () async => false,
        now: () => now,
      );

      await shared.startMonitoring(RecognitionTorchMode.currency);
      for (var i = 0; i < 5; i++) {
        shared.processLuxReading(1.0);
      }
      now = now.add(const Duration(milliseconds: 2100));
      shared.processLuxReading(1.0);
      await Future<void>.delayed(Duration.zero);
      expect(torchCalls, [true]);

      // Switch to OCR mode: must NOT toggle torch off/on
      await shared.startMonitoring(RecognitionTorchMode.ocr);
      expect(shared.activeMode, RecognitionTorchMode.ocr);
      expect(shared.controllerOwnsTorch, isTrue);
      expect(torchCalls, [true]);

      // Stop monitoring on lifecycle pause -> safely switches owned torch OFF
      await shared.stopMonitoring(turnOffIfOwned: true, announce: true);
      expect(torchCalls, [true, false]);
      expect(announcements.last, ('फ्लैशलाइट बंद है।', 'hi-IN'));

      // External torch already ON -> controller protects it
      final externalProtected = AutoFlashlightController(
        onSetTorch: (enabled) async {
          torchCalls.add(enabled);
          return true;
        },
        onAnnounce: (text, {required language}) async {},
        getSpeechLanguage: () => 'en-IN',
        ambientLightStream: controllerStream.stream,
        checkLightSensorAvailable: () async => true,
        checkTorchAvailable: () async => true,
        checkExternalTorchOn: () async => true,
        now: () => now,
      );
      await externalProtected.startMonitoring(RecognitionTorchMode.currency);
      expect(externalProtected.externalTorchProtected, isTrue);
      for (var i = 0; i < 5; i++) {
        externalProtected.processLuxReading(150.0);
      }
      now = now.add(const Duration(seconds: 10));
      externalProtected.processLuxReading(150.0);
      await Future<void>.delayed(Duration.zero);
      expect(torchCalls, [true, false]); // unchanged

      await externalProtected.dispose();
      await controllerStream.close();
    });

    test('Missing sensor and failed torch operations are handled without announcements', () async {
      var now = DateTime(2026, 11, 16, 8, 0, 0);
      final announcements = <String>[];
      final controllerStream = StreamController<double>.broadcast();

      final missingSensor = AutoFlashlightController(
        onSetTorch: (_) async => true,
        onAnnounce: (text, {required language}) async => announcements.add(text),
        getSpeechLanguage: () => 'en-IN',
        ambientLightStream: controllerStream.stream,
        checkLightSensorAvailable: () async => false,
        checkTorchAvailable: () async => true,
        checkExternalTorchOn: () async => false,
        now: () => now,
      );
      await missingSensor.startMonitoring(RecognitionTorchMode.currency);
      expect(missingSensor.isMonitoring, isFalse);
      expect(missingSensor.isSensorAvailable, isFalse);

      final failingTorch = AutoFlashlightController(
        onSetTorch: (_) async => false,
        onAnnounce: (text, {required language}) async => announcements.add(text),
        getSpeechLanguage: () => 'en-IN',
        ambientLightStream: controllerStream.stream,
        checkLightSensorAvailable: () async => true,
        checkTorchAvailable: () async => true,
        checkExternalTorchOn: () async => false,
        now: () => now,
      );
      await failingTorch.startMonitoring(RecognitionTorchMode.currency);
      for (var i = 0; i < 5; i++) {
        failingTorch.processLuxReading(1.0);
      }
      now = now.add(const Duration(milliseconds: 2100));
      failingTorch.processLuxReading(1.0);
      await Future<void>.delayed(Duration.zero);

      expect(failingTorch.controllerOwnsTorch, isFalse);
      expect(announcements, isEmpty);

      await missingSensor.dispose();
      await failingTorch.dispose();
      await controllerStream.close();
    });
  });
}
