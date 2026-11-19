import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum UpdateCheckStatus {
  offline,
  throttled,
  busy,
  upToDate,
  updateAvailable,
  migrationAvailable,
  incompatible,
  invalidManifest,
  networkError,
}

class InstalledAppInfo {
  const InstalledAppInfo({
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    required this.supportedAbis,
  });

  final String packageName;
  final String versionName;
  final int versionCode;
  final List<String> supportedAbis;
}

class UpdateManifest {
  const UpdateManifest({
    required this.version,
    required this.versionCode,
    required this.minimumSupportedVersionCode,
    required this.platform,
    required this.architecture,
    required this.releaseType,
    required this.apkAsset,
    required this.sha256,
    required this.releaseNotes,
    required this.releaseUrl,
    this.packageName,
    this.downloadUrl,
  });

  final String version;
  final int versionCode;
  final int minimumSupportedVersionCode;
  final String platform;
  final String architecture;
  final String releaseType;
  final String apkAsset;
  final String sha256;
  final String releaseNotes;
  final String releaseUrl;
  final String? packageName;
  final String? downloadUrl;

  static const String sanetraPackageName = 'com.sanetra.assistivevision';
  static final RegExp _sha256Regex = RegExp(r'^[A-Fa-f0-9]{64}$');

  static bool isTrustedHttpsUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    if (host == 'github.com' ||
        host == 'raw.githubusercontent.com' ||
        host == 'objects.githubusercontent.com') {
      return uri.path.toLowerCase().contains('/chethanone/sanetra');
    }
    return false;
  }

  String get resolvedDownloadUrl {
    if (downloadUrl != null && downloadUrl!.trim().isNotEmpty) {
      return downloadUrl!.trim();
    }
    return 'https://github.com/chethanone/Sanetra/releases/download/v$version/$apkAsset';
  }

  static UpdateManifest? tryParse(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map<String, dynamic>) return null;

      final version = (decoded['version'] as String?)?.trim() ?? '';
      final versionCode = decoded['versionCode'];
      final minSupported = decoded['minimumSupportedVersionCode'];
      final platform = (decoded['platform'] as String?)?.trim().toLowerCase() ?? '';
      final arch = (decoded['architecture'] as String?)?.trim() ?? '';
      final releaseType = (decoded['releaseType'] as String?)?.trim() ?? 'stable';
      final apkAsset = (decoded['apkAsset'] as String?)?.trim() ?? '';
      final sha256 = (decoded['sha256'] as String?)?.trim() ?? '';
      final releaseNotes = (decoded['releaseNotes'] as String?)?.trim() ?? '';
      final releaseUrl = (decoded['releaseUrl'] as String?)?.trim() ?? '';
      final packageName = (decoded['packageName'] as String?)?.trim();
      final downloadUrl = (decoded['downloadUrl'] as String?)?.trim();

      if (version.isEmpty ||
          versionCode is! int ||
          versionCode <= 0 ||
          minSupported is! int ||
          minSupported < 1 ||
          platform != 'android' ||
          arch.isEmpty ||
          apkAsset.isEmpty ||
          !apkAsset.endsWith('.apk') ||
          !_sha256Regex.hasMatch(sha256) ||
          (packageName != null && packageName.isNotEmpty && packageName != sanetraPackageName) ||
          !isTrustedHttpsUrl(releaseUrl)) {
        return null;
      }

      if (downloadUrl != null &&
          downloadUrl.isNotEmpty &&
          !isTrustedHttpsUrl(downloadUrl)) {
        return null;
      }

      final manifest = UpdateManifest(
        version: version,
        versionCode: versionCode,
        minimumSupportedVersionCode: minSupported,
        platform: platform,
        architecture: arch,
        releaseType: releaseType,
        apkAsset: apkAsset,
        sha256: sha256.toUpperCase(),
        releaseNotes: releaseNotes,
        releaseUrl: releaseUrl,
        packageName: (packageName != null && packageName.isNotEmpty)
            ? packageName
            : null,
        downloadUrl: downloadUrl,
      );

      if (!isTrustedHttpsUrl(manifest.resolvedDownloadUrl)) {
        return null;
      }
      return manifest;
    } catch (_) {
      return null;
    }
  }
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.status,
    this.manifest,
    this.installed,
    this.reason,
  });

  final UpdateCheckStatus status;
  final UpdateManifest? manifest;
  final InstalledAppInfo? installed;
  final String? reason;
}

class UpdateDownloadResult {
  const UpdateDownloadResult({
    required this.success,
    this.filePath,
    this.error,
    this.needsInstallPermission = false,
    this.installerCancelled = false,
  });

  final bool success;
  final String? filePath;
  final String? error;
  final bool needsInstallPermission;
  final bool installerCancelled;
}

enum UpdateProgressStage {
  preparing,
  downloading,
  verifying,
  downloadComplete,
  waitingForPermission,
  openingInstaller,
  installerOpened,
  failed,
}

class ThrottledProgressReporter {
  ThrottledProgressReporter({
    required this.onProgress,
    this.minInterval = const Duration(milliseconds: 250),
    this.minDelta = 0.005, // 0.5 percentage points
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final void Function(double progress) onProgress;
  final Duration minInterval;
  final double minDelta;
  final DateTime Function() _now;

  DateTime? _lastReportTime;
  double _lastReportedProgress = -1.0;
  int _lastReportedPercentage = -1;
  bool _hasReportedInitial = false;

  void reportInitial() {
    if (!_hasReportedInitial) {
      _hasReportedInitial = true;
      _lastReportedProgress = 0.0;
      _lastReportedPercentage = 0;
      _lastReportTime = _now();
      onProgress(0.0);
    }
  }

  void report(double progress) {
    if (!_hasReportedInitial) {
      reportInitial();
    }
    if (progress < 0) {
      final now = _now();
      if (_lastReportedProgress != -1.0 ||
          _lastReportTime == null ||
          now.difference(_lastReportTime!) >= minInterval) {
        _lastReportTime = now;
        _lastReportedProgress = -1.0;
        onProgress(-1.0);
      }
      return;
    }

    final clamped = progress.clamp(0.0, 1.0);
    final percentage = (clamped * 100).floor();
    final now = _now();

    if (_lastReportTime == null) {
      _lastReportTime = now;
      _lastReportedProgress = clamped;
      _lastReportedPercentage = percentage;
      onProgress(clamped);
      return;
    }

    final elapsed = now.difference(_lastReportTime!);
    final delta = (clamped - _lastReportedProgress).abs();

    if (elapsed >= minInterval && delta >= minDelta && percentage != _lastReportedPercentage) {
      _lastReportTime = now;
      _lastReportedProgress = clamped;
      _lastReportedPercentage = percentage;
      onProgress(clamped);
    }
  }

  void reportFinal() {
    if (!_hasReportedInitial) {
      reportInitial();
    }
    if (_lastReportedProgress != 1.0) {
      _lastReportedProgress = 1.0;
      _lastReportedPercentage = 100;
      _lastReportTime = _now();
      onProgress(1.0);
    }
  }
}

class PendingUpdateInstall {
  const PendingUpdateInstall({
    required this.apkPath,
    required this.apkAsset,
    required this.version,
    required this.versionCode,
    required this.expectedPackageName,
    required this.expectedSha256,
    required this.verifiedFileSize,
    required this.verifiedAt,
    this.permissionRequired = false,
    this.installerLaunched = false,
  });

  final String apkPath;
  final String apkAsset;
  final String version;
  final int versionCode;
  final String expectedPackageName;
  final String expectedSha256;
  final int verifiedFileSize;
  final DateTime verifiedAt;
  final bool permissionRequired;
  final bool installerLaunched;

  PendingUpdateInstall copyWith({
    String? apkPath,
    String? apkAsset,
    String? version,
    int? versionCode,
    String? expectedPackageName,
    String? expectedSha256,
    int? verifiedFileSize,
    DateTime? verifiedAt,
    bool? permissionRequired,
    bool? installerLaunched,
  }) {
    return PendingUpdateInstall(
      apkPath: apkPath ?? this.apkPath,
      apkAsset: apkAsset ?? this.apkAsset,
      version: version ?? this.version,
      versionCode: versionCode ?? this.versionCode,
      expectedPackageName: expectedPackageName ?? this.expectedPackageName,
      expectedSha256: expectedSha256 ?? this.expectedSha256,
      verifiedFileSize: verifiedFileSize ?? this.verifiedFileSize,
      verifiedAt: verifiedAt ?? this.verifiedAt,
      permissionRequired: permissionRequired ?? this.permissionRequired,
      installerLaunched: installerLaunched ?? this.installerLaunched,
    );
  }

  Map<String, dynamic> toJson() => {
    'apkPath': apkPath,
    'apkAsset': apkAsset,
    'version': version,
    'versionCode': versionCode,
    'expectedPackageName': expectedPackageName,
    'expectedSha256': expectedSha256,
    'verifiedFileSize': verifiedFileSize,
    'verifiedAt': verifiedAt.toIso8601String(),
    'permissionRequired': permissionRequired,
    'installerLaunched': installerLaunched,
  };

  static PendingUpdateInstall? fromJson(Map<String, dynamic> json) {
    try {
      final apkPath = (json['apkPath'] as String?)?.trim() ?? '';
      final apkAsset = (json['apkAsset'] as String?)?.trim() ?? '';
      final version = (json['version'] as String?)?.trim() ?? '';
      final versionCode = json['versionCode'] as int?;
      final expectedPackageName =
          (json['expectedPackageName'] as String?)?.trim() ?? '';
      final expectedSha256 =
          (json['expectedSha256'] as String?)?.trim().toUpperCase() ?? '';
      final verifiedFileSize = json['verifiedFileSize'] as int?;
      final verifiedAtStr = json['verifiedAt'] as String?;
      final permissionRequired = json['permissionRequired'] as bool? ?? false;
      final installerLaunched = json['installerLaunched'] as bool? ?? false;

      if (apkPath.isEmpty ||
          apkAsset.isEmpty ||
          version.isEmpty ||
          versionCode == null ||
          versionCode <= 0 ||
          expectedPackageName.isEmpty ||
          expectedSha256.isEmpty ||
          verifiedFileSize == null ||
          verifiedFileSize <= 0 ||
          verifiedAtStr == null) {
        return null;
      }

      final verifiedAt = DateTime.tryParse(verifiedAtStr);
      if (verifiedAt == null) return null;

      return PendingUpdateInstall(
        apkPath: apkPath,
        apkAsset: apkAsset,
        version: version,
        versionCode: versionCode,
        expectedPackageName: expectedPackageName,
        expectedSha256: expectedSha256,
        verifiedFileSize: verifiedFileSize,
        verifiedAt: verifiedAt,
        permissionRequired: permissionRequired,
        installerLaunched: installerLaunched,
      );
    } catch (_) {
      return null;
    }
  }
}

typedef ManifestFetcher = Future<String> Function(Uri url, Duration timeout);
typedef ApkInstaller = Future<Map<String, dynamic>> Function(String path, String expectedPackageName);
typedef ApkDownloader = Future<void> Function(
  Uri url,
  File destination,
  void Function(double progress)? onProgress,
  Duration timeout,
);

/// Optional online update checker for Sanetra using GitHub Releases.
/// Never blocks or interferes with offline currency or OCR functionality.
class AppUpdateService {
  AppUpdateService({
    String? manifestUrl,
    this.checkInterval = const Duration(hours: 6),
    this.requestTimeout = const Duration(seconds: 8),
    this.downloadTimeout = const Duration(minutes: 3),
    this.maxApkBytes = 600 * 1024 * 1024,
    Future<bool> Function()? checkConnectivity,
    Stream<bool>? connectivityStream,
    Future<InstalledAppInfo> Function()? getInstalledAppInfo,
    ManifestFetcher? fetchManifest,
    ApkDownloader? downloadApk,
    Future<String?> Function(String path)? computeSha256,
    Future<Directory> Function()? getCacheDir,
    ApkInstaller? launchInstaller,
    Future<void> Function()? openInstallSettings,
    Future<bool> Function()? canRequestPackageInstalls,
    DateTime Function()? now,
  }) : manifestUrl =
           manifestUrl ??
           'https://raw.githubusercontent.com/chethanone/Sanetra/main/update/latest.json',
       _checkConnectivity = checkConnectivity ?? _defaultCheckConnectivity,
       _connectivityStream =
           connectivityStream ?? _defaultConnectivityStream(),
       _getInstalledAppInfo =
           getInstalledAppInfo ?? _defaultGetInstalledAppInfo,
       _fetchManifest = fetchManifest ?? _defaultFetchManifest,
       _downloadApk = downloadApk ?? _defaultDownloadApk,
       _computeSha256 = computeSha256 ?? _defaultComputeSha256,
       _getCacheDir = getCacheDir ?? _defaultGetCacheDir,
       _launchInstaller = launchInstaller ?? _defaultLaunchInstaller,
       _openInstallSettings =
           openInstallSettings ?? _defaultOpenInstallSettings,
       _canRequestPackageInstalls =
           canRequestPackageInstalls ?? _defaultCanRequestPackageInstalls,
       _now = now ?? DateTime.now;

  static const MethodChannel _channel = MethodChannel(
    'vision_assistant/app_update',
  );
  static const EventChannel _connChannel = EventChannel(
    'vision_assistant/connectivity',
  );

  final String manifestUrl;
  final Duration checkInterval;
  final Duration requestTimeout;
  final Duration downloadTimeout;
  final int maxApkBytes;

  final Future<bool> Function() _checkConnectivity;
  final Stream<bool> _connectivityStream;
  final Future<InstalledAppInfo> Function() _getInstalledAppInfo;
  final ManifestFetcher _fetchManifest;
  final ApkDownloader _downloadApk;
  final Future<String?> Function(String path) _computeSha256;
  final Future<Directory> Function() _getCacheDir;
  final ApkInstaller _launchInstaller;
  final Future<void> Function() _openInstallSettings;
  final Future<bool> Function() _canRequestPackageInstalls;
  final DateTime Function() _now;

  PendingUpdateInstall? _pendingInstall;
  bool _isLaunchingInstaller = false;
  StreamSubscription<bool>? _connSub;
  Timer? _debounceTimer;
  bool _isChecking = false;
  bool _isDownloading = false;
  DateTime? _lastCheckedAt;
  final Set<int> _announcedVersionCodes = <int>{};
  final Set<int> _dismissedVersionCodes = <int>{};

  bool get isChecking => _isChecking;
  bool get isDownloading => _isDownloading;
  DateTime? get lastCheckedAt => _lastCheckedAt;

  bool hasAnnouncedVersion(int versionCode) =>
      _announcedVersionCodes.contains(versionCode);

  void markVersionAnnounced(int versionCode) {
    _announcedVersionCodes.add(versionCode);
  }

  void dismissVersion(int versionCode) {
    _dismissedVersionCodes.add(versionCode);
  }

  bool isVersionDismissed(int versionCode) =>
      _dismissedVersionCodes.contains(versionCode);

  void startConnectivityListener({
    required void Function(UpdateCheckResult result) onUpdateFound,
    bool Function()? canCheckNow,
  }) {
    _connSub?.cancel();
    _connSub = _connectivityStream.listen((connected) {
      if (!connected) return;
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(seconds: 2), () async {
        if (canCheckNow != null && !canCheckNow()) return;
        final res = await checkForUpdate();
        if ((res.status == UpdateCheckStatus.updateAvailable ||
                res.status == UpdateCheckStatus.migrationAvailable) &&
            res.manifest != null &&
            !isVersionDismissed(res.manifest!.versionCode)) {
          onUpdateFound(res);
        }
      });
    }, onError: (_) {});
  }

  Future<UpdateCheckResult> checkForUpdate({bool force = false}) async {
    if (_isChecking || _isDownloading) {
      return const UpdateCheckResult(status: UpdateCheckStatus.busy);
    }

    final currentTime = _now();
    if (!force &&
        _lastCheckedAt != null &&
        currentTime.difference(_lastCheckedAt!) < checkInterval) {
      return const UpdateCheckResult(status: UpdateCheckStatus.throttled);
    }

    _isChecking = true;
    try {
      final online = await _checkConnectivity();
      if (!online) {
        return const UpdateCheckResult(status: UpdateCheckStatus.offline);
      }

      if (!UpdateManifest.isTrustedHttpsUrl(manifestUrl)) {
        return const UpdateCheckResult(
          status: UpdateCheckStatus.invalidManifest,
          reason: 'Untrusted manifest URL',
        );
      }

      final raw = await _fetchManifest(Uri.parse(manifestUrl), requestTimeout);
      _lastCheckedAt = _now();

      final manifest = UpdateManifest.tryParse(raw);
      if (manifest == null) {
        return const UpdateCheckResult(
          status: UpdateCheckStatus.invalidManifest,
          reason: 'Malformed or untrusted update manifest',
        );
      }

      final installed = await _getInstalledAppInfo();
      return evaluateManifest(manifest: manifest, installed: installed);
    } catch (e) {
      debugPrint('[APP-UPDATE] Check failed silently: $e');
      return UpdateCheckResult(
        status: UpdateCheckStatus.networkError,
        reason: e.toString(),
      );
    } finally {
      _isChecking = false;
    }
  }

  @visibleForTesting
  static UpdateCheckResult evaluateManifest({
    required UpdateManifest manifest,
    required InstalledAppInfo installed,
  }) {
    if (manifest.versionCode <= installed.versionCode) {
      return UpdateCheckResult(
        status: UpdateCheckStatus.upToDate,
        manifest: manifest,
        installed: installed,
      );
    }
    if (!installed.supportedAbis.contains(manifest.architecture)) {
      return UpdateCheckResult(
        status: UpdateCheckStatus.incompatible,
        manifest: manifest,
        installed: installed,
        reason: 'Unsupported architecture: ${manifest.architecture}',
      );
    }
    if (installed.versionCode < manifest.minimumSupportedVersionCode) {
      return UpdateCheckResult(
        status: UpdateCheckStatus.incompatible,
        manifest: manifest,
        installed: installed,
        reason:
            'Installed versionCode ${installed.versionCode} below minimum ${manifest.minimumSupportedVersionCode}',
      );
    }
    if (manifest.packageName != null &&
        manifest.packageName != installed.packageName) {
      return UpdateCheckResult(
        status: UpdateCheckStatus.migrationAvailable,
        manifest: manifest,
        installed: installed,
        reason:
            'Package identity changed (${installed.packageName} -> ${manifest.packageName}); installs separately.',
      );
    }
    return UpdateCheckResult(
      status: UpdateCheckStatus.updateAvailable,
      manifest: manifest,
      installed: installed,
    );
  }

  Future<bool> canRequestPackageInstalls() => _canRequestPackageInstalls();

  Future<File> _getPendingInstallMetadataFile() async {
    final cacheDir = await _getCacheDir();
    return File('${cacheDir.path}/pending_install.json');
  }

  Future<PendingUpdateInstall?> getPendingInstall() async {
    if (_pendingInstall != null) return _pendingInstall;
    try {
      final metaFile = await _getPendingInstallMetadataFile();
      if (!await metaFile.exists()) return null;
      final content = await metaFile.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) return null;
      _pendingInstall = PendingUpdateInstall.fromJson(decoded);
      return _pendingInstall;
    } catch (_) {
      return null;
    }
  }

  Future<void> savePendingInstall(PendingUpdateInstall pending) async {
    _pendingInstall = pending;
    try {
      final metaFile = await _getPendingInstallMetadataFile();
      if (!await metaFile.parent.exists()) {
        await metaFile.parent.create(recursive: true);
      }
      await metaFile.writeAsString(jsonEncode(pending.toJson()), flush: true);
    } catch (e) {
      debugPrint('[APP-UPDATE] Failed to save pending_install.json: $e');
    }
  }

  Future<void> clearPendingInstall() async {
    _pendingInstall = null;
    try {
      final metaFile = await _getPendingInstallMetadataFile();
      if (await metaFile.exists()) {
        await metaFile.delete();
      }
    } catch (_) {}
  }

  Future<PendingUpdateInstall?> validateRestoredPendingInstall() async {
    final pending = await getPendingInstall();
    if (pending == null) return null;

    try {
      final installed = await _getInstalledAppInfo();
      if (installed.versionCode >= pending.versionCode) {
        await clearPendingInstall();
        final apkFile = File(pending.apkPath);
        if (await apkFile.exists()) {
          try {
            await apkFile.delete();
          } catch (_) {}
        }
        return null;
      }

      final cacheDir = await _getCacheDir();
      final apkFile = File(pending.apkPath);
      if (!await apkFile.exists()) {
        await clearPendingInstall();
        return null;
      }

      final canonicalApk = apkFile.resolveSymbolicLinksSync();
      final canonicalCache = cacheDir.resolveSymbolicLinksSync();
      if (!canonicalApk.startsWith(canonicalCache)) {
        await clearPendingInstall();
        return null;
      }

      final fileSize = await apkFile.length();
      if (fileSize != pending.verifiedFileSize ||
          fileSize <= 0 ||
          fileSize > maxApkBytes) {
        await clearPendingInstall();
        try {
          await apkFile.delete();
        } catch (_) {}
        return null;
      }

      final actualSha = await _computeSha256(apkFile.path);
      if (actualSha == null ||
          actualSha.toUpperCase() != pending.expectedSha256.toUpperCase()) {
        await clearPendingInstall();
        try {
          await apkFile.delete();
        } catch (_) {}
        return null;
      }

      return pending;
    } catch (e) {
      debugPrint('[APP-UPDATE] validateRestoredPendingInstall error: $e');
      await clearPendingInstall();
      return null;
    }
  }

  Future<void> cleanupInstalledOrStaleUpdates(InstalledAppInfo installed) async {
    try {
      final pending = await getPendingInstall();
      if (pending != null && installed.versionCode >= pending.versionCode) {
        final apkFile = File(pending.apkPath);
        if (await apkFile.exists()) {
          try {
            await apkFile.delete();
          } catch (_) {}
        }
        await clearPendingInstall();
      }
    } catch (_) {}
  }

  Future<UpdateDownloadResult> resumePendingInstallIfPermitted({
    void Function(UpdateProgressStage stage)? onStageChanged,
  }) async {
    if (_isLaunchingInstaller || _isDownloading) {
      return const UpdateDownloadResult(
        success: false,
        error: 'Installation already launching or busy',
      );
    }
    _isLaunchingInstaller = true;
    try {
      final pending = _pendingInstall ?? await validateRestoredPendingInstall();
      if (pending == null) {
        onStageChanged?.call(UpdateProgressStage.failed);
        return const UpdateDownloadResult(
          success: false,
          error: 'No valid pending update found',
        );
      }

      final apkFile = File(pending.apkPath);
      if (!await apkFile.exists()) {
        await clearPendingInstall();
        onStageChanged?.call(UpdateProgressStage.failed);
        return const UpdateDownloadResult(
          success: false,
          error: 'Pending APK file missing',
        );
      }

      final permitted = await canRequestPackageInstalls();
      if (!permitted) {
        _pendingInstall = pending.copyWith(permissionRequired: true);
        await savePendingInstall(_pendingInstall!);
        onStageChanged?.call(UpdateProgressStage.waitingForPermission);
        return UpdateDownloadResult(
          success: false,
          filePath: apkFile.path,
          needsInstallPermission: true,
          error: 'Install unknown apps permission required',
        );
      }

      onStageChanged?.call(UpdateProgressStage.openingInstaller);
      final installRes =
          await _launchInstaller(apkFile.path, pending.expectedPackageName);
      final started = installRes['started'] == true;
      final needsPerm = installRes['needsInstallPermission'] == true;
      final err = installRes['error'] as String?;

      if (started) {
        _pendingInstall = pending.copyWith(
          installerLaunched: true,
          permissionRequired: false,
        );
        await savePendingInstall(_pendingInstall!);
        onStageChanged?.call(UpdateProgressStage.installerOpened);
      } else if (needsPerm) {
        _pendingInstall = pending.copyWith(permissionRequired: true);
        await savePendingInstall(_pendingInstall!);
        onStageChanged?.call(UpdateProgressStage.waitingForPermission);
      } else {
        onStageChanged?.call(UpdateProgressStage.failed);
      }

      return UpdateDownloadResult(
        success: started,
        filePath: apkFile.path,
        needsInstallPermission: needsPerm,
        error: started ? null : (err ?? 'Installation was cancelled or failed'),
        installerCancelled: !started && !needsPerm && err == null,
      );
    } catch (e) {
      onStageChanged?.call(UpdateProgressStage.failed);
      return UpdateDownloadResult(success: false, error: e.toString());
    } finally {
      _isLaunchingInstaller = false;
    }
  }

  Future<UpdateDownloadResult> downloadAndInstall(
    UpdateManifest manifest, {
    void Function(double progress)? onProgress,
    void Function(UpdateProgressStage stage)? onStageChanged,
  }) async {
    if (_isDownloading || _isLaunchingInstaller) {
      return const UpdateDownloadResult(
        success: false,
        error: 'Download or install already in progress',
      );
    }

    final urlStr = manifest.resolvedDownloadUrl;
    if (!UpdateManifest.isTrustedHttpsUrl(urlStr)) {
      return const UpdateDownloadResult(
        success: false,
        error: 'Untrusted download URL',
      );
    }

    final expectedPackageName =
        manifest.packageName ?? (await _getInstalledAppInfo()).packageName;
    if (expectedPackageName != UpdateManifest.sanetraPackageName &&
        expectedPackageName != (await _getInstalledAppInfo()).packageName) {
      return const UpdateDownloadResult(
        success: false,
        error: 'Update manifest contains an unsupported target package ID',
      );
    }

    final cacheDir = await _getCacheDir();
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    final destFile = File('${cacheDir.path}/${manifest.apkAsset}');

    // 1. Check if an existing verified APK already exists for this manifest
    final existingPending = _pendingInstall ?? await getPendingInstall();
    bool alreadyVerified = false;
    if (existingPending != null &&
        existingPending.versionCode == manifest.versionCode &&
        existingPending.expectedSha256.toUpperCase() ==
            manifest.sha256.toUpperCase() &&
        existingPending.apkPath == destFile.path &&
        await destFile.exists() &&
        await destFile.length() == existingPending.verifiedFileSize) {
      if (_pendingInstall != null) {
        alreadyVerified = true;
      } else {
        final recheckedSha = await _computeSha256(destFile.path);
        if (recheckedSha != null &&
            recheckedSha.toUpperCase() == manifest.sha256.toUpperCase()) {
          alreadyVerified = true;
          _pendingInstall = existingPending;
        }
      }
    }

    if (alreadyVerified) {
      debugPrint('[APP-UPDATE] Existing verified APK reused without re-downloading.');
      onStageChanged?.call(UpdateProgressStage.downloadComplete);
      return resumePendingInstallIfPermitted(onStageChanged: onStageChanged);
    }

    // 2. Perform download
    _isDownloading = true;
    try {
      onStageChanged?.call(UpdateProgressStage.preparing);
      if (await destFile.exists()) {
        await destFile.delete();
      }

      final throttler = onProgress != null
          ? ThrottledProgressReporter(onProgress: onProgress)
          : null;
      throttler?.reportInitial();

      onStageChanged?.call(UpdateProgressStage.downloading);
      await _downloadApk(
        Uri.parse(urlStr),
        destFile,
        throttler != null ? (p) => throttler.report(p) : null,
        downloadTimeout,
      );
      throttler?.reportFinal();

      if (!await destFile.exists()) {
        onStageChanged?.call(UpdateProgressStage.failed);
        return const UpdateDownloadResult(
          success: false,
          error: 'Downloaded APK file missing',
        );
      }
      final fileSize = await destFile.length();
      if (fileSize <= 0 || fileSize > maxApkBytes) {
        await destFile.delete();
        onStageChanged?.call(UpdateProgressStage.failed);
        return const UpdateDownloadResult(
          success: false,
          error: 'Downloaded APK size invalid or exceeds limit',
        );
      }

      onStageChanged?.call(UpdateProgressStage.verifying);
      final actualSha = await _computeSha256(destFile.path);
      if (actualSha == null ||
          actualSha.toUpperCase() != manifest.sha256.toUpperCase()) {
        await destFile.delete();
        onStageChanged?.call(UpdateProgressStage.failed);
        return const UpdateDownloadResult(
          success: false,
          error: 'APK checksum verification failed',
        );
      }

      onStageChanged?.call(UpdateProgressStage.downloadComplete);
      final newPending = PendingUpdateInstall(
        apkPath: destFile.path,
        apkAsset: manifest.apkAsset,
        version: manifest.version,
        versionCode: manifest.versionCode,
        expectedPackageName: expectedPackageName,
        expectedSha256: manifest.sha256.toUpperCase(),
        verifiedFileSize: fileSize,
        verifiedAt: _now(),
        permissionRequired: false,
        installerLaunched: false,
      );
      await savePendingInstall(newPending);
    } catch (e) {
      debugPrint('[APP-UPDATE] Download error: $e');
      if (await destFile.exists()) {
        try {
          await destFile.delete();
        } catch (_) {}
      }
      onStageChanged?.call(UpdateProgressStage.failed);
      return UpdateDownloadResult(success: false, error: e.toString());
    } finally {
      _isDownloading = false;
    }

    // 3. Launch installation
    return resumePendingInstallIfPermitted(onStageChanged: onStageChanged);
  }

  Future<void> openUnknownSourcesSettings() => _openInstallSettings();

  Future<void> dispose() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await _connSub?.cancel();
    _connSub = null;
  }

  // ------------------------------------------------------------------
  // Default Platform & HTTP Implementations
  // ------------------------------------------------------------------
  static Future<bool> _defaultCheckConnectivity() async {
    try {
      return await _channel.invokeMethod<bool>('hasNetworkConnectivity') ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Stream<bool> _defaultConnectivityStream() {
    return _connChannel.receiveBroadcastStream().map((e) => e == true);
  }

  static Future<InstalledAppInfo> _defaultGetInstalledAppInfo() async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>(
        'getInstalledAppInfo',
      );
      final abis = (map?['supportedAbis'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const ['arm64-v8a'];
      return InstalledAppInfo(
        packageName:
            map?['packageName']?.toString() ?? 'com.sanetra.assistivevision',
        versionName: map?['versionName']?.toString() ?? '2.0.0',
        versionCode: (map?['versionCode'] as num?)?.toInt() ?? 2,
        supportedAbis: abis,
      );
    } catch (_) {
      return const InstalledAppInfo(
        packageName: 'com.sanetra.assistivevision',
        versionName: '2.0.0',
        versionCode: 2,
        supportedAbis: ['arm64-v8a'],
      );
    }
  }

  static Future<String> _defaultFetchManifest(Uri url, Duration timeout) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.getUrl(url).timeout(timeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      return await resp.transform(utf8.decoder).join().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _defaultDownloadApk(
    Uri url,
    File destination,
    void Function(double progress)? onProgress,
    Duration timeout,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(url).timeout(timeout);
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength;
      var received = 0;
      final sink = destination.openWrite();
      try {
        await for (final chunk in resp.timeout(timeout)) {
          sink.add(chunk);
          received += chunk.length;
          if (onProgress != null) {
            if (total > 0) {
              onProgress((received / total).clamp(0.0, 1.0));
            } else {
              onProgress(-1.0);
            }
          }
        }
        await sink.flush();
      } catch (e) {
        try {
          await sink.close();
        } catch (_) {}
        if (await destination.exists()) {
          try {
            await destination.delete();
          } catch (_) {}
        }
        rethrow;
      } finally {
        try {
          await sink.close();
        } catch (_) {}
      }
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> _defaultCanRequestPackageInstalls() async {
    try {
      return await _channel.invokeMethod<bool>('canRequestPackageInstalls') ??
          true;
    } catch (_) {
      return true;
    }
  }

  static Future<String?> _defaultComputeSha256(String path) async {
    try {
      return await _channel.invokeMethod<String>('computeFileSha256', {'path': path});
    } catch (_) {
      return null;
    }
  }

  static Future<Directory> _defaultGetCacheDir() async {
    try {
      final path = await _channel.invokeMethod<String>('getUpdateCacheDir');
      if (path != null && path.isNotEmpty) {
        return Directory(path);
      }
    } catch (_) {}
    return Directory('${Directory.systemTemp.path}/sanetra_updates');
  }

  static Future<Map<String, dynamic>> _defaultLaunchInstaller(
    String path,
    String expectedPackageName,
  ) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('installApk', {
        'path': path,
        'expectedPackageName': expectedPackageName,
      });
      return res ?? <String, dynamic>{'started': false};
    } catch (_) {
      return <String, dynamic>{'started': false};
    }
  }

  static Future<void> _defaultOpenInstallSettings() async {
    try {
      await _channel.invokeMethod<void>('openUnknownSourcesSettings');
    } catch (_) {}
  }
}
