# ANDROID APPLICATION REPORT (SANETRA)

## 1. Architecture & Packaging
- **Root:** `C:\VisionMission\experiments\phase5_3\final_app`
- **Package ID:** `com.visionassistant.vision_assistant.visionmission`
- **Branding (Phase 5.13):** Display name **Sanetra**, pure-black adaptive launcher icon, `"Sanetra"` splash screen.
- **Model Packaging:** 19 ONNX models bundled in `assets/models/` with SHA-256 versioned cache extraction; zero network calls required.

## 2. Hardware Controls & Accessibility
- **Volume Up (2s hold):** Toggles Currency <-> OCR mode; entering OCR automatically captures and speaks visible text once (`Phase 5.10`).
- **Volume Up Double-Press (`450 ms` in OCR mode):** Captures a fresh frame and rereads text without leaving OCR mode (`Phase 5.12`).
- **Volume Down (2s hold):** Opens/closes the 4-second Language Selector (`English`, `Kannada`, `Hindi`), pausing currency inference and granting exclusive preemptive TTS control (`Phases 5.9–5.10`).
- **Auto-Flashlight (`Phase 5.14`):** `AutoFlashlightController` + `AmbientLightFlashlightChannel.kt` (`Sensor.TYPE_LIGHT`) runs across both modes (`< 3.0 lux` for `2000 ms` -> ON; reflection-compensated OFF threshold), re-asserts `FlashMode.torch` after `takePicture()`, and respects manual/external torch ownership.

## 3. Build & Automated Verification
- `flutter analyze lib test`: **0 issues found**.
- `flutter test`: **93 / 93 tests passed**.
- Release APK: `app-visionmission-release.apk` (`399.0 MB`, SHA-256: `C90EA322035087AFDE5FD957011935145E533048203E71236455170894B7CC8B`).
