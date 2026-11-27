import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vision_assistant/services/app_update_service.dart';
import 'package:vision_assistant/services/auto_flashlight_controller.dart';
import 'package:vision_assistant/services/banknote_tracker.dart';
import 'package:vision_assistant/services/currency_language_controller.dart';
import 'package:vision_assistant/services/currency_model_service.dart';
import 'package:vision_assistant/services/currency_region.dart';
import 'package:vision_assistant/services/currency_safety_evaluator.dart';
import 'package:vision_assistant/services/currency_speech_formatter.dart';
import 'package:vision_assistant/services/mode_transition_controller.dart';
import 'package:vision_assistant/services/ocr/ocr_service.dart';
import 'package:vision_assistant/services/speech_service.dart';
import 'package:vision_assistant/widgets/banknote_overlay_painter.dart';
import 'package:vision_assistant/widgets/update_prompt_dialog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const VisionAssistantApp());
}

class VisionAssistantApp extends StatelessWidget {
  const VisionAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    const bool isCandidate = bool.fromEnvironment(
      'CANDIDATE_BUILD',
      defaultValue: false,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: isCandidate ? 'Sanetra Candidate' : 'Sanetra',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          secondary: Color(0xFF64B5F6),
          surface: Color(0xFF161616),
        ),
        useMaterial3: true,
      ),
      home: const CameraScreen(),
    );
  }
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  static const MethodChannel _hardwareKeysChannel = MethodChannel(
    'vision_assistant/hardware_keys',
  );

  CameraController? _cameraController;
  late final CurrencyModelService _currencyModelService;
  late final OcrService _ocrService;
  late final SpeechService _speechService;
  late final AutoFlashlightController _autoFlashlightController;
  late final AppUpdateService _appUpdateService;
  bool _isUpdateDialogVisible = false;

  // Real-time Detection State
  bool _cameraReady = false;
  bool _currencyModelReady = false;
  bool _ocrModelReady = false;

  late final CurrencyLanguageController _languageController =
      CurrencyLanguageController(
        initialLanguage: _currencyLanguage,
        onSpeak: (text, {required language, required interrupt}) =>
            _speechService.speakText(
              text,
              language: language,
              interrupt: interrupt,
            ),
        onPreemptSpeak:
            (
              text, {
              required language,
              required generationId,
              int keyAgeMs = 0,
              int? stateUpdateOffsetMs,
            }) => _speechService.announceSelectorLanguage(
              text,
              language: language,
              generationId: generationId,
              keyAgeMs: keyAgeMs,
              stateUpdateOffsetMs: stateUpdateOffsetMs,
            ),
        onStopSpeech: () => _speechService.stop(),
        onPreferenceChanged: (code) =>
            unawaited(_saveCurrencyLanguagePreference(code)),
      );

  bool _isProcessingFrame = false;
  int _currencyInferenceEpoch = 0;
  bool _isLiveStreamActive = false;
  bool _isTorchOn = false;
  bool _isMuted = false;
  String _currencyLanguage = 'en-IN';
  final CurrencyRegionController _currencyRegionController =
      CurrencyRegionController();
  bool _showLanguagePopup = false;
  bool _isCurrencyMode =
      true; // Mode toggle: Currency (true) vs Document Text OCR (false)
  int _lastTriggeredOcrGen = -1;
  bool _isTakingPicture = false;
  late final ModeTransitionController
  _modeController = ModeTransitionController(
    selectorInactivityTimeout: const Duration(seconds: 4),
    initialCurrencyMode: _isCurrencyMode,
    onSelectorTimeout: () => _closeLanguagePopup(announce: true),
    onTriggerAutoOcr: (modeGen) {
      unawaited(
        _triggerOcrTextRecognition(
          expectedModeGen: modeGen,
          announceEntry: true,
        ),
      );
    },
    onTriggerRereadOcr: (modeGen) {
      unawaited(
        _triggerOcrTextRecognition(
          expectedModeGen: modeGen,
          announceEntry: false,
          isReread: true,
        ),
      );
    },
    onStopOcr: (modeGen) {
      debugPrint(
        '[MODE-OCR-CANCEL] Stopped OCR on return to Currency (gen=$modeGen)',
      );
      unawaited(_speechService.stop());
    },
  );

  List<CurrencyDetection> _currentDetections = const [];
  CurrencySafetyAssessment? _currentSafetyAssessment;
  int _feedWidth = 720;
  int _feedHeight = 1280;

  // Rock-Solid Currency Temporal Tracker (flavor-isolated candidate fixes when active)
  late BanknoteTracker _currencyTracker;
  int _lastInferenceTimestamp = 0;
  int _liveAuditFrameIndex = 0;
  int _liveAuditEmptyStreak = 0;

  // Currency Speech Announcement State
  String _lastSpokenSignature = '';
  String _pendingSignature = '';
  int _pendingCount = 0;
  bool _isSpeakingCurrency = false;
  DateTime _lastSpokenTime = DateTime.fromMillisecondsSinceEpoch(0);

  // Assistive Haptic Guidance State (Continuous vibration when currency visible until recognized)
  Timer? _hapticGuidanceTimer;
  bool _isGuidanceVibrating = false;

  // Currency Snapshot Capture State
  bool _isCurrencyCapturing = false;
  CurrencyInferenceResult? _lastCaptureResult;
  CurrencySafetyAssessment? _lastCaptureSafetyAssessment;
  bool _showCaptureResult = false;

  // OCR State
  bool _isOcrRunning = false;
  bool _isSpeakingOcr = false;
  OcrResult? _lastOcrResult;
  bool _showOcrSheet = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _currencyModelService = CurrencyModelService();
    _currencyTracker = BanknoteTracker(
      candidateMode: _currencyModelService.isCandidateMode,
    );
    _ocrService = OcrService();
    _speechService = SpeechService();
    _autoFlashlightController = AutoFlashlightController(
      config: const AutoFlashlightConfig(
        lightOnThresholdLux: 3.0,
        lightOffThresholdLux: 10.0,
        reflectionHeadroomLux: 5.0,
        maxReflectionBaselineLux: 35.0,
      ),
      onSetTorch: _setTorchFromAutoController,
      onAnnounce: (text, {required language}) async {
        if (_isMuted || _showLanguagePopup) return;
        await _speechService.enqueueShortAnnouncement(text, language: language);
      },
      onAnnounceWithClips: (text, {required language, bisayaClips}) async {
        if (_isMuted || _showLanguagePopup) return;
        await _speechService.enqueueShortAnnouncement(
          text,
          language: language,
          bisayaClips: bisayaClips,
        );
      },
      getSpeechLanguage: () => _currencyLanguage,
      onTorchStateChanged: (enabled) {
        if (mounted) {
          setState(() => _isTorchOn = enabled);
        }
      },
    );
    _appUpdateService = AppUpdateService();
    _appUpdateService.startConnectivityListener(
      onUpdateFound: _handleUpdateAvailable,
      canCheckNow: _canRunUpdateCheck,
    );

    _setupHardwareKeyChannel();
    unawaited(_loadCurrencyLanguagePreference());
    unawaited(_speechService.initialize());
    _initializeCamera();
    _loadModels();
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        unawaited(_checkForAppUpdate());
      }
    });
  }

  bool _canRunUpdateCheck() {
    return mounted &&
        !_isOcrRunning &&
        !_isCurrencyCapturing &&
        !_showLanguagePopup &&
        !_isUpdateDialogVisible;
  }

  Future<void> _handleResumedUpdateCheck() async {
    if (_isUpdateDialogVisible) return;
    try {
      final pending = await _appUpdateService.validateRestoredPendingInstall();
      if (pending != null && mounted) {
        final permitted = await _appUpdateService.canRequestPackageInstalls();
        if (permitted) {
          await _appUpdateService.resumePendingInstallIfPermitted();
          return;
        }
      }
    } catch (_) {}
    await _checkForAppUpdate();
  }

  Future<void> _checkForAppUpdate() async {
    if (!_canRunUpdateCheck()) return;
    final res = await _appUpdateService.checkForUpdate();
    if (res.status == UpdateCheckStatus.updateAvailable ||
        res.status == UpdateCheckStatus.migrationAvailable) {
      _handleUpdateAvailable(res);
    }
  }

  void _handleUpdateAvailable(UpdateCheckResult result) {
    final manifest = result.manifest;
    if (!mounted || _isUpdateDialogVisible || manifest == null) return;
    if (_appUpdateService.isVersionDismissed(manifest.versionCode)) return;

    if (!_appUpdateService.hasAnnouncedVersion(manifest.versionCode)) {
      _appUpdateService.markVersionAnnounced(manifest.versionCode);
      if (!_isMuted) {
        unawaited(
          _speechService.enqueueShortAnnouncement(
            'A new Sanetra update is available.',
            language: 'en-IN',
          ),
        );
      }
    }

    _isUpdateDialogVisible = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => UpdatePromptDialog(
          manifest: manifest,
          updateService: _appUpdateService,
          isMigration: result.status == UpdateCheckStatus.migrationAvailable,
          onLater: () => _appUpdateService.dismissVersion(manifest.versionCode),
        ),
      ).whenComplete(() {
        _isUpdateDialogVisible = false;
      }),
    );
  }

  Future<File> _languagePrefFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/currency_language_pref.txt');
  }

  Future<void> _loadCurrencyLanguagePreference() async {
    try {
      final file = await _languagePrefFile();
      if (await file.exists()) {
        final saved = (await file.readAsString()).trim();
        final isValid = CurrencyLanguageController.isValidCode(saved);
        if (isValid && mounted) {
          _languageController.setSelectedCode(saved);
          setState(() {
            _currencyLanguage = saved;
            _syncCurrencyRegionForLanguage(saved);
          });
          debugPrint('[PREF] Loaded currency language: $saved');
        }
      }
    } catch (e) {
      debugPrint('[PREF] Failed to load currency language: $e');
    }
  }

  Future<void> _saveCurrencyLanguagePreference(String code) async {
    try {
      final file = await _languagePrefFile();
      await file.writeAsString(code, flush: true);
    } catch (e) {
      debugPrint('[PREF] Failed to save currency language: $e');
    }
  }

  /// Listen for hardware Volume Up / Volume Down gestures from Android native activity
  void _setupHardwareKeyChannel() {
    _hardwareKeysChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onVolumeUpLongPress':
          if (!_showLanguagePopup) {
            debugPrint('[HARDWARE-KEY] Volume Up 2s hold -> Switching mode');
            _setMode(!_isCurrencyMode);
          }
          break;
        case 'onVolumeUpDoublePress':
          if (!_showLanguagePopup && !_isCurrencyMode) {
            final gen = _modeController.requestOcrReread();
            debugPrint(
              '[HARDWARE-KEY] Volume Up double-press -> Reread OCR (gen=$gen)',
            );
          }
          break;
        case 'onVolumeDownLongPress':
          debugPrint(
            '[HARDWARE-KEY] Volume Down 2s hold -> Toggling language popup',
          );
          _toggleLanguagePopup();
          break;
        case 'onPopupVolumeUp':
          if (_showLanguagePopup) {
            final args = call.arguments as Map?;
            final keyAgeMs = (args?['nativeAgeMs'] as int?) ?? 0;
            _navigateLanguageUp(keyAgeMs: keyAgeMs);
          }
          break;
        case 'onPopupVolumeDown':
          if (_showLanguagePopup) {
            final args = call.arguments as Map?;
            final keyAgeMs = (args?['nativeAgeMs'] as int?) ?? 0;
            _navigateLanguageDown(keyAgeMs: keyAgeMs);
          }
          break;
        case 'onSynthKannadaEval':
          await _runKannadaTtsCorpusSynthesis();
          break;
        case 'onTtsDiagnostic':
          await _speechService.runDebugDiagnostic();
          break;
        case 'onOcrEvalImage':
          final args = call.arguments as Map?;
          final path = args?['path'] as String?;
          final lang = args?['lang'] as String?;
          final speak = (args?['speak'] as bool?) ?? true;
          if (path != null && path.isNotEmpty) {
            await _runOcrEvalImage(path, preferredLang: lang, speak: speak);
          }
          break;
      }
    });
  }

  Future<void> _runOcrEvalImage(
    String path, {
    String? preferredLang,
    bool speak = true,
  }) async {
    final swTotal = Stopwatch()..start();
    try {
      final file = File(path);
      if (!await file.exists()) {
        debugPrint('[OCR-EVAL] Missing file: $path');
        return;
      }
      final bytes = await file.readAsBytes();
      final result = await _ocrService.processImage(
        bytes,
        preferredLanguage: preferredLang ?? _languageController.selectedCode,
      );
      if (mounted) {
        setState(() {
          _lastOcrResult = result;
        });
      }
      debugPrint(
        '[OCR-EVAL] file=$path prefLang=${preferredLang ?? _languageController.selectedCode} '
        'durationMs=${result.durationMs} img=${result.imageWidth}x${result.imageHeight} '
        'lines=${result.lines.length} sceneSummary="${result.sceneSummary}" '
        'fullText=${result.fullText.replaceAll("\n", " | ")}',
      );
      for (final line in result.lines) {
        debugPrint(
          '[OCR-EVAL-LINE] #${line.lineIndex} lang=${line.language} '
          'geom=${line.geometryType} angle=${line.orientationDegrees} '
          'col=${line.columnIndex} heading=${line.isHeading} pos=${line.spatialPosition} '
          'uncertain=${line.isLanguageUncertain} conf=${line.confidence.toStringAsFixed(3)} '
          'box=(${line.polygon.minX.round()},${line.polygon.minY.round()},${line.polygon.maxX.round()},${line.polygon.maxY.round()}) '
          'text="${line.text}"',
        );
      }
      if (speak && result.lines.isNotEmpty) {
        await _speechService.speakOcrLines(
          result.lines,
          sceneSummary: result.sceneSummary,
        );
        debugPrint(
          '[OCR-EVAL-TTS] spoken_lines=${result.lines.length} totalMs=${swTotal.elapsedMilliseconds}',
        );
      }
    } catch (e) {
      debugPrint('[OCR-EVAL] ERROR: $e');
    }
  }

  Future<void> _runKannadaTtsCorpusSynthesis() async {
    const samples = <({String id, String lang, String text})>[
      (
        id: 'kn_01_conv',
        lang: 'kn-IN',
        text: 'ನಮಸ್ಕಾರ, ನಿಮಗೆ ಹೇಗೆ ಸಹಾಯ ಮಾಡಬಹುದು?',
      ),
      (id: 'kn_02_currency_27', lang: 'kn-IN', text: 'ಇಪ್ಪತ್ತೇಳು ರೂಪಾಯಿ'),
      (
        id: 'kn_03_currency_550',
        lang: 'kn-IN',
        text: 'ಐದು ನೂರು ರೂಪಾಯಿ ನೋಟು, ಐವತ್ತು ರೂಪಾಯಿ ನೋಟು. ಒಟ್ಟು ಐದು ನೂರ ಐವತ್ತು ರೂಪಾಯಿ.',
      ),
      (
        id: 'kn_04_medicine',
        lang: 'kn-IN',
        text: 'ದಿನಕ್ಕೆ ಎರಡು ಬಾರಿ ಊಟದ ನಂತರ ಒಂದು ಮಾತ್ರೆ ತೆಗೆದುಕೊಳ್ಳಿ.',
      ),
      (
        id: 'kn_05_signboard',
        lang: 'kn-IN',
        text: 'ಬೆಂಗಳೂರು ಮಹಾನಗರ ಸಾರಿಗೆ ಸಂಸ್ಥೆ, ನಿರ್ಗಮನ ದ್ವಾರ.',
      ),
      (
        id: 'kn_06_paragraph',
        lang: 'kn-IN',
        text: 'ಈ ಔಷಧಿಯನ್ನು ತಂಪಾದ ಮತ್ತು ಒಣಗಿದ ಸ್ಥಳದಲ್ಲಿ ಇಡಿ. ಮಕ್ಕಳ ಕೈಗೆ ಸಿಗದಂತೆ ಜಾಗ್ರತೆ ವಹಿಸಿ.',
      ),
      (
        id: 'kn_07_date_time',
        lang: 'kn-IN',
        text: 'ಇಂದು ದಿನಾಂಕ ಹದಿನೈದು ನವೆಂಬರ್, ಸಮಯ ಬೆಳಗ್ಗೆ ಒಂಬತ್ತು ಗಂಟೆ ಮೂವತ್ತು ನಿಮಿಷ.',
      ),
      (
        id: 'hi_01_test',
        lang: 'hi-IN',
        text: 'कृपया इस दवा को भोजन के बाद लें।',
      ),
      (
        id: 'en_01_test',
        lang: 'en-IN',
        text: 'Paracetamol 500 milligrams. Take one tablet after food.',
      ),
    ];
    debugPrint(
      '[TTS-EVAL] Starting synthesis of ${samples.length} offline evaluation samples...',
    );
    for (final s in samples) {
      final sw = Stopwatch()..start();
      final res = await _speechService.synthesizeToFile(
        s.text,
        '${s.id}.wav',
        language: s.lang,
      );
      sw.stop();
      debugPrint(
        '[TTS-EVAL] ${s.id} (${s.lang}) -> $res in ${sw.elapsedMilliseconds}ms',
      );
    }
    debugPrint('[TTS-EVAL] Completed all evaluation samples.');
  }

  Future<void> _loadModels() async {
    // 1. Currency Model
    try {
      await _currencyModelService.loadModel(useCandidate: true);
      _currencyTracker = BanknoteTracker(
        candidateMode: _currencyModelService.isCandidateMode,
      );
      if (mounted) {
        setState(() => _currencyModelReady = true);
      }
      _checkAndStartLiveStream();
    } catch (e) {
      debugPrint('[CURRENCY-INIT] Load failed: $e');
    }

    // 2. OCR Models
    try {
      await _ocrService.loadModels();
      if (mounted) {
        setState(() => _ocrModelReady = true);
      }
    } catch (e) {
      debugPrint('[OCR-INIT] Load failed: $e');
    }
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;

      // Automatically select the best rear-facing camera
      final rearCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      // ResolutionPreset.high provides crisp 720p (1280x720) optimal for real-time mobile AI
      final controller = CameraController(
        rearCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      _cameraController = controller;
      await controller.initialize();

      try {
        await controller.setExposureMode(ExposureMode.auto);
        await controller.setFocusMode(FocusMode.auto);
      } catch (e) {
        debugPrint('[CAMERA] Exposure/Focus config: $e');
      }

      if (!mounted) return;

      setState(() {
        _cameraReady = true;
      });

      _checkAndStartLiveStream();
      unawaited(
        _autoFlashlightController.startMonitoring(
          _isCurrencyMode
              ? RecognitionTorchMode.currency
              : RecognitionTorchMode.ocr,
        ),
      );
    } catch (e) {
      debugPrint('[CAMERA] Init failed: $e');
    }
  }

  Future<void> _handleTapToFocus(
    TapDownDetails details,
    BoxConstraints constraints,
  ) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    final x = (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
    final y = (details.localPosition.dy / constraints.maxHeight).clamp(
      0.0,
      1.0,
    );
    try {
      await controller.setFocusPoint(Offset(x, y));
      await controller.setExposurePoint(Offset(x, y));
      HapticFeedback.selectionClick();
    } catch (e) {
      debugPrint('[CAMERA] Tap to focus error: $e');
    }
  }

  void _checkAndStartLiveStream() {
    if (_cameraReady &&
        _currencyModelReady &&
        !_isLiveStreamActive &&
        _cameraController != null &&
        _cameraController!.value.isInitialized) {
      _startLiveStream();
    }
  }

  Future<void> _startLiveStream() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isStreamingImages) return;

    _isLiveStreamActive = true;
    _currencyTracker.reset();
    debugPrint('[LIVE-STREAM] Starting real-time currency vision stream...');

    try {
      await controller.startImageStream((CameraImage image) async {
        if (!_isLiveStreamActive ||
            _isProcessingFrame ||
            !_currencyModelReady) {
          return;
        }

        // Skip currency AI if in Document Text OCR mode, language selector is open,
        // or currently reading OCR / capturing currency snapshot
        if (!_isCurrencyMode ||
            _showLanguagePopup ||
            _isOcrRunning ||
            _showOcrSheet ||
            _isCurrencyCapturing) {
          if (_currentDetections.isNotEmpty && mounted && !_showLanguagePopup) {
            setState(() {
              _currentDetections = const [];
            });
          }
          return;
        }

        // Real-time camera inference with low latency (120ms throttle -> up to 7-8 FPS)
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastInferenceTimestamp < 120) {
          return;
        }
        _lastInferenceTimestamp = now;

        _isProcessingFrame = true;
        final frameEpoch = _currencyInferenceEpoch;
        final frameRegion = _currencyRegionController.region;
        final frameRegionEpoch = _currencyRegionController.regionEpoch;

        // Strict cross-currency isolation: never run INR ONNX detectors when
        // Philippine Peso (PHP / Bisaya) region is active.
        if (frameRegion == CurrencyRegion.php) {
          _isProcessingFrame = false;
          return;
        }

        try {
          final sensorOrientation = controller.description.sensorOrientation;
          final result = await _currencyModelService.runCameraImageInference(
            image,
            sensorOrientation: sensorOrientation,
          );

          if (!mounted ||
              !_isLiveStreamActive ||
              !_isCurrencyMode ||
              _showLanguagePopup ||
              frameEpoch != _currencyInferenceEpoch ||
              !_currencyRegionController.isResultCurrent(
                capturedEpoch: frameRegionEpoch,
                capturedRegion: frameRegion,
              )) {
            return;
          }

          // Strict region allowlist before tracking & safety screening
          final regionFilteredDetections = filterDetectionsForRegion(
            result.detections,
            frameRegion,
          );
          final trackerResult = _currencyTracker.updateWithSafety(
            regionFilteredDetections,
            imageWidth: result.imageWidth,
            imageHeight: result.imageHeight,
            extraReasons: result.uncertaintyReasons.toSet(),
          );
          final activeDetections = trackerResult.activeDetections;

          if (_currencyModelService.isCandidateMode) {
            _logCandidateLiveAudit(result, trackerResult);
          }

          _updateHapticGuidance(trackerResult.assessment, activeDetections);
          _handleRealtimeSpeech(trackerResult.assessment);

          setState(() {
            _currentDetections = activeDetections;
            _currentSafetyAssessment = trackerResult.assessment;
            _feedWidth = result.imageWidth;
            _feedHeight = result.imageHeight;
          });
        } catch (e) {
          debugPrint('[LIVE-FRAME] Inference error: $e');
        } finally {
          _isProcessingFrame = false;
        }
      });
    } catch (e) {
      debugPrint('[LIVE-STREAM] Failed to start stream: $e');
      _isLiveStreamActive = false;
    }
  }

  Future<void> _stopLiveStream() async {
    _isLiveStreamActive = false;
    _stopHapticGuidance();
    _currencyTracker.reset();
    final controller = _cameraController;
    if (controller != null && controller.value.isStreamingImages) {
      try {
        await controller.stopImageStream();
      } catch (e) {
        debugPrint('[LIVE-STREAM] Stop stream error: $e');
      }
    }
  }

  void _logCandidateLiveAudit(
    CurrencyInferenceResult result,
    TrackerUpdateResult trackerResult,
  ) {
    _liveAuditFrameIndex++;
    final hasAny =
        result.detections.isNotEmpty ||
        trackerResult.activeDetections.isNotEmpty;
    if (!hasAny) {
      _liveAuditEmptyStreak++;
      if (_liveAuditEmptyStreak % 15 != 1) return;
    } else {
      _liveAuditEmptyStreak = 0;
    }
    final rawDesc = result.detections
        .map(
          (d) =>
              '${d.denomination}:${d.confidence.toStringAsFixed(2)}(m=${d.classMargin.toStringAsFixed(2)},${d.confirmationState.name})',
        )
        .join(',');
    final trkDesc = trackerResult.activeDetections
        .map(
          (d) =>
              '${d.denomination}:${d.confidence.toStringAsFixed(2)}[${d.confirmationState.name},v=${d.framesVisible}]',
        )
        .join(',');
    final a = trackerResult.assessment;
    debugPrint(
      '[LIVE-AUDIT] #$_liveAuditFrameIndex ${result.imageWidth}x${result.imageHeight} '
      't=${result.totalTimeMs.toStringAsFixed(0)}ms(c=${result.coinInferenceTimeMs.toStringAsFixed(0)},n=${result.banknoteInferenceTimeMs.toStringAsFixed(0)}) '
      'raw=[$rawDesc] trk=[$trkDesc] '
      'status=${a.status.name} isConf=${a.isTotalConfirmed} confTot=${a.confirmedTotalRupees} visSum=${a.visibleDetectedSumRupees} '
      'reasons=${a.reasons.toList()} speech="${a.spokenMessage}"',
    );
  }

  /// Continuous assistive haptic feedback: Vibrates gently while currency is visible
  /// in the camera feed until it is recognized and speech begins.
  void _stopHapticGuidance() {
    if (_isGuidanceVibrating) {
      _isGuidanceVibrating = false;
      _hapticGuidanceTimer?.cancel();
      _hapticGuidanceTimer = null;
    }
  }

  void _updateHapticGuidance(
    CurrencySafetyAssessment assessment,
    List<CurrencyDetection> activeDetections,
  ) {
    if (_isMuted || _isSpeakingOcr || _isOcrRunning) {
      _stopHapticGuidance();
      return;
    }

    final hasVisibleCurrency = activeDetections.isNotEmpty &&
        assessment.status != AnnouncementSafetyStatus.empty;
    final names = activeDetections.map((d) => d.denomination).toList()..sort();
    final String currentSignature = names.join(',');
    final bool isAlreadyRecognized = _lastSpokenSignature.isNotEmpty && _lastSpokenSignature == currentSignature;
    final isConfirmedOrSpeaking = _isSpeakingCurrency || isAlreadyRecognized;

    if (hasVisibleCurrency && !isConfirmedOrSpeaking) {
      if (!_isGuidanceVibrating) {
        _isGuidanceVibrating = true;
        _hapticGuidanceTimer?.cancel();
        HapticFeedback.mediumImpact();
        _hapticGuidanceTimer = Timer.periodic(
          const Duration(milliseconds: 250),
          (timer) {
            if (!_isGuidanceVibrating) {
              timer.cancel();
            } else {
              HapticFeedback.lightImpact();
            }
          },
        );
      }
    } else {
      _stopHapticGuidance();
    }
  }

  /// Real-time speech announcement for detected currency items with safety gating
  void _handleRealtimeSpeech(CurrencySafetyAssessment assessment) {
    if (_isMuted || _isSpeakingOcr || _isOcrRunning || _isSpeakingCurrency) {
      return;
    }

    final bool hasSpecialStatus =
        assessment.reasons.contains('INVALID_CURRENCY_DETECTED') ||
        assessment.reasons.contains('FOREIGN_CURRENCY_DETECTED') ||
        assessment.reasons.contains('UNRECOGNISED_CURRENCY') ||
        assessment.reasons.contains('IDENTITY_UNKNOWN');
    final detections = assessment.screenedDetections;
    if ((detections.isEmpty && !hasSpecialStatus) ||
        assessment.status == AnnouncementSafetyStatus.empty) {
      _stopHapticGuidance();
      _pendingSignature = '';
      _pendingCount = 0;
      _lastSpokenSignature = '';
      return;
    }

    if (assessment.spokenMessage.isEmpty) {
      return;
    }

    final now = DateTime.now();

    // 1. CONFIRMED CURRENCY ANNOUNCEMENT
    if (assessment.isTotalConfirmed) {
      final names = detections.map((d) => '${d.denomination}:confirmed').toList()..sort();
      final String signature = 'CONFIRMED|${names.join(',')}';
      const int requiredFrames = 2;
      const int reannounceSec = 5;

      if (signature != _lastSpokenSignature) {
        if (signature == _pendingSignature) {
          _pendingCount++;
        } else {
          _pendingSignature = signature;
          _pendingCount = 1;
        }

        if (_pendingCount >= requiredFrames) {
          _speakCurrencyAssessment(assessment);
          _lastSpokenSignature = signature;
          _lastSpokenTime = now;
        }
      } else {
        if (now.difference(_lastSpokenTime).inSeconds >= reannounceSec) {
          _speakCurrencyAssessment(assessment);
          _lastSpokenTime = now;
        }
      }
      return;
    }

    // 2. UNCONFIRMED / DIFFICULT TO DENOMINATE GUIDANCE ANNOUNCEMENT
    // Spoken when currency is visible but cannot be safely confirmed (covered, conflict, or unclear angle).
    // Tells the blind user what is happening instead of leaving them in silence!
    final String signature = 'GUIDANCE|${assessment.status.name}|${assessment.spokenMessage}';
    const int requiredFrames = 3;
    const int reannounceSec = 6;

    if (signature != _lastSpokenSignature) {
      if (signature == _pendingSignature) {
        _pendingCount++;
      } else {
        _pendingSignature = signature;
        _pendingCount = 1;
      }

      if (_pendingCount >= requiredFrames) {
        _speakCurrencyAssessment(assessment);
        _lastSpokenSignature = signature;
        _lastSpokenTime = now;
      }
    } else {
      if (now.difference(_lastSpokenTime).inSeconds >= reannounceSec) {
        _speakCurrencyAssessment(assessment);
        _lastSpokenTime = now;
      }
    }
  }

  Future<void> _speakCurrencyAssessment(
    CurrencySafetyAssessment assessment,
  ) async {
    final bool hasSpecialStatus =
        assessment.reasons.contains('INVALID_CURRENCY_DETECTED') ||
        assessment.reasons.contains('FOREIGN_CURRENCY_DETECTED') ||
        assessment.reasons.contains('UNRECOGNISED_CURRENCY') ||
        assessment.reasons.contains('IDENTITY_UNKNOWN');
    if ((assessment.screenedDetections.isEmpty && !hasSpecialStatus) ||
        _isMuted ||
        _showLanguagePopup ||
        _isSpeakingOcr ||
        _isOcrRunning) {
      return;
    }

    if (_isSpeakingCurrency &&
        DateTime.now().difference(_lastSpokenTime).inSeconds < 4) {
      return;
    }

    _stopHapticGuidance();
    _isSpeakingCurrency = true;
    _lastSpokenTime = DateTime.now();
    HapticFeedback.lightImpact();

    try {
      await _speechService.speakCurrencyAssessment(
        assessment,
        language: _currencyLanguage,
        interrupt: true,
      );
    } catch (e) {
      debugPrint('[TTS-CURRENCY] Speak error: $e');
    } finally {
      _isSpeakingCurrency = false;
    }
  }

  /// High-resolution Currency Snapshot Recognition
  Future<void> _triggerCurrencyCaptureRecognition() async {
    final camera = _cameraController;
    if (!_cameraReady || camera == null || !camera.value.isInitialized) return;
    if (_isCurrencyCapturing || !_currencyModelReady) return;

    HapticFeedback.heavyImpact();
    setState(() {
      _isCurrencyCapturing = true;
      _showCaptureResult = true;
    });

    try {
      await _stopLiveStream();
      final XFile photo = await camera.takePicture();
      if (_isTorchOn) {
        try {
          await camera.setFlashMode(FlashMode.torch);
        } catch (e) {
          debugPrint('[AUTO-FLASH] Re-assert torch after currency capture error: $e');
        }
      }
      final imageBytes = await photo.readAsBytes();
      unawaited(_startLiveStream());

      final result = await _currencyModelService.runImageInference(
        imageBytes,
        source: 'Live camera capture',
      );

      final assessment = CurrencySafetyEvaluator.evaluate(
        result.detections,
        candidateMode: _currencyModelService.isCandidateMode,
        hasUncertainObjectCount:
            result.totalStatus == 'conflicting' &&
            result.conflictingNoteCount == 0,
        extraReasons: result.uncertaintyReasons.toSet(),
        imageWidth: result.imageWidth,
        imageHeight: result.imageHeight,
      );

      if (!mounted) return;

      setState(() {
        _lastCaptureResult = result;
        _lastCaptureSafetyAssessment = assessment;
      });

      final bool hasSpecialStatus =
          assessment.reasons.contains('INVALID_CURRENCY_DETECTED') ||
          assessment.reasons.contains('FOREIGN_CURRENCY_DETECTED') ||
          assessment.reasons.contains('UNRECOGNISED_CURRENCY') ||
          assessment.reasons.contains('IDENTITY_UNKNOWN');
      if (assessment.status == AnnouncementSafetyStatus.empty && !hasSpecialStatus) {
        HapticFeedback.vibrate();
        await _speechService.speakText(
          CurrencySpeechFormatter.formatEmptyPrompt(_currencyLanguage),
          language: _currencyLanguage,
        );
      } else {
        HapticFeedback.mediumImpact();
        debugPrint(
          '[TTS-CAPTURE] (${assessment.status.name}) lang=$_currencyLanguage',
        );
        await _speechService.speakCurrencyAssessment(
          assessment,
          language: _currencyLanguage,
          interrupt: true,
        );
      }
    } catch (e) {
      debugPrint('[CURRENCY-CAPTURE] Error: $e');
      if (mounted) _startLiveStream();
    } finally {
      if (mounted) {
        setState(() => _isCurrencyCapturing = false);
      }
    }
  }

  /// OCR Text Recognition Trigger (manual shutter, one-shot automatic entry, or double-press reread).
  Future<void> _triggerOcrTextRecognition({
    int? expectedModeGen,
    bool announceEntry = false,
    bool isReread = false,
  }) async {
    // If camera is still initializing (e.g. app just launched or resumed), wait briefly
    for (int i = 0;
        i < 25 &&
            (!_cameraReady ||
                _cameraController == null ||
                !_cameraController!.value.isInitialized);
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }

    final camera = _cameraController;
    if (!_cameraReady || camera == null || !camera.value.isInitialized) {
      debugPrint('[OCR-AUTO] Camera not ready for capture.');
      _lastTriggeredOcrGen = -1;
      if (!_isMuted) {
        unawaited(
          _speechService.speakText(
            'Camera is not ready. Please try again.',
            language: 'en-IN',
          ),
        );
      }
      return;
    }

    if (expectedModeGen != null) {
      if (_lastTriggeredOcrGen == expectedModeGen) return;
      if (!_modeController.isOcrGenerationValid(expectedModeGen)) return;
    } else if (_isSpeakingOcr) {
      HapticFeedback.selectionClick();
      await _speechService.stop();
      if (mounted) setState(() => _isSpeakingOcr = false);
      return;
    }

    // Ensure OCR models are ready before proceeding
    if (!_ocrModelReady) {
      debugPrint('[OCR-AUTO] OCR model initializing; awaiting loadModels()...');
      try {
        await _ocrService.loadModels();
        if (mounted) {
          setState(() => _ocrModelReady = true);
        }
      } catch (e) {
        debugPrint('[OCR-AUTO] Load failed: $e');
        _lastTriggeredOcrGen = -1;
        if (!_isMuted) {
          unawaited(
            _speechService.speakText(
              'Text recognition is loading. Please try again.',
              language: 'en-IN',
            ),
          );
        }
        return;
      }
    }

    if (expectedModeGen != null) {
      _lastTriggeredOcrGen = expectedModeGen;
    }

    if (!isReread && _isOcrRunning) return;

    final int captureGen = expectedModeGen ?? _modeController.modeGenerationId;
    _currencyInferenceEpoch++;

    if (isReread) {
      debugPrint(
        '[OCR-REREAD] Interrupting previous OCR/speech for fresh capture (gen=$captureGen)',
      );
      await _speechService.stop();
      if (mounted) setState(() => _isSpeakingOcr = false);
      if (!mounted || !_modeController.isOcrGenerationValid(captureGen)) return;
    }

    HapticFeedback.heavyImpact();
    setState(() {
      _isOcrRunning = true;
      _showOcrSheet = true;
    });

    if (!_isMuted) {
      unawaited(
        _speechService.speakText(
          announceEntry ? 'OCR mode. Reading text' : 'Reading text',
          language: 'en-IN',
          interrupt: true,
        ),
      );
    }

    try {
      await _stopLiveStream();
      // Wait for any in-flight currency frame or previous takePicture to settle
      for (int i = 0; i < 30 && (_isProcessingFrame || _isTakingPicture); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      // CameraX HAL stabilization delay to ensure ImageAnalysis buffers are detached
      await Future<void>.delayed(const Duration(milliseconds: 100));

      if (!mounted || !_modeController.isOcrGenerationValid(captureGen)) return;

      debugPrint(
        '[OCR-AUTO] Capturing fresh frame (gen=$captureGen reread=$isReread)...',
      );
      _isTakingPicture = true;
      XFile? photo;
      Object? lastCaptureError;
      for (int attempt = 0; attempt < 3; attempt++) {
        if (!mounted || !_modeController.isOcrGenerationValid(captureGen)) return;
        try {
          photo = await camera.takePicture();
          if (photo != null) break;
        } catch (e) {
          lastCaptureError = e;
          debugPrint('[OCR-AUTO] takePicture attempt $attempt failed: $e');
          if (attempt < 2) {
            await Future<void>.delayed(const Duration(milliseconds: 150));
          }
        }
      }
      _isTakingPicture = false;

      if (photo == null) {
        throw Exception('takePicture failed after 3 attempts: $lastCaptureError');
      }

      if (_isTorchOn) {
        try {
          await camera.setFlashMode(FlashMode.torch);
        } catch (e) {
          debugPrint('[AUTO-FLASH] Re-assert torch after OCR capture error: $e');
        }
      }
      final imageBytes = await photo.readAsBytes();
      unawaited(_startLiveStream());

      if (!mounted || !_modeController.isOcrGenerationValid(captureGen)) return;

      final result = await _ocrService.processImage(
        imageBytes,
        preferredLanguage: _languageController.selectedCode,
      );

      if (!mounted || !_modeController.isOcrGenerationValid(captureGen)) {
        debugPrint(
          '[OCR-AUTO] Discarded stale OCR result (gen=$captureGen current=${_modeController.modeGenerationId})',
        );
        return;
      }

      setState(() {
        _lastOcrResult = result;
      });

      final verifiedLines = result.lines
          .where(
            (l) =>
                l.text.trim().isNotEmpty &&
                !(l.isLanguageUncertain && l.confidence < 0.58),
          )
          .toList();

      if (result.lines.isEmpty) {
        HapticFeedback.vibrate();
        if (!_isMuted) {
          setState(() => _isSpeakingOcr = true);
          await _speechService.speakText(
            'No readable text detected. Please hold closer.',
            language: 'en-IN',
          );
          if (mounted && _modeController.isOcrGenerationValid(captureGen)) {
            setState(() => _isSpeakingOcr = false);
          }
        }
      } else if (verifiedLines.isEmpty) {
        HapticFeedback.vibrate();
        if (!_isMuted) {
          setState(() => _isSpeakingOcr = true);
          await _speechService.speakText(
            'Text is too unclear to read reliably. Please hold steady in better lighting.',
            language: 'en-IN',
          );
          if (mounted && _modeController.isOcrGenerationValid(captureGen)) {
            setState(() => _isSpeakingOcr = false);
          }
        }
      } else {
        HapticFeedback.mediumImpact();
        if (!_isMuted) {
          setState(() => _isSpeakingOcr = true);
          await _speechService.speakOcrLines(
            result.lines,
            sceneSummary: result.sceneSummary,
          );
          if (mounted && _modeController.isOcrGenerationValid(captureGen)) {
            if (verifiedLines.length < result.lines.length) {
              await _speechService.speakText(
                'Some unclear text could not be read reliably.',
                language: 'en-IN',
                interrupt: false,
              );
            }
          }
          if (mounted && _modeController.isOcrGenerationValid(captureGen)) {
            setState(() => _isSpeakingOcr = false);
          }
        }
      }
    } catch (e) {
      debugPrint('[OCR] Trigger failed: $e');
      _lastTriggeredOcrGen = -1;
      if (mounted && _modeController.isOcrGenerationValid(captureGen)) {
        setState(() {
          _isSpeakingOcr = false;
          _isOcrRunning = false;
        });
        if (!_isMuted) {
          unawaited(
            _speechService.speakText(
              'Could not read text. Please tap the screen to try again.',
              language: 'en-IN',
            ),
          );
        }
        _startLiveStream();
      }
    } finally {
      if (mounted && captureGen == _modeController.modeGenerationId) {
        setState(() => _isOcrRunning = false);
      }
    }
  }

  Future<bool> _setTorchFromAutoController(bool enabled) async {
    final expectedMode = enabled ? FlashMode.torch : FlashMode.off;
    final controller = _cameraController;
    if (controller != null && controller.value.isInitialized) {
      try {
        await controller.setFlashMode(expectedMode);
        final confirmed = controller.value.flashMode == expectedMode;
        if (confirmed && mounted) {
          setState(() => _isTorchOn = enabled);
        }
        return confirmed;
      } catch (e) {
        debugPrint('[AUTO-FLASH] CameraController setFlashMode($enabled) error: $e');
        return false;
      }
    }
    if (!enabled) {
      try {
        const channel = MethodChannel('vision_assistant/flashlight_sensor');
        final ok = await channel.invokeMethod<bool>(
          'setTorchFallback',
          {'enabled': false},
        );
        if (mounted) {
          setState(() => _isTorchOn = false);
        }
        return ok == true;
      } catch (e) {
        debugPrint('[AUTO-FLASH] setTorchFallback(false) error: $e');
      }
    }
    return false;
  }

  Future<void> _toggleTorch() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    try {
      final nextOn = !_isTorchOn;
      final nextMode = nextOn ? FlashMode.torch : FlashMode.off;
      await controller.setFlashMode(nextMode);
      HapticFeedback.selectionClick();
      _autoFlashlightController.setManualTorchState(nextOn);
      if (mounted) {
        setState(() => _isTorchOn = nextOn);
      }
    } catch (e) {
      debugPrint('[TORCH] Error: $e');
    }
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
    });
    if (_isMuted) {
      _speechService.stop();
    }
    HapticFeedback.selectionClick();
  }

  void _syncOcrModeToNative(bool active) {
    unawaited(
      _hardwareKeysChannel
          .invokeMethod('setOcrModeActive', {'active': active})
          .catchError((_) {}),
    );
  }

  void _syncPopupStateToNative(bool open) {
    unawaited(
      _hardwareKeysChannel
          .invokeMethod('setLanguagePopupOpen', {'open': open})
          .catchError((_) {}),
    );
  }

  void _resetLanguagePopupTimer() {
    _modeController.resetSelectorTimer();
  }

  void _toggleLanguagePopup() {
    if (_showLanguagePopup) {
      _closeLanguagePopup(announce: true);
    } else {
      _openLanguagePopup();
    }
  }

  void _openLanguagePopup() {
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    _currencyInferenceEpoch++;
    _isSpeakingCurrency = false;
    setState(() => _showLanguagePopup = true);
    _syncPopupStateToNative(true);
    _speechService.setSelectorOpen(true);
    _modeController.openSelector();
    debugPrint(
      '[SELECTOR-TIMING] opened timeoutMs=4000 (mode=${_isCurrencyMode ? "currency" : "ocr"})',
    );
    debugPrint(
      '[CURRENCY-PAUSE] Language selector opened: currency inference paused (mode=${_isCurrencyMode ? "currency" : "ocr"})',
    );
    if (!_isMuted) {
      unawaited(
        _speechService.speakText(
          'Language selector',
          language: 'en-IN',
          interrupt: true,
        ),
      );
    }
  }

  void _closeLanguagePopup({bool announce = false}) {
    final openedAt = _modeController.selectorOpenedAt;
    _modeController.closeSelector();
    if (!mounted) return;
    if (!_showLanguagePopup) return;
    final visibleMs = openedAt != null
        ? DateTime.now().difference(openedAt).inMilliseconds
        : 0;
    setState(() => _showLanguagePopup = false);
    _syncPopupStateToNative(false);
    _speechService.setSelectorOpen(false);
    HapticFeedback.selectionClick();
    debugPrint('[SELECTOR-TIMING] closed visibleMs=$visibleMs');
    debugPrint(
      '[CURRENCY-RESUME] Language selector closed: restored ${_isCurrencyMode ? "currency" : "ocr"} mode (lang=$_currencyLanguage)',
    );
    if (announce && !_isMuted && !_speechService.isSpeaking) {
      unawaited(
        _speechService.speakText(
          'Language selector closed',
          language: 'en-IN',
          interrupt: false,
        ),
      );
    }
  }

  void _syncCurrencyRegionForLanguage(String code) {
    final changed = _currencyRegionController.updateForLanguage(code);
    if (changed) {
      _currencyInferenceEpoch++;
      _currencyTracker.reset();
      _currentDetections = const [];
      _currentSafetyAssessment = null;
      _showCaptureResult = false;
      debugPrint(
        '[CURRENCY-REGION] Switched to ${_currencyRegionController.region.name.toUpperCase()} '
        '(symbol=${_currencyRegionController.symbol}, regionEpoch=${_currencyRegionController.regionEpoch})',
      );
    }
  }

  void _navigateLanguageUp({int keyAgeMs = 0}) {
    final sw = Stopwatch()..start();
    final selected = _languageController.navigateUp(
      isMuted: _isMuted,
      keyAgeMs: keyAgeMs,
    );
    setState(() {
      _currencyLanguage = selected.code;
      _syncCurrencyRegionForLanguage(selected.code);
    });
    sw.stop();
    HapticFeedback.selectionClick();
    _resetLanguagePopupTimer();
    debugPrint(
      '[TTS-SEL-UI] dir=up lang=${selected.code} gen=${_languageController.announcementGenerationId} keyAgeMs=$keyAgeMs stateUpdateMs=${sw.elapsedMilliseconds}',
    );
  }

  void _navigateLanguageDown({int keyAgeMs = 0}) {
    final sw = Stopwatch()..start();
    final selected = _languageController.navigateDown(
      isMuted: _isMuted,
      keyAgeMs: keyAgeMs,
    );
    setState(() {
      _currencyLanguage = selected.code;
      _syncCurrencyRegionForLanguage(selected.code);
    });
    sw.stop();
    HapticFeedback.selectionClick();
    _resetLanguagePopupTimer();
    debugPrint(
      '[TTS-SEL-UI] dir=down lang=${selected.code} gen=${_languageController.announcementGenerationId} keyAgeMs=$keyAgeMs stateUpdateMs=${sw.elapsedMilliseconds}',
    );
  }

  String _currentCurrencyLanguageLabel() {
    return kCurrencyLanguages
        .firstWhere(
          (l) => l.code == _currencyLanguage,
          orElse: () => kCurrencyLanguages.first,
        )
        .label;
  }

  void _setMode(bool isCurrency) {
    if (_isCurrencyMode == isCurrency) {
      if (!isCurrency) {
        // Tapping OCR mode while already in OCR mode initiates an immediate fresh capture & read
        unawaited(_triggerOcrTextRecognition(isReread: true));
      }
      return;
    }
    HapticFeedback.mediumImpact();
    _currencyInferenceEpoch++;
    unawaited(_speechService.stop());
    setState(() {
      _isCurrencyMode = isCurrency;
      _currentDetections = const [];
      _currentSafetyAssessment = null;
      _showCaptureResult = false;
      _showOcrSheet = !isCurrency;
      _isSpeakingCurrency = false;
      _lastTriggeredOcrGen = -1;
      _isOcrRunning = false;
      _isSpeakingOcr = false;
      if (isCurrency) {
        _lastOcrResult = null;
      }
    });
    _currencyTracker.reset();

    final gen = _modeController.setMode(isCurrency, autoTriggerOcr: true);
    _syncOcrModeToNative(!isCurrency);
    unawaited(
      _autoFlashlightController.startMonitoring(
        isCurrency ? RecognitionTorchMode.currency : RecognitionTorchMode.ocr,
      ),
    );
    debugPrint(
      '[MODE-SWITCH] mode=${isCurrency ? "currency" : "ocr"} gen=$gen',
    );

    if (isCurrency && !_isMuted) {
      unawaited(
        _speechService.speakText(
          'Currency mode activated',
          language: 'en-IN',
          interrupt: true,
        ),
      );
    }
  }

  void _dismissOcrSheet() {
    if (_isSpeakingOcr) {
      _speechService.stop();
    }
    setState(() {
      _showOcrSheet = false;
      _lastOcrResult = null;
    });
    HapticFeedback.selectionClick();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _closeLanguagePopup(announce: false);
      unawaited(
        _autoFlashlightController.stopMonitoring(
          turnOffIfOwned: true,
          announce: !_isMuted,
        ),
      );
      _stopLiveStream();
      _cameraController?.dispose();
      _cameraController = null;
      setState(() {
        _cameraReady = false;
        _isTorchOn = false;
      });
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
      unawaited(_handleResumedUpdateCheck());
    }
  }

  @override
  void dispose() {
    unawaited(_appUpdateService.dispose());
    unawaited(_autoFlashlightController.dispose());
    _modeController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _stopLiveStream();
    _cameraController?.dispose();
    unawaited(_speechService.dispose());
    unawaited(_currencyModelService.dispose());
    unawaited(_ocrService.dispose());
    super.dispose();
  }

  // ----------------------------------------------------------
  // REDESIGNED MODERN FROSTED-GLASS UI
  // ----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final controller = _cameraController;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. FULLSCREEN EDGE-TO-EDGE CAMERA PREVIEW
          if (_cameraReady &&
              controller != null &&
              controller.value.isInitialized)
            LayoutBuilder(
              builder: (context, constraints) {
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) =>
                      _handleTapToFocus(details, constraints),
                  child: SizedBox.expand(
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width:
                            controller.value.previewSize?.height ?? size.width,
                        height:
                            controller.value.previewSize?.width ?? size.height,
                        child: CameraPreview(controller),
                      ),
                    ),
                  ),
                );
              },
            )
          else
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2.5,
                  ),
                  SizedBox(height: 18),
                  Text(
                    'Initializing camera...',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),

          // 2. LIVE CURRENCY BOUNDING BOX OVERLAYS (CURRENCY MODE)
          if (_isCurrencyMode &&
              _currentDetections.isNotEmpty &&
              !_isOcrRunning)
            Positioned.fill(
              child: CustomPaint(
                painter: BanknoteOverlayPainter(
                  detections: _currentDetections,
                  imageWidth: _feedWidth,
                  imageHeight: _feedHeight,
                ),
              ),
            ),

          // 3. TOP FROSTED STATUS BAR
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Torch Button
                    _frostedIconButton(
                      icon: _isTorchOn
                          ? Icons.flash_on_rounded
                          : Icons.flash_off_rounded,
                      color: _isTorchOn
                          ? const Color(0xFFFFD54F)
                          : Colors.white,
                      active: _isTorchOn,
                      semanticLabel: _isTorchOn
                          ? 'Flashlight on'
                          : 'Flashlight off',
                      onPressed: _toggleTorch,
                    ),

                    // Central Status Badge
                    ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.15),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _isCurrencyMode
                                      ? (_currencyModelReady
                                            ? (_currentDetections.isNotEmpty
                                                  ? const Color(0xFF00E676)
                                                  : const Color(0xFFFFD600))
                                            : Colors.orangeAccent)
                                      : (_ocrModelReady
                                            ? const Color(0xFF29B6F6)
                                            : Colors.orangeAccent),
                                  boxShadow: [
                                    BoxShadow(
                                      color:
                                          (_isCurrencyMode
                                                  ? (_currentDetections.isNotEmpty
                                                        ? const Color(0xFF00E676)
                                                        : const Color(0xFFFFD600))
                                                  : const Color(0xFF29B6F6))
                                              .withValues(alpha: 0.6),
                                      blurRadius: 6,
                                      spreadRadius: 1,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _isOcrRunning
                                    ? 'READING TEXT...'
                                    : (_isCurrencyMode
                                          ? (_currentDetections.isNotEmpty
                                                ? 'DETECTED (${_currentDetections.length})'
                                                : 'Offline')
                                          : 'DOCUMENT OCR'),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    // Currency Language Selector & Audio Mute Button
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _frostedIconButton(
                          icon: Icons.translate_rounded,
                          color: _currencyLanguage != 'en-IN'
                              ? const Color(0xFF00E676)
                              : Colors.white,
                          active:
                              _showLanguagePopup ||
                              _currencyLanguage != 'en-IN',
                          semanticLabel:
                              'Currency language ${_currentCurrencyLanguageLabel()}',
                          onPressed: _toggleLanguagePopup,
                        ),
                        const SizedBox(width: 8),
                        _frostedIconButton(
                          icon: _isMuted
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                          color: _isMuted
                              ? const Color(0xFFFF5252)
                              : Colors.white,
                          active: _isMuted,
                          semanticLabel: _isMuted
                              ? 'Audio muted'
                              : 'Audio enabled',
                          onPressed: _toggleMute,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 4. FLOATING CURRENCY TOTAL BANNER (CURRENCY MODE WITH DETECTIONS)
          if (_isCurrencyMode &&
              _currentDetections.isNotEmpty &&
              !_isOcrRunning)
            Positioned(
              top: MediaQuery.of(context).padding.top + 60,
              left: 16,
              right: 16,
              child: _buildCurrencyBanner(),
            ),

          // 5. CURRENCY SNAPSHOT CAPTURE RESULT CARD
          if (_showCaptureResult)
            Positioned(
              top: MediaQuery.of(context).padding.top + 60,
              left: 16,
              right: 16,
              child: _buildCurrencyCaptureCard(),
            ),

          // 6. EXTRACTED OCR TEXT PANEL
          if (_showOcrSheet)
            Positioned(
              top: MediaQuery.of(context).padding.top + 60,
              left: 16,
              right: 16,
              child: _buildOcrResultCard(),
            ),

          // 6b. FROSTED-GLASS CURRENCY LANGUAGE SELECTOR POPUP (VOLUME-KEY CONTROLLED)
          if (_showLanguagePopup)
            Positioned.fill(
              child: IgnorePointer(
                ignoring: false,
                child: Center(child: _buildLanguageSelectorPopup()),
              ),
            ),

          // 7. BOTTOM CONTROLS: MODE SELECTOR + SHUTTER + ACCESSIBILITY HINT
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12, left: 20, right: 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Sleek Segmented Mode Selector
                    _buildModeSelector(),
                    const SizedBox(height: 16),

                    // Shutter Button
                    Semantics(
                      label: _isCurrencyMode
                          ? 'Take snapshot of currency'
                          : 'Read text document',
                      button: true,
                      child: GestureDetector(
                        onTap: () {
                          if (_isCurrencyMode) {
                            _triggerCurrencyCaptureRecognition();
                          } else {
                            _triggerOcrTextRecognition();
                          }
                        },
                        child: ClipOval(
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                            child: Container(
                              width: 76,
                              height: 76,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: (_isCurrencyCapturing || _isOcrRunning)
                                    ? Colors.white.withValues(alpha: 0.3)
                                    : Colors.white.withValues(alpha: 0.15),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.4),
                                  width: 2.5,
                                ),
                              ),
                              child: Center(
                                child: (_isCurrencyCapturing || _isOcrRunning)
                                    ? const SizedBox(
                                        width: 28,
                                        height: 28,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                          color: Colors.white,
                                        ),
                                      )
                                    : Container(
                                        width: 56,
                                        height: 56,
                                        decoration: const BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: Colors.white,
                                        ),
                                        child: Icon(
                                          _isCurrencyMode
                                              ? Icons.camera_alt_rounded
                                              : Icons.document_scanner_rounded,
                                          color: const Color(0xFF1E1E1E),
                                          size: 28,
                                        ),
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Accessibility Voice Guidance Note
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.12),
                            ),
                          ),
                          child: Text(
                            _isCurrencyMode
                                ? 'Auto-Detecting · Hold Vol+ 2s for OCR · Vol- 2s for Voice'
                                : 'Tap Shutter to Read Text · Hold Vol+ 2s for Currency',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------
  // WIDGET HELPERS
  // ----------------------------------------------------------

  Widget _frostedIconButton({
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
    required String semanticLabel,
    bool active = false,
  }) {
    return Semantics(
      label: semanticLabel,
      button: true,
      child: GestureDetector(
        onTap: onPressed,
        child: ClipOval(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active
                    ? Colors.white.withValues(alpha: 0.25)
                    : Colors.black.withValues(alpha: 0.45),
                border: Border.all(
                  color: active
                      ? Colors.white.withValues(alpha: 0.4)
                      : Colors.white.withValues(alpha: 0.15),
                ),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeSelector() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _modeButton(
                icon: Icons.currency_rupee_rounded,
                title: 'Currency',
                isSelected: _isCurrencyMode,
                onTap: () => _setMode(true),
              ),
              _modeButton(
                icon: Icons.document_scanner_rounded,
                title: 'Text OCR',
                isSelected: !_isCurrencyMode,
                onTap: () => _setMode(false),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modeButton({
    required IconData icon,
    required String title,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? const Color(0xFF151515) : Colors.white70,
            ),
            const SizedBox(width: 6),
            Text(
              title,
              style: TextStyle(
                color: isSelected ? const Color(0xFF151515) : Colors.white70,
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLanguageSelectorPopup() {
    return Semantics(
      label:
          'Currency voice language selector. ${_currentCurrencyLanguageLabel()} selected. Use Volume Up or Down to select.',
      liveRegion: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            width: 236,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.68),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.record_voice_over_rounded,
                      color: Colors.white70,
                      size: 15,
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'Currency Voice',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                for (final lang in kCurrencyLanguages) ...[
                  _buildLanguageOptionRow(
                    label: lang.label,
                    selected: _currencyLanguage == lang.code,
                  ),
                  const SizedBox(height: 4),
                ],
                const SizedBox(height: 4),
                const Text(
                  'Use Volume Up/Down · Auto-closes in 4s',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white60,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLanguageOptionRow({
    required String label,
    required bool selected,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: selected
            ? Colors.white.withValues(alpha: 0.22)
            : Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected
              ? const Color(0xFF00E676).withValues(alpha: 0.75)
              : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : Colors.white70,
                fontSize: 14,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          if (selected)
            const Icon(
              Icons.check_circle_rounded,
              color: Color(0xFF00E676),
              size: 16,
            ),
        ],
      ),
    );
  }

  Widget _buildCurrencyBanner() {
    final assessment =
        _currentSafetyAssessment ??
        CurrencySafetyEvaluator.evaluate(
          _currentDetections,
          candidateMode: _currencyModelService.isCandidateMode,
        );
    final bool isConfirmed = assessment.isTotalConfirmed;
    final int? confirmedTotal = assessment.confirmedTotalRupees;
    final Color accentColor = isConfirmed
        ? const Color(0xFF00E676)
        : (assessment.conflictingCount > 0
              ? const Color(0xFFFF5252)
              : const Color(0xFFFFD54F));

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: accentColor.withValues(alpha: 0.45)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      assessment.bannerHeadline,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      assessment.bannerSubtitle,
                      style: TextStyle(
                        color: accentColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: accentColor.withValues(alpha: 0.5)),
                ),
                child: Text(
                  isConfirmed && confirmedTotal != null
                      ? '${_currencyRegionController.symbol}$confirmedTotal'
                      : 'CHECK',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCurrencyCaptureCard() {
    final result = _lastCaptureResult;
    final assessment = _lastCaptureSafetyAssessment;
    final bool isConfirmed = assessment?.isTotalConfirmed ?? true;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          constraints: const BoxConstraints(maxHeight: 320),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.payments_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isCurrencyCapturing
                            ? 'ANALYZING CURRENCY...'
                            : 'SNAPSHOT RECOGNITION',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ],
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.white70,
                      size: 20,
                    ),
                    onPressed: () => setState(() => _showCaptureResult = false),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (_isCurrencyCapturing)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                )
              else if (result == null || result.detections.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'No currency detected. Please hold notes or coins steady under good lighting.',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      ...((assessment?.screenedDetections ?? result.detections).map((
                        d,
                      ) {
                        final tag = _currencyModelService.isCandidateMode
                            ? ' [${d.confirmationState.name.toUpperCase()}]'
                            : '';
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Flexible(
                                child: Text(
                                  '${CurrencyModelService.formatItemDisplayName(d.denomination, d.value)}$tag',
                                  style: TextStyle(
                                    color: d.isConfirmed
                                        ? Colors.white
                                        : (d.isConflicting
                                              ? const Color(0xFFFF8A80)
                                              : const Color(0xFFFFD54F)),
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                '${(d.confidence * 100).toStringAsFixed(1)}%',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        );
                      })),
                      const Divider(color: Colors.white24, height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Count: ${result.detections.length} items',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                          Text(
                            !_currencyModelService.isCandidateMode
                                ? 'TOTAL: ${_currencyRegionController.symbol}${result.totalValue}'
                                : (isConfirmed &&
                                          (assessment?.confirmedTotalRupees ??
                                                  result.totalValue) >
                                              0
                                      ? 'CONFIRMED: ${_currencyRegionController.symbol}${assessment?.confirmedTotalRupees ?? result.totalValue}'
                                      : 'UNCONFIRMED — SPREAD NOTES'),
                            style: TextStyle(
                              color: isConfirmed
                                  ? const Color(0xFF00E676)
                                  : const Color(0xFFFFD54F),
                              fontSize: isConfirmed ? 17 : 13,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOcrResultCard() {
    final result = _lastOcrResult;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          constraints: const BoxConstraints(maxHeight: 380),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.text_snippet_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isOcrRunning
                            ? 'READING DOCUMENT...'
                            : (result != null && result.isNotEmpty
                                  ? 'DOCUMENT TEXT (${result.lines.length} lines)'
                                  : 'TEXT RECOGNITION'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ],
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.white70,
                      size: 22,
                    ),
                    onPressed: _dismissOcrSheet,
                  ),
                ],
              ),
              const SizedBox(height: 10),

              if (_isOcrRunning)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(width: 14),
                        Text(
                          'Reading text in front of camera...',
                          style: TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                )
              else if (result == null || result.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Text(
                    'No text detected. Please hold document or medicine label closer.',
                    style: TextStyle(color: Color(0xFFFFD54F), fontSize: 14),
                  ),
                )
              else ...[
                Flexible(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      result.fullText,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        height: 1.45,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${result.durationMs}ms',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Copy Button
                        TextButton.icon(
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(text: result.fullText),
                            );
                            HapticFeedback.selectionClick();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Text copied to clipboard'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                          icon: const Icon(
                            Icons.copy_rounded,
                            color: Colors.white70,
                            size: 16,
                          ),
                          label: const Text(
                            'COPY',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),

                        // Speak / Stop Button
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            decoration: BoxDecoration(
                              color: _isSpeakingOcr
                                  ? const Color(0xFFFF5252)
                                        .withValues(alpha: 0.3)
                                  : Colors.white.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _isSpeakingOcr
                                    ? const Color(0xFFFF5252)
                                    : Colors.white.withValues(alpha: 0.3),
                              ),
                            ),
                            child: TextButton.icon(
                              onPressed: () {
                                if (_isSpeakingOcr) {
                                  _speechService.stop();
                                  setState(() => _isSpeakingOcr = false);
                                } else {
                                  setState(() => _isSpeakingOcr = true);
                                  unawaited(
                                    _speechService
                                        .speakOcrLines(result.lines)
                                        .whenComplete(() {
                                          if (mounted) {
                                            setState(
                                              () => _isSpeakingOcr = false,
                                            );
                                          }
                                        }),
                                  );
                                }
                              },
                              icon: Icon(
                                _isSpeakingOcr
                                    ? Icons.stop_rounded
                                    : Icons.volume_up_rounded,
                                color: Colors.white,
                                size: 18,
                              ),
                              label: Text(
                                _isSpeakingOcr ? 'STOP' : 'READ AGAIN',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
