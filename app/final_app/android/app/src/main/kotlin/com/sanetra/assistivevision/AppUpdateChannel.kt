package com.sanetra.assistivevision

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/**
 * Native Android bridge for Sanetra's optional online update checks:
 * - Installed versionName / versionCode / supported ABIs
 * - ConnectivityManager status & network-available EventChannel
 * - File SHA-256 verification
 * - Secure FileProvider APK installation intent (always requires user confirmation)
 */
class AppUpdateChannel(private val context: Context) {
    companion object {
        private const val TAG = "SanetraUpdate"
        private const val SANETRA_PACKAGE_NAME = "com.sanetra.assistivevision"
        private const val METHOD_CHANNEL = "vision_assistant/app_update"
        private const val CONNECTIVITY_EVENT_CHANNEL = "vision_assistant/connectivity"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val connectivityManager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    fun register(flutterEngine: FlutterEngine) {
        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInstalledAppInfo" -> result.success(getInstalledAppInfo())
                    "hasNetworkConnectivity" -> result.success(isNetworkConnected())
                    "getUpdateCacheDir" -> {
                        val dir = File(context.cacheDir, "updates")
                        if (!dir.exists()) dir.mkdirs()
                        result.success(dir.absolutePath)
                    }
                    "computeFileSha256" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.success(null)
                        } else {
                            result.success(computeSha256(File(path)))
                        }
                    }
                    "canRequestPackageInstalls" -> {
                        val allowed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            context.packageManager.canRequestPackageInstalls()
                        } else {
                            true
                        }
                        result.success(allowed)
                    }
                    "openUnknownSourcesSettings" -> {
                        openUnknownSourcesSettings()
                        result.success(null)
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        val expectedPackageName = call.argument<String>("expectedPackageName")
                        if (path.isNullOrBlank()) {
                            result.success(mapOf("started" to false, "error" to "Empty APK path"))
                        } else if (expectedPackageName.isNullOrBlank()) {
                            result.success(mapOf("started" to false, "error" to "Missing expected APK package ID"))
                        } else {
                            result.success(installApk(File(path), expectedPackageName))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        eventChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CONNECTIVITY_EVENT_CHANNEL
        ).apply {
            setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    registerNetworkCallback()
                }

                override fun onCancel(arguments: Any?) {
                    unregisterNetworkCallback()
                    eventSink = null
                }
            })
        }
    }

    private fun getInstalledAppInfo(): Map<String, Any> {
        return try {
            val pm = context.packageManager
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(context.packageName, 0)
            }
            val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                info.versionCode.toLong()
            }
            mapOf(
                "packageName" to context.packageName,
                "versionName" to (info.versionName ?: "1.0.0"),
                "versionCode" to versionCode,
                "supportedAbis" to Build.SUPPORTED_ABIS.toList()
            )
        } catch (t: Throwable) {
            Log.w(TAG, "getInstalledAppInfo failed: ${t.message}")
            mapOf(
                "packageName" to context.packageName,
                "versionName" to "1.0.0",
                "versionCode" to 1L,
                "supportedAbis" to Build.SUPPORTED_ABIS.toList()
            )
        }
    }

    private fun isNetworkConnected(): Boolean {
        val cm = connectivityManager ?: return false
        return try {
            val network = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(network) ?: return false
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        } catch (t: Throwable) {
            Log.w(TAG, "isNetworkConnected failed: ${t.message}")
            false
        }
    }

    private fun registerNetworkCallback() {
        val cm = connectivityManager ?: return
        if (networkCallback != null) return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                emitConnectivity(true)
            }

            override fun onLost(network: Network) {
                emitConnectivity(isNetworkConnected())
            }
        }
        try {
            cm.registerDefaultNetworkCallback(cb)
            networkCallback = cb
        } catch (t: Throwable) {
            Log.w(TAG, "registerDefaultNetworkCallback failed: ${t.message}")
        }
    }

    private fun unregisterNetworkCallback() {
        val cm = connectivityManager ?: return
        val cb = networkCallback ?: return
        try {
            cm.unregisterNetworkCallback(cb)
        } catch (_: Throwable) {}
        networkCallback = null
    }

    private fun emitConnectivity(connected: Boolean) {
        val sink = eventSink ?: return
        mainHandler.post {
            try {
                sink.success(connected)
            } catch (_: Throwable) {}
        }
    }

    private fun computeSha256(file: File): String? {
        if (!file.exists() || !file.isFile) return null
        return try {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buf = ByteArray(65536)
                while (true) {
                    val read = input.read(buf)
                    if (read <= 0) break
                    digest.update(buf, 0, read)
                }
            }
            digest.digest().joinToString("") { "%02x".format(it) }.uppercase()
        } catch (t: Throwable) {
            Log.w(TAG, "computeSha256 failed: ${t.message}")
            null
        }
    }

    private fun openUnknownSourcesSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val intent = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${context.packageName}")
                ).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(intent)
            } catch (t: Throwable) {
                Log.w(TAG, "openUnknownSourcesSettings failed: ${t.message}")
            }
        }
    }

    private fun installApk(apkFile: File, expectedPackageName: String): Map<String, Any> {
        if (!apkFile.exists() || !apkFile.isFile) {
            return mapOf("started" to false, "error" to "APK file not found")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !context.packageManager.canRequestPackageInstalls()
        ) {
            return mapOf(
                "started" to false,
                "needsInstallPermission" to true,
                "error" to "Install unknown apps permission required"
            )
        }
        if (expectedPackageName != SANETRA_PACKAGE_NAME ||
            !Regex("^[A-Za-z][A-Za-z0-9_]*(\\\\.[A-Za-z][A-Za-z0-9_]*)+$").matches(expectedPackageName)
        ) {
            return mapOf("started" to false, "error" to "Untrusted target package ID")
        }
        return try {
            // Verify the downloaded APK matches the package declared by the trusted release manifest.
            // A different package is allowed only for the explicit v1 -> v2 migration;
            // Android will install it as a separate app and preserve the existing v1 app.
            val pkgInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.packageManager.getPackageArchiveInfo(
                    apkFile.absolutePath,
                    PackageManager.PackageInfoFlags.of(0)
                )
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.getPackageArchiveInfo(apkFile.absolutePath, 0)
            }
            if (pkgInfo == null || pkgInfo.packageName != expectedPackageName) {
                return mapOf(
                    "started" to false,
                    "error" to "Downloaded APK does not match the release package ID (${pkgInfo?.packageName ?: "invalid"})"
                )
            }

            val uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                apkFile
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
            val isMigration = expectedPackageName != context.packageName
            Log.i(TAG, "Launched Android package installer for ${apkFile.name}; target=$expectedPackageName; migration=$isMigration")
            mapOf("started" to true, "isMigration" to isMigration, "targetPackageName" to expectedPackageName)
        } catch (t: Throwable) {
            Log.w(TAG, "installApk failed: ${t.message}")
            mapOf("started" to false, "error" to (t.message ?: "Installer error"))
        }
    }

    fun unregister() {
        unregisterNetworkCallback()
        eventSink = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
    }
}
