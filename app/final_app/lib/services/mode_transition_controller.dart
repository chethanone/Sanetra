import 'dart:async';

/// Pure coordinator for Phase 5.10:
/// - Language selector 4-second single-timer inactivity auto-close.
/// - Two-state Currency <-> OCR mode toggle with one-shot automatic OCR
///   capture on Currency -> OCR entry and generation-guarded cancellation
///   on OCR -> Currency return.
class ModeTransitionController {
  ModeTransitionController({
    this.selectorInactivityTimeout = const Duration(seconds: 4),
    bool initialCurrencyMode = true,
    this.onSelectorTimeout,
    this.onTriggerAutoOcr,
    this.onTriggerRereadOcr,
    this.onStopOcr,
  }) : _isCurrencyMode = initialCurrencyMode;

  final Duration selectorInactivityTimeout;
  final void Function()? onSelectorTimeout;
  final void Function(int modeGenerationId)? onTriggerAutoOcr;
  final void Function(int modeGenerationId)? onTriggerRereadOcr;
  final void Function(int modeGenerationId)? onStopOcr;

  bool _isCurrencyMode;
  int _modeGenerationId = 0;
  int _lastAutoOcrGenerationId = -1;
  bool _isSelectorOpen = false;
  Timer? _selectorTimer;
  DateTime? _selectorOpenedAt;
  DateTime? _selectorClosedAt;

  bool get isCurrencyMode => _isCurrencyMode;
  int get modeGenerationId => _modeGenerationId;
  bool get isSelectorOpen => _isSelectorOpen;
  DateTime? get selectorOpenedAt => _selectorOpenedAt;
  DateTime? get selectorClosedAt => _selectorClosedAt;

  /// Open the language selector and start the single 4-second inactivity timer.
  void openSelector() {
    if (_isSelectorOpen) {
      resetSelectorTimer();
      return;
    }
    _isSelectorOpen = true;
    _selectorOpenedAt = DateTime.now();
    _selectorClosedAt = null;
    resetSelectorTimer();
  }

  /// Reset the single inactivity timer on every navigation press.
  void resetSelectorTimer() {
    _selectorTimer?.cancel();
    if (!_isSelectorOpen) return;
    _selectorTimer = Timer(selectorInactivityTimeout, () {
      if (!_isSelectorOpen) return;
      _isSelectorOpen = false;
      _selectorClosedAt = DateTime.now();
      _selectorTimer = null;
      onSelectorTimeout?.call();
    });
  }

  /// Explicitly close the language selector (e.g. 2s Volume Down hold).
  void closeSelector() {
    _selectorTimer?.cancel();
    _selectorTimer = null;
    if (!_isSelectorOpen) return;
    _isSelectorOpen = false;
    _selectorClosedAt = DateTime.now();
  }

  /// Switch between Currency (`true`) and OCR (`false`) mode.
  /// Returns the new [modeGenerationId] if the mode changed, or `null` if
  /// already in that mode (preventing duplicate OCR triggers).
  int? setMode(bool isCurrency, {bool autoTriggerOcr = true}) {
    if (_isCurrencyMode == isCurrency) {
      return null;
    }
    _isCurrencyMode = isCurrency;
    final gen = ++_modeGenerationId;
    if (!isCurrency) {
      if (autoTriggerOcr && _lastAutoOcrGenerationId != gen) {
        _lastAutoOcrGenerationId = gen;
        onTriggerAutoOcr?.call(gen);
      }
    } else {
      onStopOcr?.call(gen);
    }
    return gen;
  }

  /// Toggle Currency <-> OCR (used by 2-second Volume Up hold outside popup).
  int? toggleMode({bool autoTriggerOcr = true}) =>
      setMode(!_isCurrencyMode, autoTriggerOcr: autoTriggerOcr);

  /// Request a fresh OCR reread while already in OCR mode (Phase 5.12 double
  /// Volume Up). Increments [modeGenerationId] to invalidate any in-flight
  /// recognition or speech, and returns the new generation ID (or `null` if not
  /// in OCR mode).
  int? requestOcrReread() {
    if (_isCurrencyMode) {
      return null;
    }
    final gen = ++_modeGenerationId;
    (onTriggerRereadOcr ?? onTriggerAutoOcr)?.call(gen);
    return gen;
  }

  /// Whether an async OCR result/speech belonging to [captureGen] is still valid.
  bool isOcrGenerationValid(int captureGen) =>
      !_isCurrencyMode && captureGen == _modeGenerationId;

  void dispose() {
    _selectorTimer?.cancel();
    _selectorTimer = null;
  }
}
