# Sanetra

**An offline-first assistive vision app for blind and low-vision users.**

Sanetra helps users identify Indian currency and read printed text using an Android phone. Currency recognition, OCR, and speech run on the device. Internet access is used only for optional update checks and downloading a newer release.

<p align="center">
  <a href="https://github.com/chethanone/Sanetra/releases/tag/v3.0.1">
    <img alt="Download Sanetra v3.0.1" src="https://img.shields.io/badge/Download-Android%20APK-111111?style=for-the-badge&logo=android&logoColor=white">
  </a>
  <a href="https://github.com/chethanone/Sanetra/releases/tag/v3.0.1">
    <img alt="Release v3.0.1" src="https://img.shields.io/badge/Release-v3.0.1-555555?style=for-the-badge">
  </a>
</p>

> **Current Android release:** v3.0.1 (versionCode 14) · arm64-v8a  
> **Package ID:** `com.sanetra.assistivevision`  
> **Release:** [Sanetra v3.0.1 on GitHub Releases](https://github.com/chethanone/Sanetra/releases/tag/v3.0.1)  
> **Upgrade path:** Compatible installations using `com.sanetra.assistivevision` can update in place when the installed version code is lower and the APK is signed with the same permanent release certificate. Legacy v1.0.0 installations use a different package ID and require the documented manual migration.

## What it does

- **Indian currency recognition:** identifies and counts supported Indian banknote and coin denominations. The production pipeline includes detection, identity/safety checks, temporal tracking and duplicate-announcement suppression. Currency guidance distinguishes a confirmed invalid/non-currency presentation (`INVALID`) from an uncertain or low-confidence observation (`UNRECOGNISED`). Visual checks assist denomination recognition; they do not guarantee physical authenticity or replace bank-grade counterfeit detection.
- **OCR text reading:** captures and reads printed text on user request. The OCR pipeline includes text detection and recognition, spatial grouping, layout-aware reading order and handling for rotated or inverted text.
- **Reading order and layout awareness (v3.0.1):** groups text regions into spatial blocks and reads lines in sequence to reduce jumping between columns or unrelated regions.
- **Multilingual script handling:** separates English, Hindi and Kannada text spans when they appear together, subject to recognition quality and the selected OCR models.
- **Spoken symbol and unit expansion:** expands supported currency symbols, arithmetic operators, percentages, common units and packaging abbreviations into speech-friendly forms.
- **Kannada handwriting handling:** includes image-processing improvements intended to preserve fine Kannada strokes and matras. Handwriting performance depends on writing quality and image conditions and should not be treated as guaranteed recognition.
- **Offline voice assistance:** speaks currency and OCR results using supported offline speech resources available on the device. Currency speech includes the configured language options; OCR language support is English, Hindi and Kannada.
- **Hands-free controls:** physical volume-button interactions support the configured OCR and currency controls.
- **Low-light assistance:** uses the device's ambient-light capability to assist camera use where supported.
- **Optional app updates:** checks the project's GitHub update manifest when connectivity is available. Android requires user approval to install a downloaded update.

## Designed to work offline

After installation and setup, core recognition and speech features are designed to work without an internet connection.

| Feature | Offline operation |
| --- | --- |
| Currency recognition and counting | Yes |
| OCR recognition | Yes |
| Speech output | Yes, when the required offline voice resources are available |
| Camera and supported low-light assistance | Yes |
| Update check and APK download | Requires internet |

Sanetra does not require cloud OCR or cloud inference for its normal recognition workflow.

## v3.0.1 release highlights

- Improved OCR reading order using spatial blocks, line grouping and column-aware sequencing.
- Improved handling of rotated and inverted text before speech output.
- Separation of English, Hindi and Kannada script spans in mixed-language content.
- Spoken expansion for supported currency symbols, arithmetic operators, units and packaging abbreviations.
- Kannada handwriting image-processing refinements.
- Currency result handling distinguishes `INVALID` from `UNRECOGNISED`, with corresponding spoken guidance and visual status treatment.
- Currency-mode status indicator differentiates idle/offline state from active detections.

The v3.0.1 release summary reports **53/53 automated regression tests passed** across the listed tracker, coin-safety, OCR layout/handwriting, flashlight and candidate-replay test groups. Automated tests are not a substitute for physical-device validation across all Android models and real-world conditions.

## Technology

- **App:** Flutter and Dart
- **Android integration:** Kotlin platform channels and Android APIs
- **On-device inference:** ONNX Runtime
- **Currency:** YOLO-based detection, identity-verification models and temporal tracking
- **OCR:** PP-OCRv5 Mobile components and Kannada/Hindi recognition components
- **Speech:** Android speech facilities and bundled/offline speech resources where configured
- **Update delivery:** GitHub Releases, version manifest, SHA-256 verification and Android's package installer

The active model files and technical metadata are listed in the [Model Catalog](models/MODEL_CATALOG.md).

## Download and install

**[Open the Sanetra v3.0.1 GitHub release](https://github.com/chethanone/Sanetra/releases/tag/v3.0.1)** and download the Android APK asset provided there.

1. Open the v3.0.1 release page.
2. Download the APK asset for Android arm64 (`arm64-v8a`).
3. Open the downloaded APK on a compatible Android device.
4. Approve Android's request to install apps from that source, if prompted.
5. Complete installation through Android's package installer.
6. Ensure the required offline speech resources are available for the languages you intend to use.

Android requires user confirmation to install an APK. Sanetra does not silently install updates.

**Release links:** [v3.0.1 release notes and assets](https://github.com/chethanone/Sanetra/releases/tag/v3.0.1) · [All releases](https://github.com/chethanone/Sanetra/releases) · [Third-party notices](THIRD_PARTY_NOTICES.md)

## Build from source

Requirements: Flutter SDK compatible with the Dart constraint in `app/final_app/pubspec.yaml`, Android SDK/Gradle, and an Android arm64 build environment.

```bash
git clone https://github.com/chethanone/Sanetra.git
cd Sanetra/app/final_app
flutter pub get
flutter analyze lib test
flutter test
flutter build apk --release --flavor production -t lib/main.dart
```

The production Android application ID is:

```text
com.sanetra.assistivevision
```

The project uses release-signing credentials for production builds. Never commit the private keystore or `key.properties` credentials.

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

The v3.0.1 release summary reports 53/53 automated regression tests passing. These tests cover the listed automated test groups; they do not establish universal accuracy or guarantee identical behavior on every physical Android device.

Recognition quality depends on lighting, focus, text size, print and handwriting quality, currency condition, viewing angle and scene complexity. OCR may fail on unclear, heavily distorted or partially obscured text. Currency visual checks are not bank-grade counterfeit verification. Offline speech depends on compatible voice resources being installed or bundled for the selected language.

The repository's earlier device-validation records identify a Nothing Phone (3a) Pro as a primary validation device for earlier releases. Do not infer that every device model has been physically tested for v3.0.1.

### Android release signing

The APK is distributed through GitHub Releases, not through Google Play. Beginning with v2.0.0 (`com.sanetra.assistivevision`), release builds use a dedicated permanent Android release-signing certificate. Its recorded SHA-256 fingerprint is `b3986507f0092f9296342fca8fe12c7c6f2e63d4e9516399690be422149a1389`. Compatible in-place updates must retain the same signing certificate and use a higher Android `versionCode`. Keep the private signing keystore backed up securely and never commit it to the repository.

## License and reuse

This repository is published for project evaluation, academic review and transparency. **All rights are reserved; no general open-source reuse or redistribution licence is granted.** Third-party components and model weights remain subject to their respective upstream terms. See [LICENSE](LICENSE) before reuse.

---

For issues or project questions, use the repository's [Issues](https://github.com/chethanone/Sanetra/issues) page.
