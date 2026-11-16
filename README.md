# Sanetra

**Offline Assistive Vision Assistant for Blind and Visually Impaired Users**

## 1. Description & Problem Statement
Blind and low-vision users often face barriers when independently identifying Indian banknotes and coins or reading printed and signboard text in English, Kannada, and Hindi. Cloud-dependent assistive apps fail without connectivity and introduce latency and privacy risks. **Sanetra** performs all currency recognition, multilingual OCR, ambient-light flashlight control, and speech synthesis **100% offline** on Android.

## 2. Main Features
- **Indian Currency Recognition & Counting:** Detects 6 banknote denominations (`₹10`, `₹20`, `₹50`, `₹100`, `₹200`, `₹500`) and 4 coin denominations (`₹1`, `₹2`, `₹5`, `₹10`) in real time and snapshot mode, gated by identity verifiers to reject foreign currency and non-currency backgrounds.
- **Offline Multilingual OCR:** Reads English, Kannada, and Hindi text, including curved bottle labels, tilted/rotated text, and multi-column layouts.
- **Automatic Ambient-Light Flashlight:** Monitors the device's hardware `Sensor.TYPE_LIGHT` across both Currency and OCR modes and announces `"Flashlight on."` / `"Flashlight off."` automatically in dark environments.
- **Hands-Free Volume-Button Controls & Offline Speech:** Full operation via physical Volume Up/Down gestures and serialized offline Google TTS.

## 3. Technology Stack & System Architecture
- **Frontend & Runtime:** Flutter (Dart `^3.13.7`), Kotlin Android channels, `flutter_onnxruntime ^1.9.0`, `camera ^0.12.2`, `flutter_tts ^4.2.5`.
- **Architecture:** See [docs/SYSTEM_ARCHITECTURE.md](docs/SYSTEM_ARCHITECTURE.md) and [docs/MASTER_PROJECT_REPORT.md](docs/MASTER_PROJECT_REPORT.md).

## 4. Model Information & Supported Languages
- **Currency:** `indian_banknote_phase4l_candidate.onnx` (YOLOv8n, `0.952 mAP@0.50`), `indian_coin_phase4n_candidate.onnx` (YOLOv8n, `0.937 mAP@0.50`), `n5_note_verifier.onnx` (MobileNetV3-Small, `99.04%` val acc), `indian_coin_verifier.onnx` (`99.88%` val acc).
- **OCR:** `PP-OCRv5` Mobile detector + English/Hindi recognizers, Kannada `CRNN v3` (clean docs), and `Arjuna SVTRv2 INT8` (`scene_arjuna_first` for scene/curved text).
- **Supported Speech Languages:** English (`en-IN`), Kannada (`kn-IN`), Hindi (`hi-IN`) using offline Google TTS voices.
- Full model inventory and SHA-256 hashes: [models/MODEL_CATALOG.md](models/MODEL_CATALOG.md).

## 5. Device Requirements
- Android `arm64-v8a` smartphone with rear camera, LED flash, hardware ambient-light sensor (`Sensor.TYPE_LIGHT`), and Google TTS offline voice packs (`en-IN`, `kn-IN`, `hi-IN`).
- Primary physical validation device: **Nothing Phone (3a) Pro** (`Android 17 / API 37`, Snapdragon 7s Gen 3).

## 6. Installation, Build & Testing
```bash
cd app/final_app
flutter pub get
flutter analyze lib test
flutter test
flutter build apk --release --flavor visionmission -t lib/main.dart
```

## 7. Offline Operation & Optional Update System
- **Offline Operation:** All recognition, camera, flashlight, and TTS features run locally with zero network dependency.
- **Optional Update Checks:** When internet connectivity becomes available, `AppUpdateService` checks `update/latest.json` via HTTPS, verifies numeric `versionCode`, architecture, and SHA-256 checksum, announces availability once via TTS, and hands verified APKs to Android's `FileProvider` package installer (user confirmation required). See [update/UPDATE_SYSTEM.md](update/UPDATE_SYSTEM.md).

## 8. Documentation Index
- [Master Project Report](docs/MASTER_PROJECT_REPORT.md)
- [Currency Final Report](docs/CURRENCY_FINAL_REPORT.md)
- [OCR Final Report](docs/OCR_FINAL_REPORT.md)
- [Model Evaluation Report](docs/MODEL_EVALUATION_REPORT.md)
- [Dataset Documentation](docs/DATASET_DOCUMENTATION.md)
- [Android Application Report](docs/ANDROID_APPLICATION_REPORT.md)
- [Device Validation Report](docs/DEVICE_VALIDATION_REPORT.md)
- [Update System](docs/UPDATE_SYSTEM.md)

## 9. Known Limitations
- Wild scene Kannada OCR (`IndicSTR12_test`) achieves `41.00%` word exact match (`21.67%` CER) vs `95–99%` on clean printed pages.
- Epoch-by-epoch OCR training logs were not persisted (`train_metrics.json` retains summary metrics only).
- Release APKs currently use development signing rather than a Google Play production keystore.

## 10. License
All rights reserved; no explicit open-source reuse license is granted. See [LICENSE](LICENSE).
