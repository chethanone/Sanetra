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

The v1.0.0 APK was built before migration-aware package installation was added. Its embedded native installer rejects an APK whose package ID differs from the currently running app, so it cannot install v2.0.0 from its in-app Update button. Users still on v1.0.0 must install v2.0.0 once from the official [GitHub Release](https://github.com/chethanone/Sanetra/releases/tag/v2.0.0). The corrected installer in the next v2.x release will support verified v2.x in-place updates. Installing v2.0.0 does not remove the v1 app or its data.
