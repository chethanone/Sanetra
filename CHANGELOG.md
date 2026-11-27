# Changelog

## v3.0.1 (2026-11-27)

- **OCR Reading Order and Layout Awareness:** Added spatial block segmentation and line-by-line sequencing intended to reduce reading-order jumps across columns and text regions.
- **Rotation and Inversion Handling:** Added OCR image normalization for rotated, inverted and curved text inputs, with recognition dependent on the source image and supported processing path.
- **Mixed-Script Separation:** Improved separation of English, Hindi and Kannada script segments in mixed-language OCR output.
- **Spoken Symbol and Unit Expansion:** Added spoken-form handling for supported currency symbols, arithmetic operators, percentages, common measurement units and packaging abbreviations.
- **Kannada Handwriting Image Processing:** Added local adaptive thresholding and stroke-contour morphology refinements intended to preserve delicate loops, curves and matras. This is not a guarantee of unrestricted handwriting recognition.
- **OCR Entry Interaction:** Improved entry into the user-triggered OCR reading flow.
- **Currency Result Semantics:** Distinguished `INVALID` results for confirmed invalid/non-currency masqueraders from `UNRECOGNISED` results for uncertain, blurry or low-confidence observations, with corresponding localized spoken guidance and visual treatment.
- **Currency Reference Coverage:** Expanded currency reference specifications for note series and coin denominations. Reference specifications do not by themselves establish detector support or counterfeit authenticity verification for every listed issue.
- **Currency Status Indicator:** Added distinct idle/offline and active-detection status indication.
- **Automated Regression:** Release summary reports 53/53 automated regression tests passing across the listed tracker, coin-safety, OCR layout/handwriting, flashlight and candidate-replay test groups.

## v2.2.0.1 (2026-11-19)
- **Splash & Loading Icon Alignment:** Replaced the legacy loading screen artwork (`drawable-nodpi/splash_logo.png`) with the official high-contrast Sanetra Vision Rupee branding centered on a pure black background (`#000000`).
- **Android 12+ (API 31+) SplashScreen Support:** Added dedicated Android 12+ theme configurations (`values-v31` and `values-night-v31`), binding `windowSplashScreenAnimatedIcon` and `windowSplashScreenBackground` directly to the new Vision Rupee logo.
- **Visual Consistency:** Resolves the discrepancy where the app launcher icon displayed the new Vision Rupee branding but launching the app displayed the legacy icon during loading.
- **Core Pipeline Preservation:** Strict icon and theme asset release. All currency models, ONNX runtime configurations, OCR engines, offline speech assets, volume gestures, anti-spoof checks, and update mechanisms remain 100% identical and unchanged.

## v2.2.0 (2026-11-19)
- **Pipeline Resource Lifecycle & Native Leak Fixes:** Refactored Android native camera frame processing to ensure all intermediate `Bitmap` allocations and ONNX `OnnxTensor` instances are deterministically closed in `finally` blocks, preventing GPU memory fragmentation and heap growth during extended continuous scanning sessions.
- **Zero-Heap Direct Tensor Population:** Eliminated intermediate `FloatArray` heap allocations in native preprocessing (`CurrencyDetector.kt` and `PreprocessOutput.kt`); normalized pixel tensors are now streamed directly into native memory buffers.
- **In-App Updater Certificate Pinning:** Enhanced `AppUpdateChannel.kt` with cryptographic signature verification that verifies APK signing certificates against the permanent release certificate SHA-256 allowlist (`B3986507F0092F9296342FCA8FE12C7C6F2E63D4E9516399690BE422149A1389`) prior to triggering system installation.
- **Android Security Hardening:** Restricted internal diagnostic broadcast receiver (`MainActivity.kt`) strictly to debuggable builds; blocked cleartext network traffic via Android `network_security_config.xml`; configured secure auto-backup rules (`data_extraction_rules.xml` and `backup_rules.xml`).
- **Fail-Closed Release Signing Configuration:** Updated Gradle build scripts (`build.gradle.kts`) to fail release builds immediately if production signing credentials or keystores are missing or unconfigured.
- **Conservative Anti-Spoofing & Denomination Guidance:** Integrated screen-replay and photocopy detection safeguards into currency classification. Detections failing sharpness, lighting, or texture uniformity gates trigger conservative spoken guidance (`"Possible [Denomination] Rupee Note, not confirmed. Hold steady in better light and try again."`). Camera-based anti-spoofing assists with visual denomination recognition and does not guarantee genuine physical banknote authenticity.
- **Validated On-Device Performance:** Verified on Nothing Phone (3a) Pro (Android 17 / SDK 37); sustained steady memory usage (~306 MB Native, ~33 MB Dalvik) with zero logcat crashes or performance degradation over continuous recognition sessions. All 140 automated Flutter unit/pipeline tests passing.

## v2.1.3 (2026-11-19)
- **High-Contrast Vision Rupee Launcher Icon:** Replaced the legacy Android application launcher icon across all screen densities (`mdpi`, `hdpi`, `xhdpi`, `xxhdpi`, `xxxhdpi`, `anydpi-v26`) with the official Sanetra Vision Rupee branding.
- **Adaptive Icon & Safe-Bound Alignment:** Scaled and centered the high-contrast white eye-and-rupee symbol on a pure black background (`#000000`), ensuring full visibility with zero edge clipping across both circular and rounded-rectangle launcher masks.
- **Android 13+ Themed Icon Support:** Added dedicated monochrome vector layer (`ic_launcher_monochrome`) to support Android 13+ themed/tinted app icons on compatible Pixel and Nothing OS launchers.
- **Core Pipeline Preservation:** Strict icon-only release. All currency recognition models, ONNX model hashes, OCR engines, offline speech assets, volume gestures, and update mechanisms remain 100% identical and unchanged.

## v2.1.2 (2026-11-19)
- **Faster, Smoother Foreground APK Downloads:** Throttled download progress callbacks to at most 1 update per 250 ms (maximum 4 updates per second) with a minimum progress delta of 0.5%, reducing foreground dialog UI rebuilds by over 98% and maintaining full wire download speed while visible.
- **Background APK Checksum Verification:** Offloaded SHA-256 integrity calculation to a dedicated background `ioExecutor` in `AppUpdateChannel.kt`, eliminating the 1.5–3.0 second main-thread UI freeze upon download completion.
- **Automatic Install Continuation:** Integrated `WidgetsBindingObserver` lifecycle resumption. When returning to Sanetra after granting Android's "Install unknown apps" permission in Settings, the application automatically launches the Android package installer without requiring the user to restart the update.
- **Zero-Download Verified APK Reuse:** Persisted pending update install metadata (`PendingUpdateInstall`) in private cache, allowing the already downloaded and verified 421 MB APK to be reused immediately without downloading again.
- **Stream Integrity & Cleanup:** Partial incomplete files are automatically deleted upon connection loss or socket read errors, preventing corrupted cache states.
- **Automated Validation:** Full test suite verified (133/133 tests passing, 100% green); static analysis clean (0 issues). Physical validation on Nothing Phone (3a) Pro was pending at release time due to disconnected ADB.

## v2.1.0 (2026-11-16)
- **Offline Bisaya (`ceb-PH`) Currency Speech:** Added Bisaya as the fourth selectable Currency Recognition language (`English`, `Kannada`, `Hindi`, `Bisaya`) with instant zero-synthesis-delay `AudioTrack` playback (`BisayaTtsChannel.kt`, `BisayaSpeechAssembler`, `BisayaNumberNormalizer`, and 43 normalized 16 kHz WAV clips totaling `1.52 MB`; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for Meta AI `facebook/mms-tts-ceb` `CC-BY-NC 4.0` attribution).
- **Strict OCR Isolation & Pipeline Preservation:** OCR remains strictly `en-IN`, `kn-IN`, and `hi-IN`. Currency ONNX models (`Phase 4L + Phase 4N + N5 + Phase 4O.10`), safety thresholds, `en-IN`/`kn-IN`/`hi-IN` TTS, flashlight, and volume gestures remain unchanged.

## v2.0.1 (2026-11-16)
- **Migration Installer Handoff Fix:** Integrated the verified Android APK installer target-package handoff (`AppUpdateChannel.kt`, `AppUpdateService`, `UpdatePromptDialog`) for cross-package migrations.
- **Upgrade Compatibility:** Signed with the permanent `com.sanetra.assistivevision` release certificate (`b3986507f0092f9296342fca8fe12c7c6f2e63d4e9516399690be422149a1389`, `versionCode: 3`). Legacy `v1.0.0` users must perform the first `v2.x` installation manually (installed as a separate app alongside `v1.0.0`), while future compatible `v2.x` updates install in place.

## v2.0.0 (2026-11-16)
- **Android Application Identity Migration:** Migrated `applicationId` and `namespace` from `com.visionassistant.vision_assistant.visionmission` to `com.sanetra.assistivevision` (`versionCode: 2`, `versionName: 2.0.0`).
- **Permanent Release Signing:** Signed release APK with a dedicated permanent Android release-signing certificate (SHA-256 fingerprint `b3986507f0092f9296342fca8fe12c7c6f2e63d4e9516399690be422149a1389`) so future `v2.x+` updates install cleanly in place.
- **Update Checker Migration Handling:** Added `packageName` manifest validation (`UpdateCheckStatus.migrationAvailable`) and migration notice in `UpdatePromptDialog` so `v1.0.0` installs are informed that `v2.0.0` installs as a new package rather than an in-place overwrite.
- **Publication-Quality Visualizations:** Redesigned all 31 documentation plots (`docs/figures/*.png`) from original numerical data with a unified white/navy/teal style, and added `docs/VISUALIZATION_STYLE_GUIDE.md` and `docs/VISUALIZATION_AUDIT_REPORT.md`.

## v1.0.0 (2026-11-16)
- Initial public release of **Sanetra** (`com.visionassistant.vision_assistant.visionmission`).
- Offline Indian banknote (`₹10`–`₹500`) and coin (`₹1`–`₹10`) recognition with `N5` and `4O10` identity verifiers.
- Offline multilingual OCR (English, Kannada `scene_arjuna_first` + `CRNN`, Hindi) with curved-label unwarping and reading-order sorting.
- Offline Google TTS (`en-IN`, `kn-IN`, `hi-IN`) with serialized queue and preemptive 4-second volume-key language selector.
- Double Volume Up OCR reread (`450 ms`) and automatic ambient-light flashlight (`Sensor.TYPE_LIGHT`).
- Optional GitHub Releases update checker (`AppUpdateService`) with SHA-256 verification and `FileProvider` install handoff.
