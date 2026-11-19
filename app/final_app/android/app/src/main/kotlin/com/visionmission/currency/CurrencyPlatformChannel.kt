package com.visionmission.currency

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class CurrencyPlatformChannel(
    private val context: Context,
    private val channelName: String = "visionmission/currency_detector"
) : MethodChannel.MethodCallHandler {

    private var channel: MethodChannel? = null
    private var detector: CurrencyDetector? = null
    private val backgroundExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val captureNextDiagnosticFrame = AtomicBoolean(false)
    private val diagnosticFrameSeq = AtomicLong(0)
    private var diagReceiver: BroadcastReceiver? = null

    // The app ID was rebranded from the legacy .visionmission suffix to
    // com.sanetra.assistivevision. Keep production identity separate from
    // diagnostic candidate flavors while selecting the same validated final models.
    private fun isSanetraProductionPackage(): Boolean =
        context.packageName == "com.sanetra.assistivevision"

    private fun isIdentityCandidatePackage(): Boolean =
        context.packageName.endsWith(".identitycandidate") ||
            context.packageName.endsWith(".identitycandidate_v2") ||
            context.packageName.endsWith(".identitycandidate_n5") ||
            context.packageName.endsWith(".unified_v52") ||
            context.packageName.endsWith(".visionmission")

    private fun usesFinalIdentityCurrencyPipeline(): Boolean =
        isIdentityCandidatePackage() || isSanetraProductionPackage()

    // Diagnostic broadcast receiver remains limited to candidate/test builds.
    private fun isCandidatePackage(): Boolean =
        context.packageName.endsWith(".candidate") ||
            context.packageName.contains(".candidate_") ||
            isIdentityCandidatePackage()

    fun register(flutterEngine: FlutterEngine) {
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler(this)
        if (isCandidatePackage()) {
            val captureAction = "${context.packageName}.CAPTURE_DIAGNOSTIC"
            val runImageAction = "${context.packageName}.RUN_IMAGE_DIAGNOSTIC"
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(ctx: Context?, intent: Intent?) {
                    when (intent?.action) {
                        captureAction -> {
                            captureNextDiagnosticFrame.set(true)
                            Log.i("CurrencyDiag", "[DIAG-CAPTURE] Armed for next camera frame")
                        }
                        runImageAction -> {
                            val imgPath = intent.getStringExtra("imagePath") ?: return
                            runImageDiagnostic(imgPath)
                        }
                    }
                }
            }
            val filter = IntentFilter().apply {
                addAction(captureAction)
                addAction(runImageAction)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                context.registerReceiver(receiver, filter)
            }
            diagReceiver = receiver
        }
    }

    fun unregister() {
        diagReceiver?.let {
            try { context.unregisterReceiver(it) } catch (_: Throwable) {}
        }
        diagReceiver = null
        channel?.setMethodCallHandler(null)
        channel = null
        backgroundExecutor.shutdown()
        detector?.close()
        detector = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initModels" -> handleInitModels(call, result)
            "detectSnapshot" -> handleDetectSnapshot(call, result)
            "detectCameraFrame" -> handleDetectCameraFrame(call, result)
            "dispose" -> handleDispose(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleInitModels(call: MethodCall, result: MethodChannel.Result) {
        backgroundExecutor.execute {
            try {
                val isCandidateApp = isCandidatePackage() || isSanetraProductionPackage()
                val defaultCoin = if (isCandidateApp) {
                    "assets/models/currency/candidates/indian_coin_phase4n_candidate.onnx"
                } else {
                    "assets/models/currency/indian_coin_yolov8n.onnx"
                }
                val defaultBanknote = if (isCandidateApp) {
                    "assets/models/currency/candidates/indian_banknote_phase4l_candidate.onnx"
                } else {
                    "assets/models/currency/indian_banknote_yolov8n.onnx"
                }

                // The published Sanetra package and identity-validation flavors use the
                // validated final detector/verifier pipeline. Experimental flavors remain isolated.
                val forceProdBaseline = !isSanetraProductionPackage() && isCandidateApp && (call.argument<Boolean>("forceProductionBaseline") == true)
                val enforceIdentityDefaults = usesFinalIdentityCurrencyPipeline() && !forceProdBaseline
                val coinModelArg = when {
                    enforceIdentityDefaults -> defaultCoin
                    isCandidateApp -> call.argument<String>("coinModelAsset") ?: defaultCoin
                    else -> defaultCoin
                }
                val banknoteModelArg = when {
                    enforceIdentityDefaults -> defaultBanknote
                    isCandidateApp -> call.argument<String>("banknoteModelAsset") ?: defaultBanknote
                    else -> defaultBanknote
                }
                val enableCandidateMode = isCandidateApp && !forceProdBaseline
                val numThreads = call.argument<Int>("numThreads") ?: 4

                val coinFallback = File(coinModelArg).name.ifEmpty {
                    if (isCandidateApp) "indian_coin_phase4n_candidate.onnx" else "indian_coin_yolov8n.onnx"
                }
                val banknoteFallback = File(banknoteModelArg).name.ifEmpty {
                    if (isCandidateApp) "indian_banknote_phase4l_candidate.onnx" else "indian_banknote_yolov8n.onnx"
                }

                val coinFilePath = resolveModelPath(coinModelArg, coinFallback)
                val banknoteFilePath = resolveModelPath(banknoteModelArg, banknoteFallback)

                val useIdentityVerifiers = usesFinalIdentityCurrencyPipeline() && !forceProdBaseline
                val isN5Only = context.packageName.endsWith(".identitycandidate_n5") ||
                    context.packageName.endsWith(".visionmission") ||
                    isSanetraProductionPackage()
                val isV2 = context.packageName.endsWith(".identitycandidate_v2")
                val noteVerifierPath = if (useIdentityVerifiers) {
                    when {
                        isN5Only -> resolveModelPath(
                            "assets/models/currency/identitycandidate_n5/n5_note_verifier.onnx",
                            "n5_note_verifier.onnx"
                        )
                        isV2 -> resolveModelPath(
                            "assets/models/currency/identitycandidate_v2/n5_note_verifier.onnx",
                            "n5_note_verifier.onnx"
                        )
                        else -> resolveModelPath(
                            "assets/models/currency/identitycandidate/n3_note_verifier.onnx",
                            "n3_note_verifier.onnx"
                        )
                    }
                } else null
                val coinVerifierPath = if (useIdentityVerifiers) {
                    when {
                        isN5Only -> resolveModelPath(
                            "assets/models/currency/identitycandidate_n5/indian_coin_verifier.onnx",
                            "indian_coin_verifier.onnx"
                        )
                        isV2 -> resolveModelPath(
                            "assets/models/currency/identitycandidate_v2/c2_coin_verifier.onnx",
                            "c2_coin_verifier.onnx"
                        )
                        else -> resolveModelPath(
                            "assets/models/currency/identitycandidate/indian_coin_verifier.onnx",
                            "indian_coin_verifier.onnx"
                        )
                    }
                } else null

                if (isSanetraProductionPackage()) {
                    val finalProfileValid =
                        enableCandidateMode &&
                        coinModelArg.endsWith("indian_coin_phase4n_candidate.onnx") &&
                        banknoteModelArg.endsWith("indian_banknote_phase4l_candidate.onnx") &&
                        noteVerifierPath?.endsWith("n5_note_verifier.onnx") == true &&
                        coinVerifierPath?.endsWith("indian_coin_verifier.onnx") == true
                    if (!finalProfileValid) {
                        throw IllegalStateException(
                            "Sanetra production currency profile mismatch. Refusing to start with baseline or incomplete models."
                        )
                    }
                    Log.i(
                        "SanetraCurrency",
                        "Activated validated final profile: Phase4L banknote + Phase4N coin + N5 note verifier + Phase4O10 coin verifier"
                    )
                }

                synchronized(this) {
                    detector?.close()
                    val t0 = System.currentTimeMillis()
                    detector = CurrencyDetector(
                        coinModelPath = coinFilePath,
                        banknoteModelPath = banknoteFilePath,
                        numThreads = numThreads,
                        isCandidateMode = enableCandidateMode,
                        noteVerifierPath = noteVerifierPath,
                        coinVerifierPath = coinVerifierPath
                    )
                    val totalInitTimeMs = (System.currentTimeMillis() - t0).toDouble()

                    mainHandler.post {
                        result.success(
                            mapOf(
                                "status" to "success",
                                "isCandidateApp" to isCandidateApp,
                                "isCandidateMode" to enableCandidateMode,
                                "isIdentityCandidate" to useIdentityVerifiers,
                                "coinLoadTimeMs" to (detector?.coinLoadTimeMs ?: 0.0),
                                "banknoteLoadTimeMs" to (detector?.banknoteLoadTimeMs ?: 0.0),
                                "noteVerifierLoadTimeMs" to (detector?.noteVerifierLoadTimeMs ?: 0.0),
                                "coinVerifierLoadTimeMs" to (detector?.coinVerifierLoadTimeMs ?: 0.0),
                                "totalInitTimeMs" to totalInitTimeMs,
                                "coinModelPath" to coinFilePath,
                                "banknoteModelPath" to banknoteFilePath,
                                "noteVerifierPath" to (noteVerifierPath ?: ""),
                                "coinVerifierPath" to (coinVerifierPath ?: "")
                            )
                        )
                    }
                }
            } catch (e: Throwable) {
                mainHandler.post {
                    result.error(
                        "INIT_ERROR",
                        "Failed to initialize native currency models: ${e.message}",
                        e.stackTraceToString()
                    )
                }
            }
        }
    }

    private fun handleDetectSnapshot(call: MethodCall, result: MethodChannel.Result) {
        val det = detector
        if (det == null) {
            result.error("NOT_INITIALIZED", "Native CurrencyDetector is not initialized. Call initModels first.", null)
            return
        }

        val imageBytes = call.argument<ByteArray>("imageBytes")
        if (imageBytes == null || imageBytes.isEmpty()) {
            result.error("INVALID_ARGUMENT", "imageBytes cannot be null or empty", null)
            return
        }

        var orientationDegrees = call.argument<Int>("orientationDegrees") ?: 0
        if (orientationDegrees == 0) {
            orientationDegrees = parseJpegExifOrientation(imageBytes)
        }

        val useCandidateDefaults = det.isCandidateMode
        val defaultCoinConf = if (useCandidateDefaults) {
            CurrencyDetector.CANDIDATE_COIN_CONF.toDouble()
        } else {
            0.25
        }
        val defaultNoteConf = if (useCandidateDefaults) {
            CurrencyDetector.CANDIDATE_BANKNOTE_CONF.toDouble()
        } else {
            0.25
        }
        val coinConf = (call.argument<Double>("coinConfThreshold") ?: defaultCoinConf).toFloat()
        val noteConf = (call.argument<Double>("banknoteConfThreshold") ?: defaultNoteConf).toFloat()
        val iouThresh = (call.argument<Double>("iouThreshold") ?: 0.45).toFloat()

        backgroundExecutor.execute {
            var bitmap: Bitmap? = null
            try {
                bitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
                if (bitmap == null) {
                    mainHandler.post {
                        result.error("DECODE_ERROR", "Failed to decode image bytes into Bitmap", null)
                    }
                    return@execute
                }

                val dualResp = synchronized(det) {
                    det.detectAll(
                        bitmap = bitmap,
                        orientationDegrees = orientationDegrees,
                        coinConfThreshold = coinConf,
                        banknoteConfThreshold = noteConf,
                        iouThreshold = iouThresh
                    )
                }

                val payload = buildDetectionPayload(dualResp)
                mainHandler.post {
                    result.success(payload)
                }
            } catch (e: Throwable) {
                mainHandler.post {
                    result.error(
                        "INFERENCE_ERROR",
                        "Error executing snapshot inference: ${e.message}",
                        e.stackTraceToString()
                    )
                }
            } finally {
                if (bitmap != null && !bitmap.isRecycled) {
                    bitmap.recycle()
                }
            }
        }
    }

    private fun handleDetectCameraFrame(call: MethodCall, result: MethodChannel.Result) {
        val det = detector
        if (det == null) {
            result.error("NOT_INITIALIZED", "Native CurrencyDetector is not initialized", null)
            return
        }

        val yBytes = call.argument<ByteArray>("yBytes")
        val uBytes = call.argument<ByteArray>("uBytes")
        val vBytes = call.argument<ByteArray>("vBytes")
        val width = call.argument<Int>("width") ?: 0
        val height = call.argument<Int>("height") ?: 0
        val yRowStride = call.argument<Int>("yRowStride") ?: width
        val uvRowStride = call.argument<Int>("uvRowStride") ?: width
        val uvPixelStride = call.argument<Int>("uvPixelStride") ?: 1
        val sensorOrientation = call.argument<Int>("sensorOrientation") ?: 90

        val useCandidateDefaults = det.isCandidateMode
        val defaultCoinConf = if (useCandidateDefaults) {
            CurrencyDetector.CANDIDATE_COIN_CONF.toDouble()
        } else {
            0.25
        }
        val defaultNoteConf = if (useCandidateDefaults) {
            CurrencyDetector.CANDIDATE_BANKNOTE_CONF.toDouble()
        } else {
            0.25
        }
        val coinConf = (call.argument<Double>("coinConfThreshold") ?: defaultCoinConf).toFloat()
        val noteConf = (call.argument<Double>("banknoteConfThreshold") ?: defaultNoteConf).toFloat()
        val iouThresh = (call.argument<Double>("iouThreshold") ?: 0.45).toFloat()

        if (yBytes == null || uBytes == null || vBytes == null || width <= 0 || height <= 0) {
            result.error("INVALID_FRAME", "Missing or invalid camera frame buffers", null)
            return
        }

        val minExpectedYSize = (height - 1) * yRowStride + width
        val uvHeight = height / 2
        val uvWidth = width / 2
        val minExpectedUvSize = if (uvHeight > 0 && uvWidth > 0) (uvHeight - 1) * uvRowStride + (uvWidth - 1) * uvPixelStride + 1 else 0

        if (yBytes.size < minExpectedYSize ||
            uBytes.size < minExpectedUvSize ||
            vBytes.size < minExpectedUvSize ||
            yRowStride < width ||
            uvRowStride < uvWidth ||
            uvPixelStride < 1
        ) {
            result.error("INVALID_FRAME", "Camera frame buffer strides or plane sizes invalid", null)
            return
        }

        backgroundExecutor.execute {
            var bitmap: Bitmap? = null
            try {
                bitmap = yuv420ToBitmap(
                    yBytes = yBytes,
                    uBytes = uBytes,
                    vBytes = vBytes,
                    width = width,
                    height = height,
                    yRowStride = yRowStride,
                    uvRowStride = uvRowStride,
                    uvPixelStride = uvPixelStride
                )

                val diagDir: File? = if (
                    isCandidatePackage() &&
                    det.isCandidateMode &&
                    captureNextDiagnosticFrame.compareAndSet(true, false)
                ) {
                    val idx = diagnosticFrameSeq.incrementAndGet()
                    val ts = System.currentTimeMillis()
                    val base = context.getExternalFilesDir("diagnostic_captures") ?: File(context.filesDir, "diagnostic_captures")
                    File(base, "frame_${idx}_${ts}").apply {
                        mkdirs()
                        File(this, "stage_a_y.bin").writeBytes(yBytes)
                        File(this, "stage_a_u.bin").writeBytes(uBytes)
                        File(this, "stage_a_v.bin").writeBytes(vBytes)
                        val meta = JSONObject().apply {
                            put("frameIndex", idx)
                            put("timestampMs", ts)
                            put("width", width)
                            put("height", height)
                            put("yRowStride", yRowStride)
                            put("uvRowStride", uvRowStride)
                            put("uvPixelStride", uvPixelStride)
                            put("sensorOrientation", sensorOrientation)
                        }
                        File(this, "stage_a_metadata.json").writeText(meta.toString(2))
                        FileOutputStream(File(this, "stage_b_yuv_converted.png")).use { fos ->
                            bitmap.compress(Bitmap.CompressFormat.PNG, 100, fos)
                        }
                    }
                } else {
                    null
                }

                val dualResp = synchronized(det) {
                    det.detectAll(
                        bitmap = bitmap,
                        orientationDegrees = sensorOrientation,
                        coinConfThreshold = coinConf,
                        banknoteConfThreshold = noteConf,
                        iouThreshold = iouThresh,
                        dumpDiagnosticDir = diagDir
                    )
                }

                if (diagDir != null) {
                    writeDiagnosticResultsJson(diagDir, dualResp)
                    Log.i("CurrencyDiag", "[DIAG-CAPTURE] Saved clean pre-overlay bundle to: ${diagDir.absolutePath}")
                }

                val payload = buildDetectionPayload(dualResp)
                mainHandler.post {
                    result.success(payload)
                }
            } catch (e: Throwable) {
                mainHandler.post {
                    result.error(
                        "FRAME_INFERENCE_ERROR",
                        "Error during camera frame inference: ${e.message}",
                        e.stackTraceToString()
                    )
                }
            } finally {
                if (bitmap != null && !bitmap.isRecycled) {
                    bitmap.recycle()
                }
            }
        }
    }

    private fun buildDetectionPayload(dualResp: DualDetectionResponse): Map<String, Any> {
        val detectionsList = mutableListOf<Map<String, Any>>()
        var rawTotalValue = 0
        var confirmedItemsValue = 0

        fun appendDetections(items: List<Detection>, type: String, classIdResolver: (String) -> Int, valueResolver: (String) -> Int) {
            for (d in items) {
                val value = valueResolver(d.className)
                rawTotalValue += value
                if (d.confirmationState == "confirmed") {
                    confirmedItemsValue += value
                }
                detectionsList.add(
                    mapOf(
                        "classId" to classIdResolver(d.className),
                        "className" to d.className,
                        "denomination" to d.className,
                        "value" to value,
                        "confidence" to d.confidence.toDouble(),
                        "box" to listOf(
                            d.box[0].toDouble(),
                            d.box[1].toDouble(),
                            d.box[2].toDouble(),
                            d.box[3].toDouble()
                        ),
                        "type" to type,
                        "top2ClassId" to d.top2ClassId,
                        "top2ClassName" to d.top2ClassName,
                        "top2Confidence" to d.top2Confidence.toDouble(),
                        "classMargin" to d.classMargin.toDouble(),
                        "suppressedConflictCount" to d.suppressedConflictCount,
                        "suppressedConflictClassId" to d.suppressedConflictClassId,
                        "suppressedConflictClassName" to d.suppressedConflictClassName,
                        "suppressedConflictConfidence" to d.suppressedConflictConfidence.toDouble(),
                        "interBoxMaxIoU" to d.interBoxMaxIoU.toDouble(),
                        "interBoxMaxIoMin" to d.interBoxMaxIoMin.toDouble(),
                        "confirmationState" to d.confirmationState,
                        "uncertaintyReasons" to d.uncertaintyReasons,
                        "identityState" to d.identityState,
                        "identityPForeign" to d.identityPForeign.toDouble(),
                        "identityPIndian" to d.identityPIndian.toDouble(),
                        "identityPNonCurrency" to d.identityPNonCurrency.toDouble(),
                        "identityMargin" to d.identityMargin.toDouble()
                    )
                )
            }
        }

        appendDetections(dualResp.banknoteDetections, "banknote", ::getUnifiedBanknoteClassId, ::getBanknoteValue)
        appendDetections(dualResp.coinDetections, "coin", ::getUnifiedCoinClassId, ::getCoinValue)

        val confirmedTotalValue = if (dualResp.isTotalConfirmed) rawTotalValue else 0

        return mapOf(
            "status" to "success",
            "isCandidateMode" to dualResp.isCandidateMode,
            "imageWidth" to dualResp.orientedWidth,
            "imageHeight" to dualResp.orientedHeight,
            "totalValue" to rawTotalValue,
            "detectedSumValue" to rawTotalValue,
            "confirmedValue" to confirmedTotalValue,
            "confirmedItemsValue" to confirmedItemsValue,
            "totalStatus" to dualResp.totalStatus,
            "isTotalConfirmed" to dualResp.isTotalConfirmed,
            "confirmedNoteCount" to dualResp.confirmedNoteCount,
            "tentativeNoteCount" to dualResp.tentativeNoteCount,
            "conflictingNoteCount" to dualResp.conflictingNoteCount,
            "uncertaintyReasons" to dualResp.uncertaintyReasons,
            "preprocessTimeMs" to dualResp.preprocessTimeMs,
            "coinInferenceTimeMs" to dualResp.coinInferenceTimeMs,
            "banknoteInferenceTimeMs" to dualResp.banknoteInferenceTimeMs,
            "cropExtractTimeMs" to dualResp.cropExtractTimeMs,
            "noteVerifyTimeMs" to dualResp.noteVerifyTimeMs,
            "coinVerifyTimeMs" to dualResp.coinVerifyTimeMs,
            "rejectedForeignCount" to dualResp.rejectedForeignCount,
            "rejectedNonCurrencyCount" to dualResp.rejectedNonCurrencyCount,
            "unknownIdentityCount" to dualResp.unknownIdentityCount,
            "rejectedIdentityDetections" to dualResp.rejectedIdentityDetections.map { r ->
                mapOf(
                    "className" to r.className,
                    "confidence" to r.confidence.toDouble(),
                    "identityState" to r.identityState,
                    "identityPForeign" to r.identityPForeign.toDouble(),
                    "identityPIndian" to r.identityPIndian.toDouble(),
                    "identityPNonCurrency" to r.identityPNonCurrency.toDouble(),
                    "identityMargin" to r.identityMargin.toDouble()
                )
            },
            "totalTimeMs" to dualResp.totalTimeMs,
            "detections" to detectionsList
        )
    }

    private fun handleDispose(call: MethodCall, result: MethodChannel.Result) {
        backgroundExecutor.execute {
            try {
                synchronized(this) {
                    detector?.close()
                    detector = null
                }
                mainHandler.post {
                    result.success(mapOf("status" to "success"))
                }
            } catch (e: Throwable) {
                mainHandler.post {
                    result.error("DISPOSE_ERROR", "Error disposing currency detector: ${e.message}", null)
                }
            }
        }
    }

    private fun yuv420ToBitmap(
        yBytes: ByteArray,
        uBytes: ByteArray,
        vBytes: ByteArray,
        width: Int,
        height: Int,
        yRowStride: Int,
        uvRowStride: Int,
        uvPixelStride: Int
    ): Bitmap {
        val pixels = IntArray(width * height)
        var outIdx = 0

        val maxIdxY = yBytes.size - 1
        val maxIdxU = uBytes.size - 1
        val maxIdxV = vBytes.size - 1

        for (y in 0 until height) {
            val yRow = y * yRowStride
            val uvRow = (y shr 1) * uvRowStride

            for (x in 0 until width) {
                val yIdx = yRow + x
                val safeY = if (yIdx in 0..maxIdxY) yIdx else maxIdxY

                val uvIdx = uvRow + (x shr 1) * uvPixelStride
                val safeU = if (uvIdx in 0..maxIdxU) uvIdx else maxIdxU
                val safeV = if (uvIdx in 0..maxIdxV) uvIdx else maxIdxV

                val yVal = yBytes[safeY].toInt() and 0xFF
                val uVal = (uBytes[safeU].toInt() and 0xFF) - 128
                val vVal = (vBytes[safeV].toInt() and 0xFF) - 128

                var r = yVal + ((359 * vVal) shr 8)
                var g = yVal - ((88 * uVal + 183 * vVal) shr 8)
                var b = yVal + ((454 * uVal) shr 8)

                if (r < 0) r = 0 else if (r > 255) r = 255
                if (g < 0) g = 0 else if (g > 255) g = 255
                if (b < 0) b = 0 else if (b > 255) b = 255

                pixels[outIdx++] = -0x1000000 or (r shl 16) or (g shl 8) or b
            }
        }
        return Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
    }

    private fun runImageDiagnostic(imagePath: String) {
        val det = detector ?: return
        if (!isCandidatePackage() || !det.isCandidateMode) return
        backgroundExecutor.execute {
            try {
                val f = File(imagePath)
                if (!f.exists()) {
                    Log.e("CurrencyDiag", "[DIAG-RUN-IMAGE] Missing file: $imagePath")
                    return@execute
                }
                val bitmap = BitmapFactory.decodeFile(f.absolutePath) ?: return@execute
                val base = context.getExternalFilesDir("diagnostic_captures") ?: File(context.filesDir, "diagnostic_captures")
                val outDir = File(base, "img_${f.nameWithoutExtension}_${System.currentTimeMillis()}").apply { mkdirs() }
                val dualResp = synchronized(det) {
                    det.detectAll(
                        bitmap = bitmap,
                        orientationDegrees = 0,
                        coinConfThreshold = CurrencyDetector.CANDIDATE_COIN_CONF,
                        banknoteConfThreshold = CurrencyDetector.CANDIDATE_BANKNOTE_CONF,
                        iouThreshold = CurrencyDetector.CANDIDATE_NMS_IOU,
                        dumpDiagnosticDir = outDir
                    )
                }
                writeDiagnosticResultsJson(outDir, dualResp)
                Log.i("CurrencyDiag", "[DIAG-RUN-IMAGE] Completed ${f.name} -> ${outDir.absolutePath}")
            } catch (e: Throwable) {
                Log.e("CurrencyDiag", "[DIAG-RUN-IMAGE] Error: ${e.message}", e)
            }
        }
    }

    private fun writeDiagnosticResultsJson(dir: File, dualResp: DualDetectionResponse) {
        val root = JSONObject().apply {
            put("isCandidateMode", dualResp.isCandidateMode)
            put("orientedWidth", dualResp.orientedWidth)
            put("orientedHeight", dualResp.orientedHeight)
            put("totalStatus", dualResp.totalStatus)
            put("isTotalConfirmed", dualResp.isTotalConfirmed)
            put("preprocessTimeMs", dualResp.preprocessTimeMs)
            put("coinInferenceTimeMs", dualResp.coinInferenceTimeMs)
            put("banknoteInferenceTimeMs", dualResp.banknoteInferenceTimeMs)
            put("cropExtractTimeMs", dualResp.cropExtractTimeMs)
            put("noteVerifyTimeMs", dualResp.noteVerifyTimeMs)
            put("coinVerifyTimeMs", dualResp.coinVerifyTimeMs)
            put("totalTimeMs", dualResp.totalTimeMs)
            put("rejectedForeignCount", dualResp.rejectedForeignCount)
            put("rejectedNonCurrencyCount", dualResp.rejectedNonCurrencyCount)
            put("unknownIdentityCount", dualResp.unknownIdentityCount)
            fun toArr(items: List<Detection>): JSONArray {
                val arr = JSONArray()
                for (d in items) {
                    arr.put(JSONObject().apply {
                        put("className", d.className)
                        put("confidence", d.confidence.toDouble())
                        put("top2ClassName", d.top2ClassName)
                        put("top2Confidence", d.top2Confidence.toDouble())
                        put("classMargin", d.classMargin.toDouble())
                        put("confirmationState", d.confirmationState)
                        put("identityState", d.identityState)
                        put("identityPForeign", d.identityPForeign.toDouble())
                        put("identityPIndian", d.identityPIndian.toDouble())
                        put("identityPNonCurrency", d.identityPNonCurrency.toDouble())
                        put("identityMargin", d.identityMargin.toDouble())
                        put("box", JSONArray(listOf(d.box[0].toDouble(), d.box[1].toDouble(), d.box[2].toDouble(), d.box[3].toDouble())))
                    })
                }
                return arr
            }
            put("banknoteDetections", toArr(dualResp.banknoteDetections))
            put("coinDetections", toArr(dualResp.coinDetections))
            put("rejectedIdentityDetections", toArr(dualResp.rejectedIdentityDetections))
        }
        File(dir, "stage_c_results.json").writeText(root.toString(2))
    }

    private fun resolveModelPath(modelPathOrAsset: String, fallbackFileName: String): String {
        val directFile = File(modelPathOrAsset)
        if (directFile.exists() && directFile.isFile) {
            return directFile.absolutePath
        }

        // Use the actual file name from the asset path if available
        val assetBaseName = File(modelPathOrAsset).name
        val actualFileName = if (assetBaseName.isNotEmpty() && assetBaseName.endsWith(".onnx")) assetBaseName else fallbackFileName

        // Try copying from Flutter assets
        val outFile = File(context.filesDir, actualFileName)
        val flutterLoader = FlutterInjector.instance().flutterLoader()
        val assetKey = flutterLoader.getLookupKeyForAsset(modelPathOrAsset)

        try {
            context.assets.open(assetKey).use { inputStream ->
                copyStreamToFile(inputStream, outFile)
            }
            return outFile.absolutePath
        } catch (_: Exception) {
            // Try direct asset open
            try {
                context.assets.open(modelPathOrAsset).use { inputStream ->
                    copyStreamToFile(inputStream, outFile)
                }
                return outFile.absolutePath
            } catch (_: Exception) {
                return modelPathOrAsset
            }
        }
    }

    private fun copyStreamToFile(inputStream: InputStream, targetFile: File) {
        val forceRefresh = isCandidatePackage()
        if (!forceRefresh && targetFile.exists() && targetFile.length() > 0) {
            return
        }
        val tmpFile = File(targetFile.parentFile, "${targetFile.name}.tmp")
        FileOutputStream(tmpFile).use { output ->
            val buffer = ByteArray(64 * 1024)
            var bytesRead: Int
            while (inputStream.read(buffer).also { bytesRead = it } != -1) {
                output.write(buffer, 0, bytesRead)
            }
            output.flush()
        }
        if (targetFile.exists()) {
            targetFile.delete()
        }
        tmpFile.renameTo(targetFile)
    }

    private fun parseJpegExifOrientation(bytes: ByteArray): Int {
        if (bytes.size < 12) return 0
        if ((bytes[0].toInt() and 0xFF) != 0xFF || (bytes[1].toInt() and 0xFF) != 0xD8) return 0
        var idx = 2
        while (idx < bytes.size - 4) {
            if ((bytes[idx].toInt() and 0xFF) != 0xFF) return 0
            val marker = bytes[idx + 1].toInt() and 0xFF
            val length = ((bytes[idx + 2].toInt() and 0xFF) shl 8) or (bytes[idx + 3].toInt() and 0xFF)
            if (marker == 0xE1) {
                if (idx + 10 <= bytes.size &&
                    bytes[idx + 4] == 'E'.code.toByte() &&
                    bytes[idx + 5] == 'x'.code.toByte() &&
                    bytes[idx + 6] == 'i'.code.toByte() &&
                    bytes[idx + 7] == 'f'.code.toByte() &&
                    bytes[idx + 8] == 0.toByte() &&
                    bytes[idx + 9] == 0.toByte()
                ) {
                    val tiffStart = idx + 10
                    val isLe = bytes[tiffStart] == 'I'.code.toByte()
                    fun parseU16(offset: Int): Int {
                        val o = tiffStart + offset
                        if (o + 1 >= bytes.size) return 0
                        val b0 = bytes[o].toInt() and 0xFF
                        val b1 = bytes[o + 1].toInt() and 0xFF
                        return if (isLe) b0 or (b1 shl 8) else (b0 shl 8) or b1
                    }
                    fun parseU32(offset: Int): Int {
                        val o = tiffStart + offset
                        if (o + 3 >= bytes.size) return 0
                        val b0 = bytes[o].toInt() and 0xFF
                        val b1 = bytes[o + 1].toInt() and 0xFF
                        val b2 = bytes[o + 2].toInt() and 0xFF
                        val b3 = bytes[o + 3].toInt() and 0xFF
                        return if (isLe) b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24)
                               else (b0 shl 24) or (b1 shl 16) or (b2 shl 8) or b3
                    }
                    if (parseU16(2) != 42) return 0
                    val firstIfd = parseU32(4)
                    val entries = parseU16(firstIfd)
                    for (e in 0 until entries) {
                        val entryOff = firstIfd + 2 + e * 12
                        val tag = parseU16(entryOff)
                        if (tag == 0x0112) {
                            return when (parseU16(entryOff + 8)) {
                                6 -> 90
                                3 -> 180
                                8 -> 270
                                else -> 0
                            }
                        }
                    }
                }
                break
            }
            idx += 2 + length
        }
        return 0
    }

    private fun getUnifiedCoinClassId(name: String): Int = when (name) {
        "INR_1_COIN" -> 6
        "INR_2_COIN" -> 7
        "INR_5_COIN" -> 8
        "INR_10_COIN" -> 9
        else -> 6
    }

    private fun getUnifiedBanknoteClassId(name: String): Int = when (name) {
        "INR_10" -> 0
        "INR_20" -> 1
        "INR_50" -> 2
        "INR_100" -> 3
        "INR_200" -> 4
        "INR_500" -> 5
        else -> 0
    }

    private fun getCoinValue(name: String): Int = when (name) {
        "INR_1_COIN" -> 1
        "INR_2_COIN" -> 2
        "INR_5_COIN" -> 5
        "INR_10_COIN" -> 10
        else -> 0
    }

    private fun getBanknoteValue(name: String): Int = when (name) {
        "INR_10" -> 10
        "INR_20" -> 20
        "INR_50" -> 50
        "INR_100" -> 100
        "INR_200" -> 200
        "INR_500" -> 500
        else -> 0
    }
}
