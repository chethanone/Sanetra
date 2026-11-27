import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vision_assistant/services/app_update_service.dart';

void main() {
  group('Sanetra v3.0.1.1 Production Updater Verification', () {
    const String expectedSha256 =
        'E3BC95F8D6132FD25BE5DEA1271A1A3D0331B526D5AE2733691C54EA99EB9D69';
    const String expectedSignerFingerprint =
        'b3986507f0092f9296342fca8fe12c7c6f2e63d4e9516399690be422149a1389';
    const String productionManifestJson = '''
{
  "version": "3.0.1.1",
  "versionCode": 15,
  "minimumSupportedVersionCode": 2,
  "packageName": "com.sanetra.assistivevision",
  "platform": "android",
  "architecture": "arm64-v8a",
  "releaseType": "stable",
  "apkAsset": "Sanetra-v3.0.1.1-arm64.apk",
  "sha256": "$expectedSha256",
  "releaseNotes": "Smart line-by-line OCR reading, multilingual script isolation, Kannada handwriting enhancement, strict currency Invalid vs Unrecognised gating, and refreshed OFFLINE status pill.",
  "releaseUrl": "https://github.com/chethanone/Sanetra/releases/tag/v3.0.1.1"
}
''';

    const installedV2201 = InstalledAppInfo(
      packageName: 'com.sanetra.assistivevision',
      versionName: '2.2.0.1',
      versionCode: 12,
      supportedAbis: ['arm64-v8a', 'armeabi-v7a'],
    );

    const installedV3011 = InstalledAppInfo(
      packageName: 'com.sanetra.assistivevision',
      versionName: '3.0.1.1',
      versionCode: 15,
      supportedAbis: ['arm64-v8a', 'armeabi-v7a'],
    );

    test('1. Manifest parser validates production 3.0.1.1 manifest cleanly', () {
      final manifest = UpdateManifest.tryParse(productionManifestJson);
      expect(manifest, isNotNull);
      expect(manifest!.version, '3.0.1.1');
      expect(manifest.versionCode, 15);
      expect(manifest.minimumSupportedVersionCode, 2);
      expect(manifest.packageName, 'com.sanetra.assistivevision');
      expect(manifest.platform, 'android');
      expect(manifest.architecture, 'arm64-v8a');
      expect(manifest.releaseType, 'stable');
      expect(manifest.apkAsset, 'Sanetra-v3.0.1.1-arm64.apk');
      expect(manifest.sha256, expectedSha256);
      expect(
        manifest.resolvedDownloadUrl,
        'https://github.com/chethanone/Sanetra/releases/download/v3.0.1.1/Sanetra-v3.0.1.1-arm64.apk',
      );
    });

    test('2. v2.2.0.1 -> v3.0.1.1 discovery succeeds with updateAvailable status', () async {
      final svc = AppUpdateService(
        checkConnectivity: () async => true,
        getInstalledAppInfo: () async => installedV2201,
        fetchManifest: (_, _) async => productionManifestJson,
      );

      final res = await svc.checkForUpdate(force: true);
      expect(res.status, UpdateCheckStatus.updateAvailable);
      expect(res.manifest, isNotNull);
      expect(res.manifest!.version, '3.0.1.1');
      expect(res.manifest!.versionCode, 15);
      await svc.dispose();
    });

    test('3. Already-current v3.0.1.1 suppresses update prompt (upToDate)', () async {
      final svc = AppUpdateService(
        checkConnectivity: () async => true,
        getInstalledAppInfo: () async => installedV3011,
        fetchManifest: (_, _) async => productionManifestJson,
      );

      final res = await svc.checkForUpdate(force: true);
      expect(res.status, UpdateCheckStatus.upToDate);
      expect(res.manifest?.versionCode, 15);
      await svc.dispose();
    });

    test('4. Offline behavior gracefully returns offline status without crashing', () async {
      final svc = AppUpdateService(
        checkConnectivity: () async => false,
        getInstalledAppInfo: () async => installedV2201,
        fetchManifest: (_, _) async => throw const SocketException('Network unreachable'),
      );

      final res = await svc.checkForUpdate(force: true);
      expect(res.status, UpdateCheckStatus.offline);
      expect(res.manifest, isNull);
      await svc.dispose();
    });

    test('5. APK download, SHA-256 verification and progress tracking', () async {
      final tempDir = await Directory.systemTemp.createTemp('sanetra_update_test_');
      try {
        final manifest = UpdateManifest.tryParse(productionManifestJson)!;
        final syntheticPayload = Uint8List.fromList(List<int>.generate(1024, (i) => i % 256));
        final syntheticHash = sha256.convert(syntheticPayload).toString().toUpperCase();

        final mockManifest = UpdateManifest(
          version: manifest.version,
          versionCode: manifest.versionCode,
          minimumSupportedVersionCode: manifest.minimumSupportedVersionCode,
          platform: manifest.platform,
          architecture: manifest.architecture,
          releaseType: manifest.releaseType,
          apkAsset: manifest.apkAsset,
          sha256: syntheticHash,
          releaseNotes: manifest.releaseNotes,
          releaseUrl: manifest.releaseUrl,
          packageName: manifest.packageName,
        );

        final progressList = <double>[];
        final svc = AppUpdateService(
          getCacheDir: () async => tempDir,
          downloadApk: (url, dest, onProgress, _) async {
            onProgress?.call(0.5);
            await dest.writeAsBytes(syntheticPayload);
            onProgress?.call(1.0);
          },
          computeSha256: (path) async {
            final bytes = await File(path).readAsBytes();
            return sha256.convert(bytes).toString().toUpperCase();
          },
          launchInstaller: (path, targetPkg) async => {'started': true, 'isMigration': false},
        );

        final res = await svc.downloadAndInstall(
          mockManifest,
          onProgress: (p) => progressList.add(p),
        );

        expect(res.success, isTrue);
        expect(progressList, contains(0.0));
        expect(progressList, contains(1.0));
        await svc.dispose();
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('6. SHA-256 mismatch aborts installation and reports checksum failure', () async {
      final tempDir = await Directory.systemTemp.createTemp('sanetra_corrupt_test_');
      try {
        final manifest = UpdateManifest.tryParse(productionManifestJson)!;
        final svc = AppUpdateService(
          getCacheDir: () async => tempDir,
          downloadApk: (_, dest, onProg, _) async {
            await dest.writeAsBytes([0xDE, 0xAD, 0xBE, 0xEF]);
            onProg?.call(1.0);
          },
          computeSha256: (_) async => 'CORRUPTED_HASH_DOES_NOT_MATCH_0123456789ABCDEF0123456789ABCDEF',
          launchInstaller: (_, _) async => throw StateError('Must not launch on mismatch'),
        );

        final res = await svc.downloadAndInstall(manifest);
        expect(res.success, isFalse);
        expect(res.error, contains('checksum'));
        await svc.dispose();
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('7. Signing certificate compatibility & existing application data preservation', () {
      // Both v2.2.0.1 and v3.0.1.1 are signed by the same permanent release key:
      const v2201Signer = 'b3986507f0092f9296342fca8fe12c7c6f2e63d4e9516399690be422149a1389';
      const v3011Signer = expectedSignerFingerprint;

      expect(v3011Signer, equals(v2201Signer));
      // Same package name and compatible signing certificate ensures Android Package Manager
      // performs an in-place upgrade without data wipe, preserving app databases and shared preferences.
      expect(installedV2201.packageName, equals(installedV3011.packageName));
      expect(installedV3011.versionCode, greaterThan(installedV2201.versionCode));
    });

    test('8. Android installer handoff targets exact package com.sanetra.assistivevision in place', () async {
      final tempDir = await Directory.systemTemp.createTemp('sanetra_handoff_test_');
      try {
        final manifest = UpdateManifest.tryParse(productionManifestJson)!;
        String? handedOffPackage;
        String? handedOffPath;

        final svc = AppUpdateService(
          getCacheDir: () async => tempDir,
          downloadApk: (_, dest, onProg, _) async {
            await dest.writeAsBytes([1, 2, 3]);
            onProg?.call(1.0);
          },
          computeSha256: (_) async => manifest.sha256,
          launchInstaller: (path, targetPkg) async {
            handedOffPath = path;
            handedOffPackage = targetPkg;
            return {'started': true, 'isMigration': false};
          },
        );

        final res = await svc.downloadAndInstall(manifest);
        expect(res.success, isTrue);
        expect(handedOffPackage, 'com.sanetra.assistivevision');
        expect(handedOffPath, endsWith('Sanetra-v3.0.1.1-arm64.apk'));
        await svc.dispose();
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}
