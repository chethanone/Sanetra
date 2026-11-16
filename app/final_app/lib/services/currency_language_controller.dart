import 'dart:async';

/// Represents a selectable currency voice language in the selector popup.
class CurrencyLanguageOption {
  const CurrencyLanguageOption({
    required this.code,
    required this.label,
    required this.spokenConfirm,
  });

  final String code;
  final String label;
  final String spokenConfirm;
}

/// Visual order of currency languages: 1. English, 2. Kannada, 3. Hindi.
const List<CurrencyLanguageOption> kCurrencyLanguages = [
  CurrencyLanguageOption(
    code: 'en-IN',
    label: 'English',
    spokenConfirm: 'English',
  ),
  CurrencyLanguageOption(
    code: 'kn-IN',
    label: 'ಕನ್ನಡ',
    spokenConfirm: 'ಕನ್ನಡ',
  ),
  CurrencyLanguageOption(
    code: 'hi-IN',
    label: 'हिन्दी',
    spokenConfirm: 'हिन्दी',
  ),
];

/// Callback signature for speaking a language announcement with interrupt support.
typedef LanguageSpeakCallback = Future<void> Function(
  String text, {
  required String language,
  required bool interrupt,
});

/// Callback signature for immediate preemptive selector announcements with
/// generation/token tracking and key-to-speech latency instrumentation.
typedef PreemptLanguageSpeakCallback = Future<void> Function(
  String text, {
  required String language,
  required int generationId,
  int keyAgeMs,
  int? stateUpdateOffsetMs,
});

/// Callback signature for cancelling any active/outdated language announcement.
typedef LanguageStopCallback = Future<void> Function();

/// Manages currency language selection, Volume Up/Down navigation direction,
/// and immediate epoch-guarded spoken announcements without debounce.
class CurrencyLanguageController {
  CurrencyLanguageController({
    String initialLanguage = 'en-IN',
    this._onSpeak,
    this._onPreemptSpeak,
    this._onStopSpeech,
    this._onPreferenceChanged,
  }) : _selectedCode = isValidCode(initialLanguage) ? initialLanguage : 'en-IN';

  String _selectedCode;
  int _announcementEpoch = 0;
  final LanguageSpeakCallback? _onSpeak;
  final PreemptLanguageSpeakCallback? _onPreemptSpeak;
  final LanguageStopCallback? _onStopSpeech;
  final void Function(String code)? _onPreferenceChanged;

  String get selectedCode => _selectedCode;
  int get announcementGenerationId => _announcementEpoch;

  CurrencyLanguageOption get selectedOption => kCurrencyLanguages.firstWhere(
        (l) => l.code == _selectedCode,
        orElse: () => kCurrencyLanguages.first,
      );

  static bool isValidCode(String code) =>
      kCurrencyLanguages.any((l) => l.code == code);

  void setSelectedCode(String code) {
    if (!isValidCode(code)) return;
    _selectedCode = code;
  }

  /// Short Volume Up: navigate UP to the previous item (with wraparound).
  CurrencyLanguageOption navigateUp({bool isMuted = false, int keyAgeMs = 0}) =>
      _step(-1, isMuted: isMuted, keyAgeMs: keyAgeMs);

  /// Short Volume Down: navigate DOWN to the next item (with wraparound).
  CurrencyLanguageOption navigateDown({bool isMuted = false, int keyAgeMs = 0}) =>
      _step(1, isMuted: isMuted, keyAgeMs: keyAgeMs);

  CurrencyLanguageOption _step(
    int delta, {
    bool isMuted = false,
    int keyAgeMs = 0,
  }) {
    final currentIdx =
        kCurrencyLanguages.indexWhere((l) => l.code == _selectedCode);
    final baseIdx = currentIdx < 0 ? 0 : currentIdx;
    final nextIdx =
        (baseIdx + delta + kCurrencyLanguages.length) % kCurrencyLanguages.length;
    final selected = kCurrencyLanguages[nextIdx];

    // 1. Update selected language preference immediately.
    _selectedCode = selected.code;
    _onPreferenceChanged?.call(selected.code);

    // 2. Cancel outdated announcement and speak the latest language immediately
    //    without any debounce timer.
    final epoch = ++_announcementEpoch;
    if (!isMuted) {
      final preempt = _onPreemptSpeak;
      if (preempt != null) {
        unawaited(
          preempt(
            selected.spokenConfirm,
            language: selected.code,
            generationId: epoch,
            keyAgeMs: keyAgeMs,
          ),
        );
      } else {
        unawaited(_announceEpoch(epoch, selected));
      }
    } else {
      final stop = _onStopSpeech;
      if (stop != null) {
        unawaited(stop());
      }
    }

    return selected;
  }

  Future<void> _announceEpoch(
    int epoch,
    CurrencyLanguageOption selected,
  ) async {
    final stop = _onStopSpeech;
    if (stop != null) {
      await stop();
    }
    if (epoch != _announcementEpoch) return;

    final speak = _onSpeak;
    if (speak != null) {
      await speak(
        selected.spokenConfirm,
        language: selected.code,
        interrupt: true,
      );
    }
  }
}

/// Pure state machine matching Android MainActivity's 2000 ms volume-key
/// long-press gesture rules for deterministic unit testing.
class VolumeGestureStateMachine {
  VolumeGestureStateMachine({
    this.longPressDuration = const Duration(milliseconds: 2000),
    this.onVolumeUpLongPress,
    this.onVolumeDownLongPress,
    this.onPopupVolumeUp,
    this.onPopupVolumeDown,
    this.onSystemVolumeUp,
    this.onSystemVolumeDown,
  });

  final Duration longPressDuration;
  final void Function()? onVolumeUpLongPress;
  final void Function()? onVolumeDownLongPress;
  final void Function()? onPopupVolumeUp;
  final void Function()? onPopupVolumeDown;
  final void Function()? onSystemVolumeUp;
  final void Function()? onSystemVolumeDown;

  bool isLanguagePopupOpen = false;

  bool _volUpPressed = false;
  bool _volUpLongTriggered = false;
  Timer? _volUpTimer;

  bool _volDownPressed = false;
  bool _volDownLongTriggered = false;
  Timer? _volDownTimer;

  void onVolumeUpDown({int repeatCount = 0}) {
    if (repeatCount > 0 || _volUpPressed) return;
    _volUpPressed = true;
    _volUpLongTriggered = false;
    if (isLanguagePopupOpen) {
      onPopupVolumeUp?.call();
    } else {
      _volUpTimer = Timer(longPressDuration, () {
        if (_volUpPressed && !_volUpLongTriggered && !isLanguagePopupOpen) {
          _volUpLongTriggered = true;
          onVolumeUpLongPress?.call();
        }
      });
    }
  }

  void onVolumeUpUp() {
    _volUpTimer?.cancel();
    _volUpTimer = null;
    final wasTriggered = _volUpLongTriggered;
    final wasPopup = isLanguagePopupOpen;
    _volUpPressed = false;
    _volUpLongTriggered = false;
    if (!wasTriggered && !wasPopup) {
      onSystemVolumeUp?.call();
    }
  }

  void onVolumeDownDown({int repeatCount = 0}) {
    if (repeatCount > 0 || _volDownPressed) return;
    _volDownPressed = true;
    _volDownLongTriggered = false;
    _volDownTimer = Timer(longPressDuration, () {
      if (_volDownPressed && !_volDownLongTriggered) {
        _volDownLongTriggered = true;
        onVolumeDownLongPress?.call();
      }
    });
  }

  void onVolumeDownUp() {
    _volDownTimer?.cancel();
    _volDownTimer = null;
    final wasTriggered = _volDownLongTriggered;
    final wasPopup = isLanguagePopupOpen;
    _volDownPressed = false;
    _volDownLongTriggered = false;
    if (!wasTriggered) {
      if (wasPopup) {
        onPopupVolumeDown?.call();
      } else {
        onSystemVolumeDown?.call();
      }
    }
  }

  void cancelAll() {
    _volUpTimer?.cancel();
    _volUpTimer = null;
    _volDownTimer?.cancel();
    _volDownTimer = null;
    _volUpPressed = false;
    _volUpLongTriggered = false;
    _volDownPressed = false;
    _volDownLongTriggered = false;
  }
}
