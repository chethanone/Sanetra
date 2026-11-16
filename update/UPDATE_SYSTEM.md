# Sanetra Automatic Update System

Sanetra runs **100% offline** for all currency recognition, OCR, flashlight, and TTS features. Network access is used **only** for optional update checks when internet connectivity is available.

## Architecture
- **Manifest Source:** `https://raw.githubusercontent.com/chethanone/Sanetra/main/update/latest.json`
- **Native Android Bridge:** `AppUpdateChannel.kt` (`vision_assistant/app_update` & `vision_assistant/connectivity`)
  - Reads installed `versionName`, `versionCode`, and `Build.SUPPORTED_ABIS` from `PackageManager`.
  - Listens to `ConnectivityManager.NetworkCallback` without background polling.
  - Computes downloaded APK SHA-256 via `MessageDigest`.
  - Launches Android's standard package installer via `FileProvider` (`${applicationId}.fileprovider`) — never attempts silent installation.
- **Flutter Service:** `lib/services/app_update_service.dart`
  - Enforces HTTPS-only URLs under `github.com/chethanone/Sanetra` / `raw.githubusercontent.com/chethanone/Sanetra`.
  - Compares numeric `versionCode` (never string comparison).
  - Validates `packageName` (`com.sanetra.assistivevision` vs legacy `com.visionassistant.vision_assistant.visionmission`), returning `migrationAvailable` when a newer release uses a different Android package ID.
  - Validates architecture (`arm64-v8a`), `minimumSupportedVersionCode`, and 64-hex SHA-256.
  - Debounces and throttles checks (6-hour automatic cooldown; skipped during active camera/OCR capture).
- **Accessible Prompt:** `lib/widgets/update_prompt_dialog.dart` announces `"A new Sanetra update is available."` (or migration guidance when `isMigration` is true) once per discovered version using `SpeechService.enqueueShortAnnouncement`.


## v1.0.0 to v2.0.0 migration note

The v1.0.0 application was built before the migration-aware installer was available. Its native installer rejects an APK whose package ID differs from the running app, which causes the `APK package mismatch` message when it tries to install v2.0.0. Users still running v1.0.0 must install v2.0.0 once from the official [GitHub Release](https://github.com/chethanone/Sanetra/releases/tag/v2.0.0). The v2.0.1 build will contain the corrected installer for future v2.x updates. The v1.0.0 app and its data are not removed by installing v2.0.0.
