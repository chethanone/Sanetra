import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'bisaya_speech_assembler.dart';
import 'currency_safety_evaluator.dart';
import 'currency_speech_formatter.dart';
import 'ocr/ocr_result.dart';
import 'ocr/ocr_symbol_normalizer.dart';

class _SelectorSpeechRequest {
  _SelectorSpeechRequest({
    required this.text,
    required this.language,
    required this.generationId,
    required this.sw,
    required this.keyAgeMs,
    required this.stateMs,
    required this.invalidateMs,
  });

  final String text;
  final String language;
  final int generationId;
  final Stopwatch sw;
  final int keyAgeMs;
  final int stateMs;
  final int invalidateMs;
}

class _SelectorLatencyTrace {
  _SelectorLatencyTrace({
    required this.token,
    required this.generationId,
    required this.language,
    required this.sw,
    required this.keyAgeMs,
    required this.stateMs,
    required this.invalidateMs,
    required this.stopDispatchMs,
    required this.speakDispatchMs,
  });

  final int token;
  final int generationId;
  final String language;
  final Stopwatch sw;
  final int keyAgeMs;
  final int stateMs;
  final int invalidateMs;
  final int stopDispatchMs;
  final int speakDispatchMs;
}

typedef BisayaTtsInitFn = Future<Map<String, dynamic>?> Function();
typedef BisayaTtsSpeakFn = Future<dynamic> Function(String text, double rate);
typedef BisayaTtsStopFn = Future<dynamic> Function();

/// Shared offline-first audio/TTS service used by both Currency and OCR subsystems.
/// Maintains a single FlutterTts instance, single-flight initialization, and a
/// serialized epoch-guarded speech queue so utterances never overlap, cancelled
/// futures never hang, and callers recover cleanly after errors.
class SpeechService {
  SpeechService({
    FlutterTts? tts,
    MethodChannel? bisayaChannel,
    BisayaTtsInitFn? bisayaInitFn,
    BisayaTtsSpeakFn? bisayaSpeakFn,
    BisayaTtsStopFn? bisayaStopFn,
  }) : _tts = tts ?? FlutterTts(),
       _bisayaChannel =
           bisayaChannel ?? const MethodChannel('vision_assistant/bisaya_tts'),
       _bisayaInitOverride = bisayaInitFn,
       _bisayaSpeakOverride = bisayaSpeakFn,
       _bisayaStopOverride = bisayaStopFn;

  final FlutterTts _tts;
  final MethodChannel _bisayaChannel;
  final BisayaTtsInitFn? _bisayaInitOverride;
  final BisayaTtsSpeakFn? _bisayaSpeakOverride;
  final BisayaTtsStopFn? _bisayaStopOverride;
  bool _bisayaInitialized = false;
  Future<bool>? _bisayaInitFuture;

  bool _initialized = false;
  Future<void>? _initFuture;
  bool _isSpeaking = false;
  String _pendingCancelReason = 'unexplained';
  int _speechEpoch = 0;
  String? _defaultEngine;

  // Phase 5.9: Preemptive Language Selector state & generation guard
  bool _isSelectorOpen = false;
  int _selectorGenerationId = 0;
  int _utteranceTokenSeq = 0;
  int _activeUtteranceToken = 0;
  _SelectorSpeechRequest? _pendingSelectorRequest;
  bool _selectorWorkerRunning = false;
  _SelectorLatencyTrace? _activeSelectorTrace;

  Completer<void>? _activeUtteranceCompleter;
  Future<void> _serialQueue = Future<void>.value();
  Stopwatch? _pendingStartStopwatch;
  String? _lastPreparedLang;
  double? _lastPreparedRate;
  String? _lastPreparedVoiceName;

  final Map<String, bool> _langAvailable = {};
  final Map<String, Map<String, String>> _selectedVoices = {};

  bool get isInitialized => _initialized;
  bool get isSpeaking => _isSpeaking;
  bool get isSelectorOpen => _isSelectorOpen;
  int get speechEpoch => _speechEpoch;
  int get selectorGenerationId => _selectorGenerationId;
  String? get defaultEngine => _defaultEngine;
  Map<String, bool> get languageAvailability =>
      Map.unmodifiable(_langAvailable);
  Map<String, Map<String, String>> get selectedVoices =>
      Map.unmodifiable(_selectedVoices);

  /// Select the best offline/local voice for [lang] from [allVoices] without
  /// hardcoding a single-device requirement:
  /// 1. Exact locale match (e.g. `en-in`) ahead of region-fallback (`en-us`).
  /// 2. Offline (`network_required != 'true'`) ahead of network voices.
  /// 3. Local (`name` contains `local`) ahead of non-local.
  /// 4. Known-good primary Google TTS voice if present on device (`en-in-x-enc-local`,
  ///    `kn-in-x-knd-local`, `hi-in-x-hia-local`), else deterministic name order.
  static Map<String, String>? selectBestVoice(
    String lang,
    List<Map<String, String>> allVoices,
  ) {
    const preferredNames = {
      'en-in': 'en-in-x-enc-local',
      'kn-in': 'kn-in-x-knd-local',
      'hi-in': 'hi-in-x-hia-local',
    };
    final prefix = lang.toLowerCase().replaceAll('_', '-');
    final langPrefix = '${prefix.split('-').first}-';
    final matching = allVoices.where((v) {
      final loc = (v['locale'] ?? '').toLowerCase().replaceAll('_', '-');
      return loc == prefix || loc.startsWith(langPrefix);
    }).toList();
    if (matching.isEmpty) return null;

    matching.sort((a, b) {
      final aExact =
          (a['locale'] ?? '').toLowerCase().replaceAll('_', '-') == prefix
          ? 0
          : 1;
      final bExact =
          (b['locale'] ?? '').toLowerCase().replaceAll('_', '-') == prefix
          ? 0
          : 1;
      if (aExact != bExact) return aExact.compareTo(bExact);

      final aNet = (a['network_required'] ?? '').toLowerCase() == 'true'
          ? 1
          : 0;
      final bNet = (b['network_required'] ?? '').toLowerCase() == 'true'
          ? 1
          : 0;
      if (aNet != bNet) return aNet.compareTo(bNet);

      final aLocal = (a['name'] ?? '').contains('local') ? 0 : 1;
      final bLocal = (b['name'] ?? '').contains('local') ? 0 : 1;
      if (aLocal != bLocal) return aLocal.compareTo(bLocal);

      final preferred = preferredNames[prefix];
      if (preferred != null) {
        final aPref = (a['name'] ?? '').toLowerCase() == preferred ? 0 : 1;
        final bPref = (b['name'] ?? '').toLowerCase() == preferred ? 0 : 1;
        if (aPref != bPref) return aPref.compareTo(bPref);
      }

      return (a['name'] ?? '').compareTo(b['name'] ?? '');
    });

    return matching.first;
  }

  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    final existing = _initFuture;
    if (existing != null) return existing;

    final future = _doInitialize();
    _initFuture = future;
    return future;
  }

  Future<void> _doInitialize() async {
    final sw = Stopwatch()..start();

    try {
      await _tts.awaitSpeakCompletion(true);
      final volRes = await _tts.setVolume(1.0);
      final pitchRes = await _tts.setPitch(1.0);
      final rateRes = await _tts.setSpeechRate(0.48);

      _tts.setStartHandler(() {
        _isSpeaking = true;
        final trace = _activeSelectorTrace;
        if (trace != null && trace.token == _activeUtteranceToken) {
          final onStartMs = trace.sw.elapsedMilliseconds + trace.keyAgeMs;
          debugPrint(
            '[TTS-SEL-LAT] gen=${trace.generationId} lang=${trace.language} '
            'keyAgeMs=${trace.keyAgeMs} stateMs=${trace.stateMs} '
            'invalidateMs=${trace.invalidateMs} stopDispatchMs=${trace.stopDispatchMs} '
            'speakDispatchMs=${trace.speakDispatchMs} onStartMs=$onStartMs',
          );
          _activeSelectorTrace = null;
        }
        final sw = _pendingStartStopwatch;
        if (sw != null) {
          sw.stop();
          debugPrint('[TTS-CB] onStart latencyMs=${sw.elapsedMilliseconds}');
          _pendingStartStopwatch = null;
        } else {
          debugPrint('[TTS-CB] onStart');
        }
      });
      _tts.setCompletionHandler(() {
        if (_activeUtteranceCompleter != null) {
          _isSpeaking = false;
        }
        _pendingCancelReason = 'unexplained';
        debugPrint('[TTS-CB] onDone');
        _completeActiveUtterance();
      });
      _tts.setCancelHandler(() {
        if (_activeUtteranceCompleter != null) {
          _isSpeaking = false;
        }
        final reason = _pendingCancelReason;
        _pendingCancelReason = 'unexplained';
        debugPrint('[TTS-CB] onCancel reason=$reason');
        _completeActiveUtterance();
      });
      _tts.setErrorHandler((msg) {
        debugPrint('[TTS-CB] onError: $msg');
        if (_activeUtteranceCompleter != null) {
          _isSpeaking = false;
        }
        _pendingCancelReason = 'unexplained';
        _completeActiveUtterance();
      });

      try {
        _bisayaChannel.setMethodCallHandler((call) async {
          switch (call.method) {
            case 'onStart':
              _isSpeaking = true;
              final trace = _activeSelectorTrace;
              if (trace != null && trace.token == _activeUtteranceToken) {
                final onStartMs = trace.sw.elapsedMilliseconds + trace.keyAgeMs;
                debugPrint(
                  '[TTS-SEL-LAT] gen=${trace.generationId} lang=${trace.language} '
                  'keyAgeMs=${trace.keyAgeMs} stateMs=${trace.stateMs} '
                  'invalidateMs=${trace.invalidateMs} stopDispatchMs=${trace.stopDispatchMs} '
                  'speakDispatchMs=${trace.speakDispatchMs} onStartMs=$onStartMs',
                );
                _activeSelectorTrace = null;
              }
              final startSw = _pendingStartStopwatch;
              if (startSw != null) {
                startSw.stop();
                debugPrint(
                  '[BISAYA-CB] onStart latencyMs=${startSw.elapsedMilliseconds}',
                );
                _pendingStartStopwatch = null;
              } else {
                debugPrint('[BISAYA-CB] onStart');
              }
              break;
            case 'onDone':
              if (_activeUtteranceCompleter != null) {
                _isSpeaking = false;
              }
              _pendingCancelReason = 'unexplained';
              debugPrint('[BISAYA-CB] onDone');
              _completeActiveUtterance();
              break;
            case 'onCancel':
              if (_activeUtteranceCompleter != null) {
                _isSpeaking = false;
              }
              _pendingCancelReason = 'unexplained';
              debugPrint('[BISAYA-CB] onCancel');
              _completeActiveUtterance();
              break;
            case 'onError':
              debugPrint('[BISAYA-CB] onError: ${call.arguments}');
              if (_activeUtteranceCompleter != null) {
                _isSpeaking = false;
              }
              _pendingCancelReason = 'unexplained';
              _completeActiveUtterance();
              break;
          }
        });
      } catch (_) {}

      try {
        final eng = await _tts.getDefaultEngine;
        _defaultEngine = eng?.toString();
      } catch (_) {}

      final voicesRaw = await _tts.getVoices;
      final List<Map<String, String>> allVoices = [];
      if (voicesRaw is List) {
        for (final v in voicesRaw) {
          if (v is Map) {
            allVoices.add(
              v.map((k, val) => MapEntry(k.toString(), val?.toString() ?? '')),
            );
          }
        }
      }

      for (final lang in const ['en-IN', 'kn-IN', 'hi-IN']) {
        final avail = await _tts.isLanguageAvailable(lang);
        final ok = (avail == true || avail == 1);
        _langAvailable[lang] = ok;

        final best = selectBestVoice(lang, allVoices);
        if (best != null) {
          _selectedVoices[lang] = best;
        }
      }

      // Pre-warm approved local voices in reverse order ending on en-IN
      for (final warmLang in const ['kn-IN', 'hi-IN', 'en-IN']) {
        if (_langAvailable[warmLang] == true) {
          await _tts.setLanguage(warmLang);
          if (_selectedVoices[warmLang] != null) {
            await _applyVoice(_selectedVoices[warmLang]!);
          }
        }
      }
      _lastPreparedLang = 'en-IN';
      _lastPreparedRate = 0.48;
      _lastPreparedVoiceName = _selectedVoices['en-IN']?['name'];

      sw.stop();
      _initialized = true;
      if (_bisayaInitOverride == null) {
        unawaited(
          _bisayaChannel
              .invokeMethod<dynamic>('preloadSelector')
              .catchError((_) => null),
        );
      }
      debugPrint(
        '[TTS-AUDIT] Init=${sw.elapsedMilliseconds}ms engine=$_defaultEngine '
        'vol=$volRes pitch=$pitchRes rate=$rateRes langRes=1 voiceRes=1 '
        'avail=$_langAvailable voices=${_selectedVoices.map((k, v) => MapEntry(k, "${v['name']}(net=${v['network_required']})"))}',
      );
    } catch (e) {
      _initialized = false;
      _initFuture = null;
      debugPrint('[TTS-AUDIO] Init failed: $e');
    }
  }

  void _completeActiveUtterance() {
    final c = _activeUtteranceCompleter;
    if (c != null && !c.isCompleted) {
      c.complete();
    }
    _activeUtteranceCompleter = null;
  }

  Future<dynamic> _applyVoice(Map<String, String> voice) async {
    try {
      final name = voice['name'];
      final locale = voice['locale'];
      if (name != null &&
          locale != null &&
          name.isNotEmpty &&
          locale.isNotEmpty) {
        return await _tts.setVoice({'name': name, 'locale': locale});
      }
    } catch (e) {
      debugPrint('[TTS-AUDIO] setVoice warning: $e');
    }
    return null;
  }

  /// Update language-selector visibility. Opening the selector immediately
  /// invalidates and stops any active ordinary speech so currency/OCR audio
  /// never competes with the selector.
  void setSelectorOpen(bool open) {
    if (_isSelectorOpen == open) return;
    _isSelectorOpen = open;
    _selectorGenerationId++;
    _pendingSelectorRequest = null;
    _activeSelectorTrace = null;
    if (open) {
      _speechEpoch++;
      _activeUtteranceToken = ++_utteranceTokenSeq;
      if (_isSpeaking || _activeUtteranceCompleter != null) {
        _pendingCancelReason = 'selector_opened';
      }
      _isSpeaking = false;
      _completeActiveUtterance();
      if (_initialized) {
        unawaited(_stopAllEngines(const Duration(milliseconds: 200)));
      }
    }
  }

  String _mapLanguageToSelectorClip(String lang) {
    switch (lang) {
      case 'ceb-PH':
        return 'confirm_bisaya';
      case 'kn-IN':
        return 'confirm_kn';
      case 'hi-IN':
        return 'confirm_hi';
      case 'en-IN':
      default:
        return 'confirm_en';
    }
  }

  /// Preemptive selector announcement path: immediately invalidates older
  /// generations, interrupts active speech, and speaks only the latest
  /// selected language without queuing stale selections.
  Future<void> announceSelectorLanguage(
    String text, {
    required String language,
    required int generationId,
    int keyAgeMs = 0,
    int? stateUpdateOffsetMs,
  }) async {
    final cleaned = text.trim();
    if (cleaned.isEmpty) return;

    final sw = Stopwatch()..start();
    final invalidateMs = sw.elapsedMilliseconds + keyAgeMs;
    _selectorGenerationId = generationId;
    _speechEpoch++;
    final token = ++_utteranceTokenSeq;
    _activeUtteranceToken = token;

    final wasActive = _isSpeaking || _activeUtteranceCompleter != null;
    if (wasActive) {
      _pendingCancelReason = 'selector_preempted';
    }
    _isSpeaking = false;
    _completeActiveUtterance();

    _pendingSelectorRequest = _SelectorSpeechRequest(
      text: cleaned,
      language: language,
      generationId: generationId,
      sw: sw,
      keyAgeMs: keyAgeMs,
      stateMs: stateUpdateOffsetMs ?? (sw.elapsedMilliseconds + keyAgeMs),
      invalidateMs: invalidateMs,
    );

    // Immediately stop any active selector audio in native hardware
    unawaited(
      _bisayaChannel
          .invokeMethod<dynamic>('stopSelector')
          .catchError((_) => null),
    );
    if (wasActive && _initialized) {
      unawaited(_stopAllEngines(const Duration(milliseconds: 100)));
    }

    if (_selectorWorkerRunning) return;
    _selectorWorkerRunning = true;
    try {
      await initialize();

      while (_pendingSelectorRequest != null) {
        final req = _pendingSelectorRequest!;
        _pendingSelectorRequest = null;
        if (req.generationId != _selectorGenerationId) continue;

        final clipId = _mapLanguageToSelectorClip(req.language);
        final speakDispatchMs = req.sw.elapsedMilliseconds + req.keyAgeMs;
        _pendingStartStopwatch = req.sw;
        _activeSelectorTrace = _SelectorLatencyTrace(
          token: token,
          generationId: req.generationId,
          language: req.language,
          sw: req.sw,
          keyAgeMs: req.keyAgeMs,
          stateMs: req.stateMs,
          invalidateMs: req.invalidateMs,
          stopDispatchMs: req.sw.elapsedMilliseconds + req.keyAgeMs,
          speakDispatchMs: speakDispatchMs,
        );
        debugPrint(
          '[TTS-SEL-DISPATCH] gen=${req.generationId} lang=${req.language} '
          'clip=$clipId text="${req.text}" stateMs=${req.stateMs} invalidateMs=${req.invalidateMs} '
          'speakDispatchMs=$speakDispatchMs',
        );

        if (_bisayaSpeakOverride != null) {
          await _bisayaSpeakOverride(req.text, 1.0);
        } else {
          try {
            await _bisayaChannel.invokeMethod<dynamic>('speakSelector', {
              'clip': clipId,
              'utteranceId': req.generationId,
            });
          } catch (e) {
            debugPrint(
              '[TTS-SEL-FALLBACK] speakSelector fallback to _tts for test/env: $e',
            );
            await _prepareLanguage(req.language);
            await _speakChunkGuarded(req.text, _speechEpoch);
          }
        }
      }
    } finally {
      _selectorWorkerRunning = false;
    }
  }

  /// Cancel any active or queued speech immediately and unblock any awaiting caller.
  Future<void> stop() async {
    _speechEpoch++;
    _selectorGenerationId++;
    _activeUtteranceToken = ++_utteranceTokenSeq;
    _pendingSelectorRequest = null;
    _activeSelectorTrace = null;
    if (_isSpeaking || _activeUtteranceCompleter != null) {
      _pendingCancelReason = 'user_stop';
    }
    _isSpeaking = false;
    _completeActiveUtterance();
    await _stopAllEngines(const Duration(milliseconds: 500));
  }

  /// Enqueue a serialized TTS task so only one utterance touches the Android
  /// TextToSpeech engine at a time.
  Future<void> _enqueue(Future<void> Function() task) {
    final next = _serialQueue.then((_) => task()).catchError((Object e) {
      debugPrint('[TTS-AUDIO] Serial queue recovered from error: $e');
    });
    _serialQueue = next;
    return next;
  }

  Future<bool> _ensureBisayaInitialized() {
    if (_bisayaInitialized) return Future<bool>.value(true);
    final existing = _bisayaInitFuture;
    if (existing != null) return existing;

    final future = () async {
      try {
        final raw = _bisayaInitOverride != null
            ? await _bisayaInitOverride()
            : await _bisayaChannel.invokeMapMethod<String, dynamic>(
                'initialize',
              );
        if (raw == null) {
          _langAvailable['ceb-PH'] = false;
          return false;
        }
        _bisayaInitialized = true;
        _langAvailable['ceb-PH'] = true;
        _selectedVoices['ceb-PH'] = {
          'name': 'recorded_pcm_clips',
          'locale': 'ceb-PH',
          'network_required': 'false',
        };
        return true;
      } catch (e) {
        debugPrint('[BISAYA-TTS] Lazy init failed: $e');
        _langAvailable['ceb-PH'] = false;
        return false;
      } finally {
        _bisayaInitFuture = null;
      }
    }();
    _bisayaInitFuture = future;
    return future;
  }

  Future<void> _stopAllEngines(Duration timeout) async {
    try {
      await _tts.stop().timeout(timeout);
    } catch (_) {}
    if (_bisayaInitialized || _bisayaStopOverride != null) {
      try {
        final f = _bisayaStopOverride != null
            ? _bisayaStopOverride()
            : _bisayaChannel.invokeMethod<dynamic>('stop');
        await f.timeout(timeout);
      } catch (_) {}
    }
  }

  /// Configure language, speech rate, and offline-preferred voice.
  /// Returns true if the target language is available; false if missing.
  Future<bool> _prepareLanguage(String lang) async {
    final normalized = (lang == 'unknown' || lang.isEmpty) ? 'en-IN' : lang;
    if (normalized == 'ceb-PH') {
      final ok = await _ensureBisayaInitialized();
      if (!ok) {
        debugPrint(
          '[TTS-AUDIO] MISSING_OFFLINE_VOICE: ceb-PH is not available offline.',
        );
        return false;
      }
      _lastPreparedLang = 'ceb-PH';
      _lastPreparedRate = 1.0;
      _lastPreparedVoiceName = 'recorded_pcm_clips';
      return true;
    }

    var avail = _langAvailable[normalized] ?? false;

    if (!avail) {
      try {
        final liveAvail = await _tts.isLanguageAvailable(normalized);
        final ok = (liveAvail == true || liveAvail == 1);
        _langAvailable[normalized] = ok;
        avail = ok;
      } catch (e) {
        debugPrint('[TTS-AUDIO] isLanguageAvailable($normalized) error: $e');
        avail = false;
      }
      if (!avail) {
        debugPrint(
          '[TTS-AUDIO] MISSING_OFFLINE_VOICE: $normalized is not available offline.',
        );
        return false;
      }
    }

    final targetRate = (normalized == 'kn-IN' || normalized == 'hi-IN')
        ? 0.45
        : 0.48;
    final voice = _selectedVoices[normalized];
    final voiceName = voice?['name'];

    if (_lastPreparedLang == normalized &&
        _lastPreparedRate == targetRate &&
        _lastPreparedVoiceName == voiceName) {
      return true;
    }

    dynamic langRes;
    try {
      langRes = await _tts.setLanguage(normalized);
    } catch (e) {
      _lastPreparedLang = null;
      _lastPreparedVoiceName = null;
      debugPrint('[TTS-AUDIO] setLanguage($normalized) error: $e');
      return false;
    }

    dynamic rateRes;
    if (_lastPreparedRate != targetRate) {
      try {
        rateRes = await _tts.setSpeechRate(targetRate);
      } catch (e) {
        debugPrint('[TTS-AUDIO] setSpeechRate($targetRate) warning: $e');
      }
    }

    dynamic voiceRes;
    if (voice != null) {
      voiceRes = await _applyVoice(voice);
    }
    _lastPreparedLang = normalized;
    _lastPreparedRate = targetRate;
    _lastPreparedVoiceName = voiceName;
    debugPrint(
      '[TTS-CFG] lang=$normalized langRes=$langRes rate=$targetRate($rateRes) '
      'voice=${voiceName ?? 'default'} voiceRes=$voiceRes',
    );
    return true;
  }

  Future<void> _speakChunkGuarded(
    String chunk,
    int myEpoch, {
    List<String>? bisayaClips,
  }) async {
    if (myEpoch != _speechEpoch) return;

    final completer = Completer<void>();
    _activeUtteranceCompleter = completer;
    _isSpeaking = true;

    try {
      if (_lastPreparedLang == 'ceb-PH') {
        if (_bisayaSpeakOverride != null) {
          final res = await _bisayaSpeakOverride(
            chunk,
            _lastPreparedRate ?? 1.0,
          );
          debugPrint('[BISAYA-RESULT] res=$res epoch=$myEpoch/$_speechEpoch');
        } else {
          await _bisayaChannel.invokeMethod<dynamic>('speak', {
            'text': chunk,
            if (bisayaClips != null && bisayaClips.isNotEmpty)
              'clips': bisayaClips,
            'rate': _lastPreparedRate ?? 1.0,
          });
          await completer.future.timeout(
            const Duration(seconds: 25),
            onTimeout: () {
              debugPrint('[BISAYA-TTS] speak() timeout after 25s for "$chunk"');
            },
          );
          debugPrint('[BISAYA-RESULT] done epoch=$myEpoch/$_speechEpoch');
        }
      } else {
        final speakFuture = _tts.speak(chunk);
        final speakRes =
            await Future.any<dynamic>([
              speakFuture,
              completer.future.then((_) => 'interrupted'),
            ]).timeout(
              const Duration(seconds: 15),
              onTimeout: () {
                debugPrint(
                  '[TTS-AUDIO] speak() timeout after 15s for "$chunk"',
                );
                return 'timeout';
              },
            );
        debugPrint('[TTS-RESULT] res=$speakRes epoch=$myEpoch/$_speechEpoch');
      }
    } catch (e) {
      debugPrint('[TTS-AUDIO] _speakChunkGuarded error: $e');
    } finally {
      if (identical(_activeUtteranceCompleter, completer)) {
        if (!completer.isCompleted) {
          completer.complete();
        }
        _activeUtteranceCompleter = null;
      }
      if (myEpoch == _speechEpoch) {
        _isSpeaking = false;
      }
    }
  }

  Future<void> _restoreDefaultEnglishVoice(int myEpoch) async {
    if (myEpoch != _speechEpoch) return;
    _isSpeaking = false;
    if (_lastPreparedLang == 'en-IN' &&
        _lastPreparedVoiceName == _selectedVoices['en-IN']?['name']) {
      return;
    }
    try {
      await _tts.setLanguage('en-IN');
      final enVoice = _selectedVoices['en-IN'];
      if (enVoice != null) {
        await _applyVoice(enVoice);
      }
      _lastPreparedLang = 'en-IN';
      _lastPreparedVoiceName = enVoice?['name'];
    } catch (_) {}
  }

  /// Split long text into natural sentence/clause chunks (<= maxChars)
  /// so Android TTS neither clips long paragraphs nor pauses word-by-word.
  static List<String> chunkText(String text, {int maxChars = 260}) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return const [];
    if (cleaned.length <= maxChars) return [cleaned];

    final sentences = cleaned.split(RegExp(r'(?<=[.!?।])\s+'));
    final chunks = <String>[];
    final current = StringBuffer();

    for (final s in sentences) {
      if (s.trim().isEmpty) continue;
      if (current.isEmpty) {
        current.write(s.trim());
      } else if (current.length + 1 + s.trim().length <= maxChars) {
        current.write(' ');
        current.write(s.trim());
      } else {
        chunks.add(current.toString());
        current.clear();
        current.write(s.trim());
      }
    }
    if (current.isNotEmpty) {
      chunks.add(current.toString());
    }
    return chunks;
  }

  /// Speak a single utterance in [language], cancelling any prior speech when
  /// [interrupt] is true, or skipping when [interrupt] is false and already speaking.
  Future<void> speakText(
    String text, {
    String language = 'en-IN',
    bool interrupt = true,
    List<String>? bisayaClips,
  }) async {
    if (_isSelectorOpen) return;
    await initialize();
    if (!_initialized || _isSelectorOpen) return;

    final cleaned = text.trim();
    if (cleaned.isEmpty) return;

    if (!interrupt && _isSpeaking) {
      return;
    }

    final int myEpoch;
    final sw = Stopwatch()..start();
    _pendingStartStopwatch = sw;
    if (interrupt) {
      final wasActive = _isSpeaking || _activeUtteranceCompleter != null;
      myEpoch = ++_speechEpoch;
      if (wasActive) {
        _pendingCancelReason = 'new_utterance_requested';
      }
      _isSpeaking = false;
      _completeActiveUtterance();
      if (wasActive) {
        await _stopAllEngines(const Duration(milliseconds: 250));
      }
    } else {
      myEpoch = _speechEpoch;
    }

    await _enqueue(() async {
      if (myEpoch != _speechEpoch || _isSelectorOpen) return;
      if (!interrupt && _isSpeaking) return;

      try {
        final ok = await _prepareLanguage(language);
        if (myEpoch != _speechEpoch) return;

        if (!ok && language != 'en-IN') {
          final fallbackOk = await _prepareLanguage('en-IN');
          if (!fallbackOk || myEpoch != _speechEpoch) return;
          debugPrint(
            '[TTS-AUDIO] Diagnostic: "$language" voice unavailable; speaking diagnostic in en-IN.',
          );
          await _speakChunkGuarded(
            '$language offline voice is not installed.',
            myEpoch,
          );
          return;
        }
        if (!ok) return;

        final activeLang = ok ? language : 'en-IN';
        if (activeLang == 'ceb-PH' &&
            bisayaClips != null &&
            bisayaClips.isNotEmpty) {
          debugPrint(
            '[TTS-SPEAK] ($activeLang) clips=${bisayaClips.join("+")}',
          );
          await _speakChunkGuarded(cleaned, myEpoch, bisayaClips: bisayaClips);
        } else {
          for (final chunk in chunkText(cleaned)) {
            if (myEpoch != _speechEpoch) break;
            debugPrint('[TTS-SPEAK] ($activeLang) "$chunk"');
            await _speakChunkGuarded(chunk, myEpoch);
          }
        }
      } catch (e) {
        debugPrint('[TTS-AUDIO] speakText error: $e');
      } finally {
        await _restoreDefaultEnglishVoice(myEpoch);
      }
    });
  }

  /// Queue a short status announcement (e.g., automatic flashlight ON/OFF)
  /// onto the existing serialized speech queue without interrupting an
  /// ongoing recognition utterance.
  Future<void> enqueueShortAnnouncement(
    String text, {
    String language = 'en-IN',
    List<String>? bisayaClips,
  }) async {
    if (_isSelectorOpen) return;
    await initialize();
    if (!_initialized || _isSelectorOpen) return;

    final cleaned = text.trim();
    if (cleaned.isEmpty) return;

    final int myEpoch = _speechEpoch;
    await _enqueue(() async {
      if (myEpoch != _speechEpoch || _isSelectorOpen) return;
      try {
        final ok = await _prepareLanguage(language);
        if (myEpoch != _speechEpoch || _isSelectorOpen) return;
        final activeLang = ok ? language : 'en-IN';
        if (!ok && language != 'en-IN' && language != 'ceb-PH') {
          final fallbackOk = await _prepareLanguage('en-IN');
          if (!fallbackOk || myEpoch != _speechEpoch || _isSelectorOpen) return;
        } else if (!ok) {
          return;
        }
        debugPrint('[TTS-FLASHLIGHT] ($activeLang) "$cleaned"');
        await _speakChunkGuarded(
          cleaned,
          myEpoch,
          bisayaClips: activeLang == 'ceb-PH' ? bisayaClips : null,
        );
      } catch (e) {
        debugPrint('[TTS-FLASHLIGHT] enqueueShortAnnouncement error: $e');
      } finally {
        await _restoreDefaultEnglishVoice(myEpoch);
      }
    });
  }

  /// Speak multi-language OCR lines in exact reading order, grouping consecutive
  /// lines with the same language so voice switches only happen at script boundaries.
  /// When [sceneSummary] is provided, announces concise layout/centering guidance first.
  Future<void> speakOcrLines(
    List<OcrLineResult> lines, {
    String? sceneSummary,
  }) async {
    if (_isSelectorOpen) return;
    await initialize();
    if (!_initialized || _isSelectorOpen) return;

    if (lines.isEmpty) {
      await speakText(
        'No text detected. Please hold closer.',
        language: 'en-IN',
      );
      return;
    }

    final myEpoch = ++_speechEpoch;
    final wasActive = _isSpeaking || _activeUtteranceCompleter != null;
    if (wasActive) {
      _pendingCancelReason = 'new_utterance_requested';
    }
    _isSpeaking = false;
    _completeActiveUtterance();
    if (wasActive) {
      await _stopAllEngines(const Duration(milliseconds: 500));
    }

    final groups = <({String lang, List<String> texts})>[];
    final trimmedSummary = sceneSummary?.trim() ?? '';
    if (trimmedSummary.isNotEmpty) {
      groups.add((lang: 'en-IN', texts: [trimmedSummary]));
    }
    for (final line in lines) {
      if (line.isLanguageUncertain && line.confidence < 0.58) {
        debugPrint(
          '[TTS-OCR] Skipping unverified region (${(line.confidence * 100).toStringAsFixed(0)}%): "${line.text}"',
        );
        continue;
      }
      final units = line.segments.isNotEmpty
          ? line.segments
                .where((s) => !(s.isLanguageUncertain && s.confidence < 0.58))
                .map((s) => (lang: s.language, text: s.text))
          : [(lang: line.language, text: line.text)];
      for (final unit in units) {
        final lang = (unit.lang == 'unknown' || unit.lang.isEmpty)
            ? 'en-IN'
            : unit.lang;
        final txt = unit.text.trim();
        if (txt.isEmpty) continue;
        final spokenTxt = OcrSymbolNormalizer.expandForSpeech(txt, lang);
        if (spokenTxt.isEmpty) continue;
        if (groups.isNotEmpty && groups.last.lang == lang) {
          groups.last.texts.add(spokenTxt);
        } else {
          groups.add((lang: lang, texts: [spokenTxt]));
        }
      }
    }

    if (groups.isEmpty) {
      groups.add((
        lang: 'en-IN',
        texts: ['Text unclear. Please hold steady and try again.'],
      ));
    }

    await _enqueue(() async {
      if (myEpoch != _speechEpoch) return;

      try {
        for (final group in groups) {
          if (myEpoch != _speechEpoch) break;
          final joined = group.texts.join('. ');
          final ok = await _prepareLanguage(group.lang);
          if (myEpoch != _speechEpoch) break;

          if (!ok) {
            final enOk = await _prepareLanguage('en-IN');
            if (!enOk || myEpoch != _speechEpoch) continue;
            debugPrint(
              '[TTS-OCR] MISSING_OFFLINE_VOICE: ${group.lang}; skipping silent substitution.',
            );
            await _speakChunkGuarded(
              '${group.lang} offline voice unavailable.',
              myEpoch,
            );
            continue;
          }

          final voiceName = _selectedVoices[group.lang]?['name'] ?? 'default';
          for (final chunk in chunkText(joined)) {
            if (myEpoch != _speechEpoch) break;
            debugPrint(
              '[TTS-OCR] (${group.lang} / $voiceName) Speaking: "$chunk"',
            );
            await _speakChunkGuarded(chunk, myEpoch);
          }
        }
      } catch (e) {
        debugPrint('[TTS-OCR] speakOcrLines error: $e');
      } finally {
        await _restoreDefaultEnglishVoice(myEpoch);
      }
    });
  }

  /// Speak a currency safety assessment in English (`en-IN`), Kannada (`kn-IN`),
  /// or Hindi (`hi-IN`).
  Future<void> speakCurrencyAssessment(
    CurrencySafetyAssessment assessment, {
    String language = 'en-IN',
    bool interrupt = true,
  }) async {
    if (_isSelectorOpen) return;
    final text = CurrencySpeechFormatter.formatAssessment(
      assessment,
      language: language,
    );
    debugPrint('[TTS-CURRENCY-$language] (${assessment.status.name}) "$text"');
    await speakText(
      text,
      language: language,
      interrupt: interrupt,
      bisayaClips: language == 'ceb-PH'
          ? BisayaSpeechAssembler.clipsForAssessment(assessment)
          : null,
    );
  }

  /// Internal debug-only diagnostic to verify audible English, Kannada, and Hindi
  /// playback independently of currency/OCR pipelines.
  Future<void> runDebugDiagnostic() async {
    const samples = <({String lang, String phrase})>[
      (lang: 'en-IN', phrase: 'Testing English voice output.'),
      (lang: 'kn-IN', phrase: 'ಕನ್ನಡ ಧ್ವನಿ ಪರೀಕ್ಷೆ.'),
      (lang: 'hi-IN', phrase: 'हिन्दी आवाज परीक्षण.'),
    ];
    for (final s in samples) {
      debugPrint(
        '[TTS-DIAG] Testing ${s.lang} voice=${_selectedVoices[s.lang]?['name'] ?? 'pending'}',
      );
      await speakText(s.phrase, language: s.lang, interrupt: true);
    }
  }

  /// Synthesize text directly to an audio file on-device for offline quality verification.
  Future<dynamic> synthesizeToFile(
    String text,
    String fileName, {
    String language = 'kn-IN',
  }) async {
    await initialize();
    if (!_initialized) return null;
    await _prepareLanguage(language);
    return _tts.synthesizeToFile(text, fileName);
  }

  Future<void> dispose() async {
    await stop();
  }
}
