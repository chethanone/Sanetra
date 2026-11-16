package com.visionassistant.vision_assistant

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.KeyEvent
import com.visionmission.currency.CurrencyPlatformChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "HardwareKeys"
        private const val CHANNEL = "vision_assistant/hardware_keys"
        private const val LONG_PRESS_DURATION_MS = 2000L
        private const val DOUBLE_PRESS_WINDOW_MS = 450L
    }

    private var channel: MethodChannel? = null
    private var currencyChannel: CurrencyPlatformChannel? = null
    private var ambientLightFlashlightChannel: AmbientLightFlashlightChannel? = null
    private var appUpdateChannel: AppUpdateChannel? = null
    private var ttsEvalReceiver: BroadcastReceiver? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private var isLanguagePopupOpen = false
    private var isOcrModeActive = false

    private var volUpPressed = false
    private var volUpLongTriggered = false
    private var volUpAwaitingSecondTap = false
    private var volUpSecondTapDown = false
    private var volDownPressed = false
    private var volDownLongTriggered = false

    private val volUpLongPressRunnable = Runnable {
        if (volUpPressed && !volUpLongTriggered && !isLanguagePopupOpen) {
            volUpLongTriggered = true
            volUpAwaitingSecondTap = false
            volUpSecondTapDown = false
            mainHandler.removeCallbacks(volUpSingleTapPendingRunnable)
            Log.i(TAG, "[GESTURE] Volume Up 2000ms hold -> toggleMode")
            channel?.invokeMethod("onVolumeUpLongPress", null)
        }
    }

    private val volUpSingleTapPendingRunnable = Runnable {
        if (volUpAwaitingSecondTap) {
            volUpAwaitingSecondTap = false
            Log.i(TAG, "[KEY] Volume Up single short press window expired -> adjustSystemVolume(+1)")
            adjustSystemVolume(AudioManager.ADJUST_RAISE)
        }
    }

    private val volDownLongPressRunnable = Runnable {
        if (volDownPressed && !volDownLongTriggered) {
            volDownLongTriggered = true
            Log.i(TAG, "[GESTURE] Volume Down 2000ms hold -> toggleLanguagePopup (open=$isLanguagePopupOpen)")
            channel?.invokeMethod("onVolumeDownLongPress", null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "setLanguagePopupOpen" -> {
                        isLanguagePopupOpen = call.argument<Boolean>("open") ?: false
                        if (isLanguagePopupOpen) {
                            mainHandler.removeCallbacks(volUpSingleTapPendingRunnable)
                            volUpAwaitingSecondTap = false
                            volUpSecondTapDown = false
                        }
                        Log.i(TAG, "[POPUP-STATE] isLanguagePopupOpen=$isLanguagePopupOpen")
                        result.success(null)
                    }
                    "setOcrModeActive" -> {
                        isOcrModeActive = call.argument<Boolean>("active") ?: false
                        if (!isOcrModeActive) {
                            mainHandler.removeCallbacks(volUpSingleTapPendingRunnable)
                            volUpAwaitingSecondTap = false
                            volUpSecondTapDown = false
                        }
                        Log.i(TAG, "[OCR-STATE] isOcrModeActive=$isOcrModeActive")
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        currencyChannel = CurrencyPlatformChannel(applicationContext).apply {
            register(flutterEngine)
        }
        ambientLightFlashlightChannel = AmbientLightFlashlightChannel(applicationContext).apply {
            register(flutterEngine)
        }
        appUpdateChannel = AppUpdateChannel(applicationContext).apply {
            register(flutterEngine)
        }
        val evalAction = "${applicationContext.packageName}.SYNTH_KANNADA_EVAL"
        val diagAction = "${applicationContext.packageName}.TTS_DIAGNOSTIC"
        val ocrEvalAction = "${applicationContext.packageName}.OCR_EVAL_IMAGE"
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    evalAction -> channel?.invokeMethod("onSynthKannadaEval", null)
                    diagAction -> channel?.invokeMethod("onTtsDiagnostic", null)
                    ocrEvalAction -> {
                        val path = intent.getStringExtra("path") ?: ""
                        val lang = intent.getStringExtra("lang")
                        val speak = intent.getBooleanExtra("speak", true)
                        channel?.invokeMethod(
                            "onOcrEvalImage",
                            mapOf("path" to path, "lang" to lang, "speak" to speak)
                        )
                    }
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(evalAction)
            addAction(diagAction)
            addAction(ocrEvalAction)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }
        ttsEvalReceiver = receiver
    }

    private fun cancelPendingGestures() {
        mainHandler.removeCallbacks(volUpLongPressRunnable)
        mainHandler.removeCallbacks(volUpSingleTapPendingRunnable)
        mainHandler.removeCallbacks(volDownLongPressRunnable)
        volUpPressed = false
        volUpLongTriggered = false
        volUpAwaitingSecondTap = false
        volUpSecondTapDown = false
        volDownPressed = false
        volDownLongTriggered = false
    }

    private fun adjustSystemVolume(direction: Int) {
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            audioManager?.adjustStreamVolume(
                AudioManager.STREAM_MUSIC,
                direction,
                AudioManager.FLAG_SHOW_UI
            )
        } catch (t: Throwable) {
            Log.w(TAG, "adjustSystemVolume failed: ${t.message}")
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val keyCode = event.keyCode
        if (keyCode != KeyEvent.KEYCODE_VOLUME_UP && keyCode != KeyEvent.KEYCODE_VOLUME_DOWN) {
            return super.dispatchKeyEvent(event)
        }

        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            when (event.action) {
                KeyEvent.ACTION_DOWN -> {
                    if (event.repeatCount > 0 || volUpPressed) {
                        return true
                    }
                    volUpPressed = true
                    volUpLongTriggered = false
                    if (isLanguagePopupOpen) {
                        val ageMs = (android.os.SystemClock.uptimeMillis() - event.eventTime).coerceAtLeast(0L)
                        Log.i(TAG, "[POPUP-KEY] Short Volume Up -> prevLanguage (nativeAgeMs=$ageMs)")
                        channel?.invokeMethod("onPopupVolumeUp", mapOf("nativeAgeMs" to ageMs))
                    } else {
                        if (isOcrModeActive && volUpAwaitingSecondTap) {
                            mainHandler.removeCallbacks(volUpSingleTapPendingRunnable)
                            volUpAwaitingSecondTap = false
                            volUpSecondTapDown = true
                        } else {
                            volUpSecondTapDown = false
                        }
                        mainHandler.postDelayed(volUpLongPressRunnable, LONG_PRESS_DURATION_MS)
                    }
                    return true
                }
                KeyEvent.ACTION_UP -> {
                    mainHandler.removeCallbacks(volUpLongPressRunnable)
                    val wasTriggered = volUpLongTriggered
                    val wasPopup = isLanguagePopupOpen
                    val wasSecondTap = volUpSecondTapDown
                    volUpPressed = false
                    volUpLongTriggered = false
                    volUpSecondTapDown = false
                    if (!wasTriggered && !wasPopup) {
                        if (wasSecondTap && isOcrModeActive) {
                            Log.i(TAG, "[GESTURE] Volume Up double-press within ${DOUBLE_PRESS_WINDOW_MS}ms -> rereadOcr")
                            channel?.invokeMethod("onVolumeUpDoublePress", null)
                        } else if (isOcrModeActive) {
                            volUpAwaitingSecondTap = true
                            mainHandler.removeCallbacks(volUpSingleTapPendingRunnable)
                            mainHandler.postDelayed(volUpSingleTapPendingRunnable, DOUBLE_PRESS_WINDOW_MS)
                        } else {
                            adjustSystemVolume(AudioManager.ADJUST_RAISE)
                        }
                    }
                    return true
                }
            }
        }

        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
            when (event.action) {
                KeyEvent.ACTION_DOWN -> {
                    if (event.repeatCount > 0 || volDownPressed) {
                        return true
                    }
                    volDownPressed = true
                    volDownLongTriggered = false
                    mainHandler.postDelayed(volDownLongPressRunnable, LONG_PRESS_DURATION_MS)
                    return true
                }
                KeyEvent.ACTION_UP -> {
                    mainHandler.removeCallbacks(volDownLongPressRunnable)
                    val wasTriggered = volDownLongTriggered
                    val wasPopup = isLanguagePopupOpen
                    volDownPressed = false
                    volDownLongTriggered = false
                    if (!wasTriggered) {
                        if (wasPopup) {
                            val ageMs = (android.os.SystemClock.uptimeMillis() - event.eventTime).coerceAtLeast(0L)
                            Log.i(TAG, "[POPUP-KEY] Short Volume Down -> nextLanguage (nativeAgeMs=$ageMs)")
                            channel?.invokeMethod("onPopupVolumeDown", mapOf("nativeAgeMs" to ageMs))
                        } else {
                            adjustSystemVolume(AudioManager.ADJUST_LOWER)
                        }
                    }
                    return true
                }
            }
        }

        return super.dispatchKeyEvent(event)
    }

    override fun onPause() {
        cancelPendingGestures()
        super.onPause()
    }

    override fun onStop() {
        cancelPendingGestures()
        super.onStop()
    }

    override fun onDestroy() {
        cancelPendingGestures()
        ttsEvalReceiver?.let {
            try { unregisterReceiver(it) } catch (_: Throwable) {}
        }
        ttsEvalReceiver = null
        currencyChannel?.unregister()
        currencyChannel = null
        ambientLightFlashlightChannel?.unregister()
        ambientLightFlashlightChannel = null
        appUpdateChannel?.unregister()
        appUpdateChannel = null
        channel?.setMethodCallHandler(null)
        channel = null
        super.onDestroy()
    }
}
