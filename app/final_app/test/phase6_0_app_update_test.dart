import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vision_assistant/services/app_update_service.dart';
import 'package:vision_assistant/widgets/update_prompt_dialog.dart';

String _validManifestJson({
  String version = '2.0.1',
  int versionCode = 3,
  int minSupported = 2,
  String packageName = 'com.sanetra.assistivevision',
  String arch = 'arm64-v8a',
  String sha256 =
      '0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF',
}) {
  return '''
{
  "version": "$version",
  "versionCode": $versionCode,
  "minimumSupportedVersionCode": $minSupported,
  "packageName": "$packageName",
  "platform": "android",
  "architecture": "$arch",
  "releaseType": "stable",
  "apkAsset": "Sanetra-v$version-arm64.apk",
  "sha256": "$sha256",
  "releaseNotes": "Bug fixes and improvements.",
  "releaseUrl": "https://github.com/chethanone/Sanetra/releases/tag/v$version"
}
''';
}

const _installedV1 = InstalledAppInfo(
  packageName: 'com.sanetra.assistivevision',
  versionName: '2.0.0',
  versionCode: 2,
  supportedAbis: ['arm64-v8a', 'armeabi-v7a'],
);

void main() {
  group('Phase 6.0 AppUpdateService', () {
    test('Offline startup returns offline status without throwing', () async {
      final svc = AppUpdateService(
        checkConnectivity: () async => false,
        getInstalledAppInfo: () async => _installedV1,
        fetchManifest: (_, _) async => throw StateError('Should not fetch offline'),
      );
      final res = await svc.checkForUpdate(force: true);
      expect(res.status, UpdateCheckStatus.offline);
      await svc.dispose();
    });

    test('Same or lower versionCode returns upToDate (no popup)', () async {
      final svc = AppUpdateService(
        checkConnectivity: () async => true,
        getInstalledAppInfo: () async => _installedV1,
        fetchManifest: (_, _) async => _validManifestJson(version: '1.0.0', versionCode: 1),
      );
      final res = await svc.checkForUpdate(force: true);
      expect(res.status, UpdateCheckStatus.upToDate);
      await svc.dispose();
    });

    test('Package mismatch classifies as migrationAvailable rather than in-place update', () async {
      final svc = AppUpdateService(
        checkConnectivity: () async => true,
        getInstalledAppInfo: () async => const InstalledAppInfo(
          packageName: 'com.visionassistant.vision_assistant.visionmission',
          versionName: '1.0.0',
          versionCode: 1,
          supportedAbis: ['arm64-v8a'],
        ),
        fetchManifest: (_, _) async => _validManifestJson(
          version: '2.0.0',
          versionCode: 2,
          minSupported: 1,
          packageName: 'com.sanetra.assistivevision',
        ),
      );
      final res = await svc.checkForUpdate(force: true);
      expect(res.status, UpdateCheckStatus.migrationAvailable);
      await svc.dispose();
    });

    test('Migration install passes the target Sanetra package to Android installer', () async {
      final tempDir = await Directory.systemTemp.createTemp('sanetra_migration_');
      try {
        final manifest = UpdateManifest.tryParse(
          _validManifestJson(
            version: '2.0.0',
            versionCode: 2,
            minSupported: 1,
            packageName: 'com.sanetra.assistivevision',
          ),
        )!;
        String? installerTargetPackage;
        final svc = AppUpdateService(
          getCacheDir: () async => tempDir,
          downloadApk: (_, dest, _, _) async => dest.writeAsBytes([1, 2, 3]),
          computeSha256: (_) async => manifest.sha256,
          launchInstaller: (path, expectedPackageName) async {
            installerTargetPackage = expectedPackageName;
            return {'started': true, 'isMigration': true};
          },
        );

        final res = await svc.downloadAndInstall(manifest);
        expect(res.success, isTrue);
        expect(installerTargetPackage, 'com.sanetra.assistivevision');
        await svc.dispose();
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('Higher compatible versionCode returns updateAvailable', () async {
      final svc = AppUpdateService(
        checkConnectivity: () async => true,
        getInstalledAppInfo: () async => _installedV1,
        fetchManifest: (_, _) async => _validManifestJson(version: '2.0.1', versionCode: 3),
      );
      final res = await svc.checkForUpdate(force: true);
      expect(res.status, UpdateCheckStatus.updateAvailable);
      expect(res.manifest?.version, '2.0.1');
      await svc.dispose();
    });

    test('Malformed manifest or untrusted URL returns invalidManifest', () async {
      final badJson = AppUpdateService(
        checkConnectivity: () async => true,
        getInstalledAppInfo: () async => _installedV1,
        fetchManifest: (_, _) async => '{"version": "1.0.1"}',
      );
      expect((await badJson.checkForUpdate(force: true)).status, UpdateCheckStatus.invalidManifest);

      final badUrl = AppUpdateService(
        checkConnectivity: () async => true,
        getInstalledAppInfo: () async => _installedV1,
        fetchManifest: (_, _) async => '''
{
  "version": "1.0.1",
  "versionCode": 2,
  "minimumSupportedVersionCode": 1,
  "platform": "android",
  "architecture": "arm64-v8a",
  "releaseType": "stable",
  "apkAsset": "Sanetra.apk",
  "sha256": "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
  "releaseNotes": "x",
  "releaseUrl": "https://evil.example.com/Sanetra"
}''',
      );
      expect((await badUrl.checkForUpdate(force: true)).status, UpdateCheckStatus.invalidManifest);
      await badJson.dispose();
      await badUrl.dispose();
    });

    test('Network timeout returns networkError gracefully', () async {
      final svc = AppUpdateService(
        checkConnectivity: () async => true,
        getInstalledAppInfo: () async => _installedV1,
        fetchManifest: (_, _) async => throw TimeoutException('Request timed out'),
      );
      final res = await svc.checkForUpdate(force: true);
      expect(res.status, UpdateCheckStatus.networkError);
      await svc.dispose();
    });

    test('Unsupported architecture or minSupportedVersion returns incompatible', () async {
      final badArch = AppUpdateService(
        checkConnectivity: () async => true,
        getInstalledAppInfo: () async => _installedV1,
        fetchManifest: (_, _) async => _validManifestJson(arch: 'x86_64'),
      );
      expect((await badArch.checkForUpdate(force: true)).status, UpdateCheckStatus.incompatible);

      final tooOld = AppUpdateService(
        checkConnectivity: () async => true,
        getInstalledAppInfo: () async => _installedV1,
        fetchManifest: (_, _) async => _validManifestJson(versionCode: 5, minSupported: 3),
      );
      expect((await tooOld.checkForUpdate(force: true)).status, UpdateCheckStatus.incompatible);
      await badArch.dispose();
      await tooOld.dispose();
    });

    test('Invalid checksum deletes downloaded APK and fails verification', () async {
      final tempDir = await Directory.systemTemp.createTemp('sanetra_upd_bad_');
      try {
        final manifest = UpdateManifest.tryParse(_validManifestJson())!;
        final svc = AppUpdateService(
          getCacheDir: () async => tempDir,
          downloadApk: (_, dest, onProg, _) async {
            await dest.writeAsBytes([1, 2, 3, 4]);
            onProg?.call(1.0);
          },
          computeSha256: (_) async => 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF',
          launchInstaller: (_, _) async => {'started': true},
        );

        final res = await svc.downloadAndInstall(manifest);
        expect(res.success, isFalse);
        expect(res.error, contains('checksum'));
        expect(await File('${tempDir.path}/${manifest.apkAsset}').exists(), isFalse);
        await svc.dispose();
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('Valid download + checksum launches installer; handles permission & cancellation', () async {
      final tempDir = await Directory.systemTemp.createTemp('sanetra_upd_ok_');
      try {
        final manifest = UpdateManifest.tryParse(_validManifestJson())!;

        final svcOk = AppUpdateService(
          getCacheDir: () async => tempDir,
          downloadApk: (_, dest, onProg, _) async {
            await dest.writeAsBytes([10, 20, 30]);
            onProg?.call(1.0);
          },
          computeSha256: (_) async => manifest.sha256,
          launchInstaller: (_, _) async => {'started': true},
        );
        expect((await svcOk.downloadAndInstall(manifest)).success, isTrue);

        final svcPerm = AppUpdateService(
          getCacheDir: () async => tempDir,
          downloadApk: (_, dest, _, _) async => dest.writeAsBytes([10, 20, 30]),
          computeSha256: (_) async => manifest.sha256,
          launchInstaller: (_, _) async => {'started': false, 'needsInstallPermission': true},
        );
        final permRes = await svcPerm.downloadAndInstall(manifest);
        expect(permRes.success, isFalse);
        expect(permRes.needsInstallPermission, isTrue);

        final svcCancel = AppUpdateService(
          getCacheDir: () async => tempDir,
          downloadApk: (_, dest, _, _) async => dest.writeAsBytes([10, 20, 30]),
          computeSha256: (_) async => manifest.sha256,
          launchInstaller: (_, _) async => {'started': false},
        );
        final cancelRes = await svcCancel.downloadAndInstall(manifest);
        expect(cancelRes.success, isFalse);
        expect(cancelRes.installerCancelled, isTrue);

        await svcOk.dispose();
        await svcPerm.dispose();
        await svcCancel.dispose();
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    testWidgets('UpdatePromptDialog renders accessible controls and Later dismisses', (tester) async {
      final manifest = UpdateManifest.tryParse(_validManifestJson())!;
      var dismissed = false;
      final svc = AppUpdateService(
        launchInstaller: (_, _) async => {'started': true},
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: ctx,
                  builder: (_) => UpdatePromptDialog(
                    manifest: manifest,
                    updateService: svc,
                    onLater: () {
                      dismissed = true;
                      svc.dismissVersion(manifest.versionCode);
                    },
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('A new Sanetra update is available'), findsOneWidget);
      expect(find.text('Version: 2.0.1'), findsOneWidget);
      expect(find.text('Update now'), findsOneWidget);
      expect(find.text('Later'), findsOneWidget);

      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();

      expect(dismissed, isTrue);
      expect(svc.isVersionDismissed(3), isTrue);
      await svc.dispose();
    });
  });
}
