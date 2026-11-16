# Changelog

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
