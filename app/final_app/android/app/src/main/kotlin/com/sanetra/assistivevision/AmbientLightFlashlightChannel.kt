package com.sanetra.assistivevision

import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Native Android bridge for:
 * 1. Hardware ambient light sensor (Sensor.TYPE_LIGHT) via EventChannel.
 * 2. Torch capability, external torch-ownership tracking (TorchCallback),
 *    and fallback torch-off control via MethodChannel.
 */
class AmbientLightFlashlightChannel(private val context: Context) {
    companion object {
        private const val TAG = "AutoFlashlightNative"
        private const val METHOD_CHANNEL = "vision_assistant/flashlight_sensor"
        private const val EVENT_CHANNEL = "vision_assistant/ambient_light"
    }

    private val sensorManager: SensorManager? =
        context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
    private val lightSensor: Sensor? =
        sensorManager?.getDefaultSensor(Sensor.TYPE_LIGHT)
    private val cameraManager: CameraManager? =
        context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var sensorListener: SensorEventListener? = null
    private var torchCallback: CameraManager.TorchCallback? = null

    @Volatile
    private var backCameraIdWithFlash: String? = null

    @Volatile
    private var lastReportedTorchEnabled: Boolean? = null

    @Volatile
    private var lastReportedTorchAvailable: Boolean? = null

    fun register(flutterEngine: FlutterEngine) {
        backCameraIdWithFlash = findBackCameraWithFlash()
        registerTorchCallback()

        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "getLightSensorInfo" -> {
                        val sensor = lightSensor
                        result.success(
                            mapOf(
                                "available" to (sensor != null),
                                "name" to sensor?.name,
                                "vendor" to sensor?.vendor,
                                "maxRange" to sensor?.maximumRange?.toDouble(),
                                "resolution" to sensor?.resolution?.toDouble()
                            )
                        )
                    }
                    "isTorchAvailable" -> {
                        val hasFeature = context.packageManager.hasSystemFeature(
                            PackageManager.FEATURE_CAMERA_FLASH
                        )
                        val available = hasFeature && (backCameraIdWithFlash != null)
                        result.success(available)
                    }
                    "getTorchStatus" -> {
                        result.success(
                            mapOf(
                                "torchEnabled" to lastReportedTorchEnabled,
                                "torchAvailable" to lastReportedTorchAvailable,
                                "cameraId" to backCameraIdWithFlash
                            )
                        )
                    }
                    "setTorchFallback" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        val ok = setTorchViaCameraManager(enabled)
                        result.success(ok)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        eventChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL
        ).apply {
            setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    startLightSensor()
                }

                override fun onCancel(arguments: Any?) {
                    stopLightSensor()
                    eventSink = null
                }
            })
        }

        Log.i(
            TAG,
            "[INIT] lightSensorAvailable=${lightSensor != null} " +
                "name=${lightSensor?.name} maxRange=${lightSensor?.maximumRange} " +
                "torchCameraId=$backCameraIdWithFlash"
        )
    }

    private fun findBackCameraWithFlash(): String? {
        val cm = cameraManager ?: return null
        return try {
            for (id in cm.cameraIdList) {
                val chars = cm.getCameraCharacteristics(id)
                val facing = chars.get(CameraCharacteristics.LENS_FACING)
                val hasFlash = chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
                if (facing == CameraCharacteristics.LENS_FACING_BACK && hasFlash) {
                    return id
                }
            }
            null
        } catch (t: Throwable) {
            Log.w(TAG, "[TORCH] findBackCameraWithFlash failed: ${t.message}")
            null
        }
    }

    private fun registerTorchCallback() {
        val cm = cameraManager ?: return
        val targetId = backCameraIdWithFlash ?: return
        if (torchCallback != null) return

        val cb = object : CameraManager.TorchCallback() {
            override fun onTorchModeChanged(cameraId: String, enabled: Boolean) {
                if (cameraId == targetId) {
                    lastReportedTorchAvailable = true
                    lastReportedTorchEnabled = enabled
                    Log.d(TAG, "[TORCH-CB] camera=$cameraId enabled=$enabled")
                }
            }

            override fun onTorchModeUnavailable(cameraId: String) {
                if (cameraId == targetId) {
                    lastReportedTorchAvailable = false
                    Log.d(TAG, "[TORCH-CB] camera=$cameraId unavailable (likely in use by CameraController)")
                }
            }
        }
        try {
            cm.registerTorchCallback(cb, mainHandler)
            torchCallback = cb
        } catch (t: Throwable) {
            Log.w(TAG, "[TORCH-CB] registerTorchCallback failed: ${t.message}")
        }
    }

    private fun startLightSensor() {
        val sm = sensorManager
        val sensor = lightSensor
        if (sm == null || sensor == null) {
            Log.w(TAG, "[SENSOR] TYPE_LIGHT unavailable on this device")
            return
        }
        if (sensorListener != null) return

        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent?) {
                if (event == null || event.values.isEmpty()) return
                val lux = event.values[0].toDouble()
                if (!lux.isFinite() || lux < 0.0) return
                val sink = eventSink ?: return
                mainHandler.post {
                    try {
                        sink.success(
                            mapOf(
                                "lux" to lux,
                                "timestampMs" to System.currentTimeMillis()
                            )
                        )
                    } catch (t: Throwable) {
                        Log.w(TAG, "[SENSOR] sink.success failed: ${t.message}")
                    }
                }
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
                // No action needed; lux values are filtered in AutoFlashlightController.
            }
        }

        val registered = sm.registerListener(
            listener,
            sensor,
            SensorManager.SENSOR_DELAY_NORMAL,
            mainHandler
        )
        if (registered) {
            sensorListener = listener
            Log.i(TAG, "[SENSOR] Started TYPE_LIGHT listener (${sensor.name})")
        } else {
            Log.w(TAG, "[SENSOR] Failed to register TYPE_LIGHT listener")
        }
    }

    private fun stopLightSensor() {
        val sm = sensorManager
        val listener = sensorListener
        if (sm != null && listener != null) {
            try {
                sm.unregisterListener(listener)
                Log.i(TAG, "[SENSOR] Stopped TYPE_LIGHT listener")
            } catch (t: Throwable) {
                Log.w(TAG, "[SENSOR] unregisterListener failed: ${t.message}")
            }
        }
        sensorListener = null
    }

    private fun setTorchViaCameraManager(enabled: Boolean): Boolean {
        val cm = cameraManager ?: return false
        val id = backCameraIdWithFlash ?: return false
        return try {
            cm.setTorchMode(id, enabled)
            lastReportedTorchEnabled = enabled
            Log.i(TAG, "[TORCH-FALLBACK] setTorchMode($id, $enabled) succeeded")
            true
        } catch (t: Throwable) {
            Log.w(TAG, "[TORCH-FALLBACK] setTorchMode($id, $enabled) failed: ${t.message}")
            false
        }
    }

    fun unregister() {
        stopLightSensor()
        eventSink = null
        val cm = cameraManager
        val cb = torchCallback
        if (cm != null && cb != null) {
            try {
                cm.unregisterTorchCallback(cb)
            } catch (_: Throwable) {}
        }
        torchCallback = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
    }
}
