import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum RecognitionTorchMode { currency, ocr }

/// Centralized threshold and timing configuration for automatic flashlight control.
class AutoFlashlightConfig {
  const AutoFlashlightConfig({
    this.lightOnThresholdLux = 3.0,
    this.lightOffThresholdLux = 25.0,
    this.lowLightConfirmation = const Duration(milliseconds: 2000),
    this.brightLightConfirmation = const Duration(milliseconds: 2500),
    this.minimumStateHold = const Duration(milliseconds: 6000),
    this.medianWindowSize = 5,
    this.failureCooldown = const Duration(seconds: 5),
    this.reflectionCalibrationWindow = const Duration(milliseconds: 1500),
    this.reflectionHeadroomLux = 25.0,
    this.maxReflectionBaselineLux = 120.0,
  });

  final double lightOnThresholdLux;
  final double lightOffThresholdLux;
  final Duration lowLightConfirmation;
  final Duration brightLightConfirmation;
  final Duration minimumStateHold;
  final int medianWindowSize;
  final Duration failureCooldown;
  final Duration reflectionCalibrationWindow;
  final double reflectionHeadroomLux;
  final double maxReflectionBaselineLux;
}

class AutoFlashlightPhrases {
  static String phraseFor({
    required bool enabled,
    required String languageCode,
  }) {
    if (enabled) {
      switch (languageCode) {
        case 'kn-IN':
          return 'ಫ್ಲ್ಯಾಶ್ಲೈಟ್ ಆನ್ ಆಗಿದೆ.';
        case 'hi-IN':
          return 'फ्लैशलाइट चालू है।';
        case 'ceb-PH':
          return 'Naka-on ang flashlight.';
        default:
          return 'Flashlight on.';
      }
    } else {
      switch (languageCode) {
        case 'kn-IN':
          return 'ಫ್ಲ್ಯಾಶ್ಲೈಟ್ ಆಫ್ ಆಗಿದೆ.';
        case 'hi-IN':
          return 'फ्लैशलाइट बंद है।';
        case 'ceb-PH':
          return 'Naka-off ang flashlight.';
        default:
          return 'Flashlight off.';
      }
    }
  }

  /// Explicit Bisaya clip IDs for flashlight ON/OFF so Bisaya announcements
  /// never fall back to `confirm_bisaya`.
  static List<String>? clipsFor({
    required bool enabled,
    required String languageCode,
  }) {
    if (languageCode != 'ceb-PH') return null;
    return [enabled ? 'flashlight_on' : 'flashlight_off'];
  }
}

typedef TorchSetCallback = Future<bool> Function(bool enabled);
typedef TorchAnnounceCallback =
    Future<void> Function(String text, {required String language});
typedef TorchAnnounceWithClipsCallback =
    Future<void> Function(
      String text, {
      required String language,
      List<String>? bisayaClips,
    });

/// Shared automatic ambient-light flashlight controller for Currency and OCR modes.
class AutoFlashlightController {
  AutoFlashlightController({
    this.config = const AutoFlashlightConfig(),
    required this.onSetTorch,
    required this.onAnnounce,
    this.onAnnounceWithClips,
    required this.getSpeechLanguage,
    this.onTorchStateChanged,
    Stream<double>? ambientLightStream,
    Future<bool> Function()? checkLightSensorAvailable,
    Future<bool> Function()? checkTorchAvailable,
    Future<bool> Function()? checkExternalTorchOn,
    DateTime Function()? now,
  }) : _ambientLightStream = ambientLightStream ?? _defaultAmbientLightStream(),
       _checkLightSensorAvailable =
           checkLightSensorAvailable ?? _defaultCheckLightSensorAvailable,
       _checkTorchAvailable =
           checkTorchAvailable ?? _defaultCheckTorchAvailable,
       _checkExternalTorchOn =
           checkExternalTorchOn ?? _defaultCheckExternalTorchOn,
       _now = now ?? DateTime.now;

  static const MethodChannel _methodChannel = MethodChannel(
    'vision_assistant/flashlight_sensor',
  );
  static const EventChannel _eventChannel = EventChannel(
    'vision_assistant/ambient_light',
  );

  static Stream<double> _defaultAmbientLightStream() {
    return _eventChannel.receiveBroadcastStream().map((event) {
      if (event is Map) {
        final raw = event['lux'];
        if (raw is num) return raw.toDouble();
      } else if (event is num) {
        return event.toDouble();
      }
      return double.nan;
    });
  }

  static Future<bool> _defaultCheckLightSensorAvailable() async {
    try {
      final info = await _methodChannel.invokeMapMethod<String, dynamic>(
        'getLightSensorInfo',
      );
      return info?['available'] == true;
    } catch (e) {
      debugPrint('[AUTO-FLASH] getLightSensorInfo error: $e');
      return false;
    }
  }

  static Future<bool> _defaultCheckTorchAvailable() async {
    try {
      final available = await _methodChannel.invokeMethod<bool>(
        'isTorchAvailable',
      );
      return available == true;
    } catch (e) {
      debugPrint('[AUTO-FLASH] isTorchAvailable error: $e');
      return false;
    }
  }

  static Future<bool> _defaultCheckExternalTorchOn() async {
    try {
      final status = await _methodChannel.invokeMapMethod<String, dynamic>(
        'getTorchStatus',
      );
      return status?['torchEnabled'] == true;
    } catch (e) {
      debugPrint('[AUTO-FLASH] getTorchStatus error: $e');
      return false;
    }
  }

  final AutoFlashlightConfig config;
  final TorchSetCallback onSetTorch;
  final TorchAnnounceCallback onAnnounce;
  final TorchAnnounceWithClipsCallback? onAnnounceWithClips;
  final String Function() getSpeechLanguage;
  final void Function(bool enabled)? onTorchStateChanged;
  final Stream<double> _ambientLightStream;
  final Future<bool> Function() _checkLightSensorAvailable;
  final Future<bool> Function() _checkTorchAvailable;
  final Future<bool> Function() _checkExternalTorchOn;
  final DateTime Function() _now;

  final List<double> _luxWindow = <double>[];
  StreamSubscription<double>? _sensorSub;
  Timer? _confirmationTimer;

  bool _isMonitoring = false;
  bool _isDisposed = false;
  RecognitionTorchMode _activeMode = RecognitionTorchMode.currency;
  bool _sensorAvailable = true;
  bool _torchAvailable = true;

  bool _controllerOwnsTorch = false;
  bool _manualTorchOverride = false;
  bool _externalTorchProtected = false;
  bool _transitionInFlight = false;

  DateTime? _lowLightSince;
  DateTime? _brightLightSince;
  DateTime? _lastTransitionAt;
  DateTime? _lastFailureAt;
  DateTime? _torchTurnedOnAt;
  double _postTorchReflectionLux = 0.0;
  double? _lastRawLux;
  double? _lastFilteredLux;

  bool get isMonitoring => _isMonitoring;
  RecognitionTorchMode get activeMode => _activeMode;
  bool get controllerOwnsTorch => _controllerOwnsTorch;
  bool get manualTorchOverride => _manualTorchOverride;
  bool get externalTorchProtected => _externalTorchProtected;
  bool get isSensorAvailable => _sensorAvailable;
  bool get isTorchAvailable => _torchAvailable;
  double? get lastRawLux => _lastRawLux;
  double? get lastFilteredLux => _lastFilteredLux;
  double get effectiveOffThresholdLux {
    if (_postTorchReflectionLux <= config.lightOnThresholdLux) {
      return config.lightOffThresholdLux;
    }
    final reflected = (_postTorchReflectionLux + config.reflectionHeadroomLux)
        .clamp(config.lightOffThresholdLux, config.maxReflectionBaselineLux);
    return reflected;
  }

  /// Start or continue ambient-light monitoring for [mode].
  /// Switching between Currency and OCR keeps the same controller and torch state.
  Future<void> startMonitoring(RecognitionTorchMode mode) async {
    if (_isDisposed) return;
    _activeMode = mode;

    if (_isMonitoring) {
      debugPrint(
        '[AUTO-FLASH] Mode switched to ${mode.name}; keeping active monitor '
        '(ownsTorch=$_controllerOwnsTorch, filteredLux=$_lastFilteredLux)',
      );
      return;
    }

    _isMonitoring = true;
    _luxWindow.clear();
    _lowLightSince = null;
    _brightLightSince = null;
    _cancelConfirmationTimer();

    _sensorAvailable = await _checkLightSensorAvailable();
    _torchAvailable = await _checkTorchAvailable();
    if (!_isMonitoring || _isDisposed) return;

    if (!_sensorAvailable) {
      debugPrint('[AUTO-FLASH] Ambient light sensor unavailable; monitoring disabled.');
      _isMonitoring = false;
      return;
    }
    if (!_torchAvailable) {
      debugPrint('[AUTO-FLASH] Camera torch unavailable; monitoring disabled.');
      _isMonitoring = false;
      return;
    }

    final externalOn = await _checkExternalTorchOn();
    if (!_isMonitoring || _isDisposed) return;
    if (externalOn && !_controllerOwnsTorch) {
      _externalTorchProtected = true;
      debugPrint('[AUTO-FLASH] External torch already ON; preserving external ownership.');
    } else {
      _externalTorchProtected = false;
    }

    _sensorSub = _ambientLightStream.listen(
      _onLuxSample,
      onError: (Object error) {
        debugPrint('[AUTO-FLASH] Sensor stream error: $error');
      },
    );
    debugPrint('[AUTO-FLASH] Started monitoring in ${mode.name} mode.');
  }

  /// Update manual torch override when the user taps the manual torch button.
  void setManualTorchState(bool enabled) {
    _cancelConfirmationTimer();
    _lowLightSince = null;
    _brightLightSince = null;
    if (enabled) {
      _manualTorchOverride = true;
      _controllerOwnsTorch = false;
      debugPrint('[AUTO-FLASH] Manual torch ON; auto-off suspended.');
    } else {
      _manualTorchOverride = false;
      _controllerOwnsTorch = false;
      _externalTorchProtected = false;
      _lastTransitionAt = _now();
      debugPrint('[AUTO-FLASH] Manual torch OFF; auto control resumed.');
    }
  }

  /// Stop ambient-light monitoring. If [turnOffIfOwned] is true and this
  /// controller owns an enabled flashlight, turn it OFF safely.
  Future<void> stopMonitoring({
    bool turnOffIfOwned = true,
    bool announce = true,
  }) async {
    _isMonitoring = false;
    _cancelConfirmationTimer();
    _lowLightSince = null;
    _brightLightSince = null;
    _luxWindow.clear();

    await _sensorSub?.cancel();
    _sensorSub = null;

    if (turnOffIfOwned && _controllerOwnsTorch) {
      await _applyTorchTransition(targetEnabled: false, announce: announce);
    }
    debugPrint('[AUTO-FLASH] Stopped monitoring.');
  }

  /// Feed a lux sample (used by the sensor stream and unit tests).
  @visibleForTesting
  void processLuxReading(double rawLux) {
    _onLuxSample(rawLux);
  }

  void _onLuxSample(double rawLux) {
    if (!_isMonitoring || _isDisposed) return;
    if (!rawLux.isFinite || rawLux < 0) return;

    _lastRawLux = rawLux;
    _luxWindow.add(rawLux);
    if (_luxWindow.length > config.medianWindowSize) {
      _luxWindow.removeAt(0);
    }
    final filtered = _computeMedian(_luxWindow);
    _lastFilteredLux = filtered;

    _evaluateLighting(filtered);
  }

  void _evaluateLighting(double filteredLux) {
    if (!_isMonitoring || _isDisposed) return;
    if (_manualTorchOverride || _externalTorchProtected) return;

    final currentTime = _now();

    if (!_controllerOwnsTorch) {
      _brightLightSince = null;
      if (filteredLux < config.lightOnThresholdLux) {
        _lowLightSince ??= currentTime;
        _scheduleOrTrigger(
          since: _lowLightSince!,
          confirmation: config.lowLightConfirmation,
          targetEnabled: true,
          currentTime: currentTime,
        );
      } else {
        _lowLightSince = null;
        _cancelConfirmationTimer();
      }
    } else {
      _lowLightSince = null;
      if (_torchTurnedOnAt != null &&
          currentTime.difference(_torchTurnedOnAt!) <=
              config.reflectionCalibrationWindow) {
        if (filteredLux > _postTorchReflectionLux) {
          _postTorchReflectionLux = filteredLux;
        }
      }
      final offThreshold = effectiveOffThresholdLux;
      if (filteredLux > offThreshold) {
        _brightLightSince ??= currentTime;
        _scheduleOrTrigger(
          since: _brightLightSince!,
          confirmation: config.brightLightConfirmation,
          targetEnabled: false,
          currentTime: currentTime,
        );
      } else {
        _brightLightSince = null;
        _cancelConfirmationTimer();
      }
    }
  }

  void _scheduleOrTrigger({
    required DateTime since,
    required Duration confirmation,
    required bool targetEnabled,
    required DateTime currentTime,
  }) {
    final confirmRemaining = confirmation - currentTime.difference(since);
    final holdRemaining = _lastTransitionAt == null
        ? Duration.zero
        : config.minimumStateHold - currentTime.difference(_lastTransitionAt!);
    final cooldownRemaining = _lastFailureAt == null
        ? Duration.zero
        : config.failureCooldown - currentTime.difference(_lastFailureAt!);

    var waitDuration = confirmRemaining;
    if (holdRemaining > waitDuration) waitDuration = holdRemaining;
    if (cooldownRemaining > waitDuration) waitDuration = cooldownRemaining;

    if (waitDuration <= Duration.zero) {
      _cancelConfirmationTimer();
      unawaited(_applyTorchTransition(targetEnabled: targetEnabled, announce: true));
      return;
    }

    if (_confirmationTimer?.isActive == true) {
      return;
    }

    _confirmationTimer = Timer(waitDuration, () {
      _confirmationTimer = null;
      if (!_isMonitoring || _isDisposed) return;
      final latestLux = _lastFilteredLux;
      if (latestLux == null) return;
      _evaluateLighting(latestLux);
    });
  }

  Future<void> _applyTorchTransition({
    required bool targetEnabled,
    required bool announce,
  }) async {
    if (_isDisposed || _transitionInFlight) return;
    if (_controllerOwnsTorch == targetEnabled) return;
    if (targetEnabled && (_manualTorchOverride || _externalTorchProtected)) {
      return;
    }

    _transitionInFlight = true;
    try {
      final success = await onSetTorch(targetEnabled);
      if (!success) {
        _lastFailureAt = _now();
        debugPrint(
          '[AUTO-FLASH] Torch transition to $targetEnabled failed; '
          'cooldown ${config.failureCooldown.inMilliseconds}ms.',
        );
        return;
      }

      _controllerOwnsTorch = targetEnabled;
      _lastTransitionAt = _now();
      if (targetEnabled) {
        _torchTurnedOnAt = _lastTransitionAt;
        _postTorchReflectionLux = 0.0;
      } else {
        _torchTurnedOnAt = null;
        _postTorchReflectionLux = 0.0;
      }
      _lowLightSince = null;
      _brightLightSince = null;
      onTorchStateChanged?.call(targetEnabled);

      debugPrint(
        '[AUTO-FLASH] Torch ${targetEnabled ? "ON" : "OFF"} '
        '(mode=${_activeMode.name}, filteredLux=$_lastFilteredLux)',
      );

      if (announce) {
        final lang = getSpeechLanguage();
        final phrase = AutoFlashlightPhrases.phraseFor(
          enabled: targetEnabled,
          languageCode: lang,
        );
        final clips = AutoFlashlightPhrases.clipsFor(
          enabled: targetEnabled,
          languageCode: lang,
        );
        if (onAnnounceWithClips != null) {
          await onAnnounceWithClips!(
            phrase,
            language: lang,
            bisayaClips: clips,
          );
        } else {
          await onAnnounce(phrase, language: lang);
        }
      }
    } catch (e) {
      _lastFailureAt = _now();
      debugPrint('[AUTO-FLASH] Torch transition exception: $e');
    } finally {
      _transitionInFlight = false;
    }
  }

  void _cancelConfirmationTimer() {
    _confirmationTimer?.cancel();
    _confirmationTimer = null;
  }

  static double _computeMedian(List<double> values) {
    final sorted = List<double>.from(values)..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  Future<void> dispose() async {
    _isDisposed = true;
    await stopMonitoring(turnOffIfOwned: true, announce: false);
  }
}
