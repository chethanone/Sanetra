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
  final String? downloadUrl;

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

typedef ManifestFetcher = Future<String> Function(Uri url, Duration timeout);
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
    Future<Map<String, dynamic>> Function(String path)? launchInstaller,
    Future<void> Function()? openInstallSettings,
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
  final Future<Map<String, dynamic>> Function(String path) _launchInstaller;
  final Future<void> Function() _openInstallSettings;
  final DateTime Function() _now;

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
        if (res.status == UpdateCheckStatus.updateAvailable &&
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
    return UpdateCheckResult(
      status: UpdateCheckStatus.updateAvailable,
      manifest: manifest,
      installed: installed,
    );
  }

  Future<UpdateDownloadResult> downloadAndInstall(
    UpdateManifest manifest, {
    void Function(double progress)? onProgress,
  }) async {
    if (_isDownloading) {
      return const UpdateDownloadResult(
        success: false,
        error: 'Download already in progress',
      );
    }

    final urlStr = manifest.resolvedDownloadUrl;
    if (!UpdateManifest.isTrustedHttpsUrl(urlStr)) {
      return const UpdateDownloadResult(
        success: false,
        error: 'Untrusted download URL',
      );
    }

    _isDownloading = true;
    try {
      final cacheDir = await _getCacheDir();
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
      final destFile = File('${cacheDir.path}/${manifest.apkAsset}');
      if (await destFile.exists()) {
        await destFile.delete();
      }

      await _downloadApk(
        Uri.parse(urlStr),
        destFile,
        onProgress,
        downloadTimeout,
      );

      if (!await destFile.exists()) {
        return const UpdateDownloadResult(
          success: false,
          error: 'Downloaded APK file missing',
        );
      }
      final fileSize = await destFile.length();
      if (fileSize <= 0 || fileSize > maxApkBytes) {
        await destFile.delete();
        return const UpdateDownloadResult(
          success: false,
          error: 'Downloaded APK size invalid or exceeds limit',
        );
      }

      final actualSha = await _computeSha256(destFile.path);
      if (actualSha == null ||
          actualSha.toUpperCase() != manifest.sha256.toUpperCase()) {
        await destFile.delete();
        return const UpdateDownloadResult(
          success: false,
          error: 'APK checksum verification failed',
        );
      }

      final installRes = await _launchInstaller(destFile.path);
      final started = installRes['started'] == true;
      final needsPerm = installRes['needsInstallPermission'] == true;
      final err = installRes['error'] as String?;

      return UpdateDownloadResult(
        success: started,
        filePath: destFile.path,
        needsInstallPermission: needsPerm,
        error: started ? null : (err ?? 'Installation was cancelled or failed'),
        installerCancelled: !started && !needsPerm && err == null,
      );
    } catch (e) {
      debugPrint('[APP-UPDATE] Download/install error: $e');
      return UpdateDownloadResult(success: false, error: e.toString());
    } finally {
      _isDownloading = false;
    }
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
    final map = await _channel.invokeMapMethod<String, dynamic>(
      'getInstalledAppInfo',
    );
    final abis = (map?['supportedAbis'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const ['arm64-v8a'];
    return InstalledAppInfo(
      packageName:
          map?['packageName']?.toString() ??
          'com.visionassistant.vision_assistant.visionmission',
      versionName: map?['versionName']?.toString() ?? '1.0.0',
      versionCode: (map?['versionCode'] as num?)?.toInt() ?? 1,
      supportedAbis: abis,
    );
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
          if (total > 0 && onProgress != null) {
            onProgress((received / total).clamp(0.0, 1.0));
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
    } finally {
      client.close(force: true);
    }
  }

  static Future<String?> _defaultComputeSha256(String path) async {
    return _channel.invokeMethod<String>('computeFileSha256', {'path': path});
  }

  static Future<Directory> _defaultGetCacheDir() async {
    final path = await _channel.invokeMethod<String>('getUpdateCacheDir');
    if (path != null && path.isNotEmpty) {
      return Directory(path);
    }
    return Directory('${Directory.systemTemp.path}/sanetra_updates');
  }

  static Future<Map<String, dynamic>> _defaultLaunchInstaller(
    String path,
  ) async {
    final res = await _channel.invokeMapMethod<String, dynamic>('installApk', {
      'path': path,
    });
    return res ?? <String, dynamic>{'started': false};
  }

  static Future<void> _defaultOpenInstallSettings() async {
    await _channel.invokeMethod<void>('openUnknownSourcesSettings');
  }
}
