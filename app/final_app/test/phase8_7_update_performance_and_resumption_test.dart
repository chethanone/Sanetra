import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vision_assistant/services/app_update_service.dart';
import 'package:vision_assistant/widgets/update_prompt_dialog.dart';

String _validManifestJson({
  String version = '2.1.2',
  int versionCode = 9,
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
  "releaseNotes": "Performance optimizations and install resumption.",
  "releaseUrl": "https://github.com/chethanone/Sanetra/releases/tag/v$version"
}
''';
}

const _installedCandidate = InstalledAppInfo(
  packageName: 'com.sanetra.assistivevision',
  versionName: '2.1.1',
  versionCode: 8,
  supportedAbis: ['arm64-v8a'],
);

class _MockDialogUpdateService extends AppUpdateService {
  _MockDialogUpdateService({
    this.canInstall = false,
  });

  bool canInstall;
  bool installerLaunched = false;
  int downloadCallCount = 0;
  int resumeCallCount = 0;

  @override
  Future<PendingUpdateInstall?> getPendingInstall() async => null;

  @override
  Future<bool> canRequestPackageInstalls() async => canInstall;

  @override
  Future<UpdateDownloadResult> downloadAndInstall(
    UpdateManifest manifest, {
    void Function(double progress)? onProgress,
    void Function(UpdateProgressStage stage)? onStageChanged,
  }) async {
    downloadCallCount++;
    if (!canInstall) {
      onStageChanged?.call(UpdateProgressStage.waitingForPermission);
      return const UpdateDownloadResult(
        success: false,
        needsInstallPermission: true,
        error: 'Install unknown apps permission required',
      );
    }
    installerLaunched = true;
    onStageChanged?.call(UpdateProgressStage.installerOpened);
    return const UpdateDownloadResult(success: true);
  }

  @override
  Future<UpdateDownloadResult> resumePendingInstallIfPermitted({
    void Function(UpdateProgressStage stage)? onStageChanged,
  }) async {
    resumeCallCount++;
    if (!canInstall) {
      return const UpdateDownloadResult(
        success: false,
        needsInstallPermission: true,
      );
    }
    installerLaunched = true;
    onStageChanged?.call(UpdateProgressStage.installerOpened);
    return const UpdateDownloadResult(success: true);
  }
}

void main() {
  group('Phase 8.7 Download Performance & Throttling', () {
    test('ThrottledProgressReporter limits callback rate and emits initial/final', () {
      final progressValues = <double>[];
      var fakeTime = DateTime(2026, 11, 19, 12, 0, 0);

      final throttler = ThrottledProgressReporter(
        onProgress: progressValues.add,
        minInterval: const Duration(milliseconds: 250),
        minDelta: 0.005,
        now: () => fakeTime,
      );

      // Report initial
      throttler.reportInitial();
      expect(progressValues, [0.0]);

      // Burst of 100 rapid chunks in 100ms
      for (var i = 1; i <= 100; i++) {
        fakeTime = fakeTime.add(const Duration(milliseconds: 1));
        throttler.report(i / 1000.0); // 0.001 to 0.100
      }
      // None of the rapid burst should have emitted because < 250ms elapsed
      expect(progressValues.length, 1);

      // Advance time by 250ms and report progress change >= 0.5%
      fakeTime = fakeTime.add(const Duration(milliseconds: 250));
      throttler.report(0.25);
      expect(progressValues, [0.0, 0.25]);

      // Advance time by 250ms again and report 0.50
      fakeTime = fakeTime.add(const Duration(milliseconds: 250));
      throttler.report(0.50);
      expect(progressValues, [0.0, 0.25, 0.50]);

      // Sub-delta change (< 0.5%) even if time passed should be filtered
      fakeTime = fakeTime.add(const Duration(milliseconds: 300));
      throttler.report(0.502);
      expect(progressValues.length, 3);

      // Identical percentage should not be emitted repeatedly
      throttler.report(0.508); // floor is still 50%
      expect(progressValues.length, 3);

      // Final completion always emits 1.0
      throttler.reportFinal();
      expect(progressValues.last, 1.0);
    });

    test('Sustained download has no more than 4 callbacks per second', () {
      final progressValues = <double>[];
      var fakeTime = DateTime(2026, 11, 19, 12, 0, 0);

      final throttler = ThrottledProgressReporter(
        onProgress: progressValues.add,
        minInterval: const Duration(milliseconds: 250),
        minDelta: 0.005,
        now: () => fakeTime,
      );

      throttler.reportInitial();

      // Simulate 1 second of heavy chunks (1,000 chunks over 1,000 ms)
      for (var ms = 1; ms <= 1000; ms++) {
        fakeTime = fakeTime.add(const Duration(milliseconds: 1));
        throttler.report(ms / 1000.0);
      }
      throttler.reportFinal();

      // Over 1 second with 250ms intervals: initial (0.0), ~250ms, ~500ms, ~750ms, ~1000ms, final (1.0)
      // Total callback count must not exceed 6 (at most 4 updates/sec steady state)
      expect(progressValues.length, inInclusiveRange(4, 6));
      expect(progressValues.first, 0.0);
      expect(progressValues.last, 1.0);
    });

    test('Indeterminate progress handled when content length is unknown', () {
      final progressValues = <double>[];
      var fakeTime = DateTime(2026, 11, 19, 12, 0, 0);

      final throttler = ThrottledProgressReporter(
        onProgress: progressValues.add,
        minInterval: const Duration(milliseconds: 250),
        now: () => fakeTime,
      );

      throttler.reportInitial();
      throttler.report(-1.0);
      expect(progressValues, [0.0, -1.0]);

      // Throttles repeated indeterminate callbacks
      fakeTime = fakeTime.add(const Duration(milliseconds: 100));
      throttler.report(-1.0);
      expect(progressValues.length, 2);

      fakeTime = fakeTime.add(const Duration(milliseconds: 200));
      throttler.report(-1.0);
      expect(progressValues.length, 3);
    });

    test('Download errors clean up incomplete partial files', () async {
      final tempDir = await Directory.systemTemp.createTemp('sanetra_stream_err_');
      try {
        final manifest = UpdateManifest.tryParse(_validManifestJson())!;
        final svc = AppUpdateService(
          getCacheDir: () async => tempDir,
          downloadApk: (_, dest, _, _) async {
            await dest.writeAsBytes([1, 2, 3, 4, 5]);
            throw const SocketException('Connection lost during APK stream');
          },
          computeSha256: (_) async => manifest.sha256,
          launchInstaller: (_, _) async => {'started': true},
        );

        final res = await svc.downloadAndInstall(manifest);
        expect(res.success, isFalse);
        expect(res.error, contains('SocketException'));

        final destFile = File('${tempDir.path}/${manifest.apkAsset}');
        expect(await destFile.exists(), isFalse,
            reason: 'Incomplete file must be deleted on error');
        await svc.dispose();
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });

  group('Phase 8.7 Pending Installation & Automatic Resumption', () {
    test('Missing permission preserves verified APK without re-downloading', () async {
      final tempDir = await Directory.systemTemp.createTemp('sanetra_pending_ok_');
      try {
        final manifest = UpdateManifest.tryParse(_validManifestJson())!;
        var downloadCount = 0;
        var shaCount = 0;
        var installerCalls = 0;
        var permissionGranted = false;

        final svc = AppUpdateService(
          getCacheDir: () async => tempDir,
          canRequestPackageInstalls: () async => permissionGranted,
          downloadApk: (_, dest, onProg, _) async {
            downloadCount++;
            await dest.writeAsBytes([10, 20, 30, 40]);
            onProg?.call(1.0);
          },
          computeSha256: (_) async {
            shaCount++;
            return manifest.sha256;
          },
          launchInstaller: (path, pkg) async {
            installerCalls++;
            return {'started': true};
          },
        );

        // 1. Initial attempt: permission is NOT granted
        final firstRes = await svc.downloadAndInstall(manifest);
        expect(firstRes.success, isFalse);
        expect(firstRes.needsInstallPermission, isTrue);
        expect(downloadCount, 1);
        expect(shaCount, 1);
        expect(installerCalls, 0);

        // Verified APK must still exist in cache
        final cachedApk = File('${tempDir.path}/${manifest.apkAsset}');
        expect(await cachedApk.exists(), isTrue);

        // Pending install metadata must exist
        final pending = await svc.getPendingInstall();
        expect(pending, isNotNull);
        expect(pending?.versionCode, manifest.versionCode);
        expect(pending?.permissionRequired, isTrue);
        expect(pending?.verifiedFileSize, 4);

        // 2. User returns from Settings: permission is now GRANTED
        permissionGranted = true;

        // Call resumePendingInstallIfPermitted()
        final resumeRes = await svc.resumePendingInstallIfPermitted();
        expect(resumeRes.success, isTrue);
        expect(installerCalls, 1);

        // ZERO additional downloads or SHA hashing!
        expect(downloadCount, 1, reason: 'Must not redownload the APK');
        expect(shaCount, 1, reason: 'Must not re-hash 421MB if app remained in memory');

        await svc.dispose();
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('Calling downloadAndInstall again with existing verified APK reuses it', () async {
      final tempDir = await Directory.systemTemp.createTemp('sanetra_reuse_ok_');
      try {
        final manifest = UpdateManifest.tryParse(_validManifestJson())!;
        var downloadCount = 0;
        var permissionGranted = false;

        final svc = AppUpdateService(
          getCacheDir: () async => tempDir,
          canRequestPackageInstalls: () async => permissionGranted,
          downloadApk: (_, dest, onProg, _) async {
            downloadCount++;
            await dest.writeAsBytes([1, 2, 3]);
            onProg?.call(1.0);
          },
          computeSha256: (_) async => manifest.sha256,
          launchInstaller: (_, _) async => {'started': true},
        );

        // Download and verify, but permission required
        await svc.downloadAndInstall(manifest);
        expect(downloadCount, 1);

        // Permission now granted
        permissionGranted = true;

        // User taps "Update now" or triggers downloadAndInstall again
        final secondRes = await svc.downloadAndInstall(manifest);
        expect(secondRes.success, isTrue);
        expect(downloadCount, 1, reason: 'Existing verified APK was reused without re-downloading');

        await svc.dispose();
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('Process restoration: validates metadata and re-checks SHA-256 before resuming', () async {
      final tempDir = await Directory.systemTemp.createTemp('sanetra_restore_ok_');
      try {
        final manifest = UpdateManifest.tryParse(_validManifestJson())!;
        final apkFile = File('${tempDir.path}/${manifest.apkAsset}');
        await apkFile.writeAsBytes([1, 2, 3, 4, 5, 6]);

        final metaFile = File('${tempDir.path}/pending_install.json');
        final metadata = PendingUpdateInstall(
          apkPath: apkFile.path,
          apkAsset: manifest.apkAsset,
          version: manifest.version,
          versionCode: manifest.versionCode,
          expectedPackageName: 'com.sanetra.assistivevision',
          expectedSha256: manifest.sha256,
          verifiedFileSize: 6,
          verifiedAt: DateTime.now(),
          permissionRequired: true,
          installerLaunched: false,
        );
        await metaFile.writeAsString(jsonEncode(metadata.toJson()));

        var shaRecheckCount = 0;
        final freshSvc = AppUpdateService(
          getCacheDir: () async => tempDir,
          getInstalledAppInfo: () async => _installedCandidate,
          canRequestPackageInstalls: () async => true,
          computeSha256: (path) async {
            shaRecheckCount++;
            return manifest.sha256;
          },
          launchInstaller: (_, _) async => {'started': true},
        );

        final restored = await freshSvc.validateRestoredPendingInstall();
        expect(restored, isNotNull);
        expect(restored?.versionCode, manifest.versionCode);
        expect(shaRecheckCount, 1, reason: 'Process restart must revalidate SHA-256');

        final res = await freshSvc.resumePendingInstallIfPermitted();
        expect(res.success, isTrue);

        await freshSvc.dispose();
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('Process restoration: rejects tampered or modified APK files', () async {
      final tempDir = await Directory.systemTemp.createTemp('sanetra_tamper_bad_');
      try {
        final manifest = UpdateManifest.tryParse(_validManifestJson())!;
        final apkFile = File('${tempDir.path}/${manifest.apkAsset}');
        await apkFile.writeAsBytes([1, 2, 3, 4]);

        final metaFile = File('${tempDir.path}/pending_install.json');
        final metadata = PendingUpdateInstall(
          apkPath: apkFile.path,
          apkAsset: manifest.apkAsset,
          version: manifest.version,
          versionCode: manifest.versionCode,
          expectedPackageName: 'com.sanetra.assistivevision',
          expectedSha256: manifest.sha256,
          verifiedFileSize: 4,
          verifiedAt: DateTime.now(),
          permissionRequired: true,
          installerLaunched: false,
        );
        await metaFile.writeAsString(jsonEncode(metadata.toJson()));

        // Simulate tampering: file content changed so SHA mismatches
        final svc = AppUpdateService(
          getCacheDir: () async => tempDir,
          getInstalledAppInfo: () async => _installedCandidate,
          canRequestPackageInstalls: () async => true,
          computeSha256: (_) async => 'BAD_HASH_123456789012345678901234567890123456789012345678901234567890',
        );

        final restored = await svc.validateRestoredPendingInstall();
        expect(restored, isNull);
        expect(await metaFile.exists(), isFalse, reason: 'Corrupt metadata must be deleted');
        expect(await apkFile.exists(), isFalse, reason: 'Tampered APK must be deleted');

        await svc.dispose();
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('Process restoration: rejects paths outside Sanetra private cache directory', () async {
      final tempDir = await Directory.systemTemp.createTemp('sanetra_path_bad_');
      final outsideDir = await Directory.systemTemp.createTemp('sanetra_outside_');
      try {
        final manifest = UpdateManifest.tryParse(_validManifestJson())!;
        final outsideApk = File('${outsideDir.path}/fake.apk');
        await outsideApk.writeAsBytes([1, 2, 3]);

        final metaFile = File('${tempDir.path}/pending_install.json');
        final metadata = PendingUpdateInstall(
          apkPath: outsideApk.path, // path traversal attempt outside cache
          apkAsset: manifest.apkAsset,
          version: manifest.version,
          versionCode: manifest.versionCode,
          expectedPackageName: 'com.sanetra.assistivevision',
          expectedSha256: manifest.sha256,
          verifiedFileSize: 3,
          verifiedAt: DateTime.now(),
        );
        await metaFile.writeAsString(jsonEncode(metadata.toJson()));

        final svc = AppUpdateService(
          getCacheDir: () async => tempDir,
          getInstalledAppInfo: () async => _installedCandidate,
          computeSha256: (_) async => manifest.sha256,
        );

        final restored = await svc.validateRestoredPendingInstall();
        expect(restored, isNull);
        expect(await metaFile.exists(), isFalse);

        await svc.dispose();
      } finally {
        await tempDir.delete(recursive: true);
        await outsideDir.delete(recursive: true);
      }
    });

    test('cleanupInstalledOrStaleUpdates removes APK and metadata once upgraded', () async {
      final tempDir = await Directory.systemTemp.createTemp('sanetra_cleanup_');
      try {
        final manifest = UpdateManifest.tryParse(_validManifestJson())!;
        final apkFile = File('${tempDir.path}/${manifest.apkAsset}');
        await apkFile.writeAsBytes([1, 2, 3]);

        final metaFile = File('${tempDir.path}/pending_install.json');
        final metadata = PendingUpdateInstall(
          apkPath: apkFile.path,
          apkAsset: manifest.apkAsset,
          version: manifest.version,
          versionCode: manifest.versionCode, // 9
          expectedPackageName: 'com.sanetra.assistivevision',
          expectedSha256: manifest.sha256,
          verifiedFileSize: 3,
          verifiedAt: DateTime.now(),
        );
        await metaFile.writeAsString(jsonEncode(metadata.toJson()));

        final svc = AppUpdateService(getCacheDir: () async => tempDir);

        // App running version code 9 (same or higher than pending)
        await svc.cleanupInstalledOrStaleUpdates(const InstalledAppInfo(
          packageName: 'com.sanetra.assistivevision',
          versionName: '2.1.2',
          versionCode: 9,
          supportedAbis: ['arm64-v8a'],
        ));

        expect(await metaFile.exists(), isFalse);
        expect(await apkFile.exists(), isFalse);

        await svc.dispose();
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });

  group('Phase 8.7 UpdatePromptDialog Lifecycle & Auto-Resume UI', () {
    testWidgets('Dialog automatically resumes and launches installer when permission granted upon return', (tester) async {
      final manifest = UpdateManifest.tryParse(_validManifestJson())!;
      final svc = _MockDialogUpdateService(canInstall: false);

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
                    onLater: () {},
                  ),
                ),
                child: const Text('OpenDialog'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('OpenDialog'));
      await tester.pumpAndSettle();

      expect(find.text('A new Sanetra update is available'), findsOneWidget);
      expect(find.text('Update now'), findsOneWidget);

      // Tap "Update now"
      await tester.tap(find.text('Update now'));
      await tester.pump();
      await tester.pump();

      // Permission needed: shows warning and Open Settings / Continue installation buttons
      expect(find.text('Open Settings'), findsOneWidget);
      expect(find.text('Continue installation'), findsOneWidget);
      expect(svc.installerLaunched, isFalse);
      expect(svc.downloadCallCount, 1);

      // User goes to Settings, enables permission, returns (resumed)
      svc.canInstall = true;
      final state =
          tester.state(find.byType(UpdatePromptDialog)) as WidgetsBindingObserver;
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();

      // Installer should have been launched automatically!
      expect(svc.installerLaunched, isTrue);
      expect(svc.resumeCallCount, 1);

      await tester.pumpAndSettle();
    });

    testWidgets('Dialog retains state and explains permission if user returns without granting', (tester) async {
      final manifest = UpdateManifest.tryParse(_validManifestJson())!;
      final svc = _MockDialogUpdateService(canInstall: false);

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
                    onLater: () {},
                  ),
                ),
                child: const Text('OpenDialog'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('OpenDialog'));
      await tester.pumpAndSettle();

      // Tap "Update now"
      await tester.tap(find.text('Update now'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Open Settings'), findsOneWidget);
      expect(find.text('Continue installation'), findsOneWidget);

      // User returns without granting permission
      final state =
          tester.state(find.byType(UpdatePromptDialog)) as WidgetsBindingObserver;
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();

      // Dialog remains open, installer was NOT launched
      expect(svc.installerLaunched, isFalse);
      expect(find.text('Open Settings'), findsOneWidget);
      expect(find.text('Continue installation'), findsOneWidget);

      // Tapping Continue installation manually checks again
      await tester.tap(find.text('Continue installation'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Permission is still disabled in Settings'), findsOneWidget);
      expect(svc.installerLaunched, isFalse);

      await tester.pumpWidget(const SizedBox());
    });
  });
}
