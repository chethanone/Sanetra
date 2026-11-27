# Sanetra Automatic Update System

Sanetra runs **100% offline** for all currency recognition, OCR, flashlight, and TTS features. Network access is used **only** for optional update checks when internet connectivity is available.


## Current release: v3.0.1

The production source declares Sanetra **v3.0.1** with Android `versionCode: 14` and package ID `com.sanetra.assistivevision`. The corresponding production flavor is configured in the Android Gradle build.

The public update manifest at `update/latest.json` is the authoritative version source for installed clients. **Do not advertise v3.0.1 in that manifest until the exact APK asset uploaded to the v3.0.1 GitHub Release has been retrieved and verified.** The manifest must contain the exact release asset filename and the SHA-256 digest computed from those exact APK bytes. A local build filename, a reported file size, or a release tag is not a substitute for verifying the uploaded asset.

Release publication checklist:
1. Confirm the v3.0.1 GitHub Release contains the production arm64 APK asset.
2. Download that exact asset and independently calculate its SHA-256.
3. Verify package ID, version name, version code, architecture and signing-certificate fingerprint.
4. Update `update/latest.json` with the exact asset filename and verified digest.
5. Fetch the public raw manifest URL and confirm it serves the new version and digest.
6. Test update discovery and Android installer handoff on a compatible existing installation.

Android installation remains user-approved; this updater cannot silently force an installation on every device. The current manifest's architecture restriction also means that only compatible `arm64-v8a` installations can use that APK.

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
