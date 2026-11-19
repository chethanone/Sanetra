# Sanetra

**An offline-first assistive vision app for blind and low-vision users.**

Sanetra helps users identify Indian currency and read printed text using an Android phone. Currency recognition, OCR, and speech run on the device; an internet connection is used only for optional app-update checks and downloading a new release.

<p align="center">
  <a href="https://github.com/chethanone/Sanetra/releases/download/v2.1.3/Sanetra-v2.1.3-arm64.apk">
    <img alt="Download Sanetra v2.1.3" src="https://img.shields.io/badge/Download-Android%20APK-111111?style=for-the-badge&logo=android&logoColor=white">
  </a>
  <a href="https://github.com/chethanone/Sanetra/releases/tag/v2.1.3">
    <img alt="Release v2.1.3" src="https://img.shields.io/badge/Release-v2.1.3-555555?style=for-the-badge">
  </a>
</p>

> **Current Android release:** v2.1.3 (versionCode 10) · arm64-v8a  
> **Package ID:** `com.sanetra.assistivevision`  
> **Upgrading:** Existing `v2.0.0`–`v2.1.2` installations (`com.sanetra.assistivevision`) upgrade cleanly in place via the built-in update checker. Legacy `v1.0.0` (`com.visionassistant.vision_assistant.visionmission`) users must perform the first `v2.x` installation manually as a separate app.

## What it does

- **Indian currency recognition:** identifies and counts six banknote denominations (₹10, ₹20, ₹50, ₹100, ₹200 and ₹500) and four coin denominations (₹1, ₹2, ₹5 and ₹10). The detection pipeline includes identity verification and tracking to reduce false detections and unreliable totals.
- **Multilingual text reading:** detects and reads printed English, Kannada and Hindi text. Kannada recognition uses a document/scene-aware routing approach; text geometry and reading order are considered during processing.
- **Voice assistance:** provides spoken recognition results using the device's offline text-to-speech voices.
- **Hands-free controls:** physical volume buttons control mode switching, OCR rereading and the currency language selector.
- **Automatic low-light assistance:** monitors the ambient-light sensor and controls the flashlight in Currency and OCR modes, with spoken ON/OFF feedback.
- **Optional app updates:** when connectivity is available, Sanetra checks the project's GitHub update manifest. It shows an update prompt only when a newer compatible version is found.

## Designed to work offline

After installation and setup, the core features do not require an internet connection:

| Feature | Offline operation |
| --- | --- |
| Currency detection and counting | Yes |
| English, Kannada and Hindi OCR | Yes |
| Speech output | Yes, with the required offline voice packs installed on Android |
| Camera and automatic flashlight | Yes |
| Version/update check and APK download | Requires internet |

Sanetra does not send camera frames or recognized text to a cloud recognition service.

## Technology

- **App:** Flutter and Dart
- **Android integration:** Kotlin platform channels and Android APIs
- **On-device inference:** ONNX Runtime
- **Currency:** YOLOv8n detection with MobileNetV3-Small identity-verification models and temporal tracking
- **OCR:** PP-OCRv5 Mobile detection/recognition, Kannada CRNN and Arjuna SVTRv2 scene-recognition model
- **Speech:** Android text-to-speech using offline English (India), Kannada and Hindi voices
- **Update delivery:** GitHub Releases, version manifest, SHA-256 verification and Android's package installer

The active model files and their technical metadata are listed in [Model Catalog](models/MODEL_CATALOG.md).

## Download and install

**[Download Sanetra v2.1.2 for Android (arm64-v8a)](https://github.com/chethanone/Sanetra/releases/download/v2.1.2/Sanetra-v2.1.2-arm64.apk)**

1. Download the APK from the release link above.
2. Open the downloaded APK on an Android arm64 device.
3. Approve Android's request to install apps from that source, if prompted.
4. Complete installation through the Android package installer.
5. For offline speech, make sure the required Google TTS offline voice data is installed for the languages you intend to use.

Android requires user confirmation to install an APK. Sanetra does not silently install updates.

**Release details:** [v2.1.2 release notes and APK](https://github.com/chethanone/Sanetra/releases/tag/v2.1.2) · [All releases](https://github.com/chethanone/Sanetra/releases) · [Third-party audio notices](THIRD_PARTY_NOTICES.md)

## Build from source

Requirements: Flutter SDK compatible with the Dart constraint in `app/final_app/pubspec.yaml`, Android SDK/Gradle, and an Android arm64 build environment.

```bash
git clone https://github.com/chethanone/Sanetra.git
cd Sanetra/app/final_app
flutter pub get
flutter analyze lib test
flutter test
flutter build apk --release --flavor visionmission -t lib/main.dart
```

The current Android application ID is:

```text
com.sanetra.assistivevision
```

## Project documentation

- [Master project report](docs/MASTER_PROJECT_REPORT.md)
- [Currency subsystem](docs/CURRENCY_FINAL_REPORT.md)
- [OCR subsystem](docs/OCR_FINAL_REPORT.md)
- [Android application](docs/ANDROID_APPLICATION_REPORT.md)
- [Device validation](docs/DEVICE_VALIDATION_REPORT.md)
- [Model catalog and model hashes](models/MODEL_CATALOG.md)
- [Automatic update system](update/UPDATE_SYSTEM.md)
- [Changelog](CHANGELOG.md)

## Validation and known limitations

The repository's Phase 6.0 report records static analysis, automated tests and release-build checks. Automated tests do not replace testing on a physical device.

Recognition quality depends on lighting, focus, text size, print quality, note condition and scene complexity. Kannada scene text is more challenging than clean printed documents; see the OCR report for benchmark details. Offline speech depends on compatible voice data being available on the Android device.

The primary validation device used during development was a Nothing Phone (3a) Pro running Android 17. Other Android devices may differ in camera, sensor, ONNX Runtime and TTS behaviour.

### Android release signing

The APK is distributed directly through GitHub Releases, not through Google Play. Beginning with `v2.0.0` (`com.sanetra.assistivevision`), release builds use a dedicated permanent Android release-signing certificate. Its SHA-256 fingerprint is `b3986507f0092f9296342fca8fe12c7c6f2e63d4e9516399690be422149a1389` and can be used to verify the signer. Future in-app upgrades must use the same signing certificate and a higher Android `versionCode`; keep the private signing keystore backed up securely and never commit it to the repository.

## License and reuse

This repository is published for project evaluation, academic review and transparency. **All rights are reserved; no general open-source reuse or redistribution licence is granted.** Third-party components and model weights remain subject to their respective upstream terms. See [LICENSE](LICENSE) before reuse.

---

For issues or project questions, use the repository's [Issues](https://github.com/chethanone/Sanetra/issues) page.
