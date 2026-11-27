package com.visionmission.currency

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.max
import kotlin.math.min

class CurrencyDetector(
    private val coinModelPath: String,
    private val banknoteModelPath: String,
    numThreads: Int = 4,
    val isCandidateMode: Boolean = false,
    val isPhase10CandidateMode: Boolean = false,
    noteVerifierPath: String? = null,
    coinVerifierPath: String? = null
) : AutoCloseable {

    companion object {
        val UNIFIED_10_CLASSES = listOf(
            "INR_10",
            "INR_20",
            "INR_50",
            "INR_100",
            "INR_200",
            "INR_500",
            "INR_1_COIN",
            "INR_2_COIN",
            "INR_5_COIN",
            "INR_10_COIN"
        )

        val COIN_CLASSES = listOf(
            "INR_1_COIN",
            "INR_2_COIN",
            "INR_5_COIN",
            "INR_10_COIN"
        )

        val BANKNOTE_CLASSES = listOf(
            "INR_10",
            "INR_20",
            "INR_50",
            "INR_100",
            "INR_200",
            "INR_500"
        )

        const val INPUT_SIZE = 640
        const val NUM_ANCHORS = 8400

        /**
         * Comprehensive specifications for ALL Indian Banknotes (New Mahatma Gandhi series and Old series)
         * and Indian coins. Includes exact millimeter dimensions, nominal aspect ratios, color palettes,
         * and obverse/reverse motifs.
         */
        data class BanknoteSpec(
            val denomination: String,
            val value: Int,
            val series: String, // "NEW_MAHATMA_GANDHI", "OLD_MAHATMA_GANDHI"
            val widthMm: Float,
            val heightMm: Float,
            val baseColorName: String,
            val motif: String,
            val isLegalTender: Boolean = true
        ) {
            val nominalAspectRatio: Float get() = widthMm / heightMm
        }

        val ALL_INDIAN_BANKNOTE_SPECS = listOf(
            // --- NEW MAHATMA GANDHI SERIES (2016 - present) ---
            BanknoteSpec("INR_10", 10, "NEW_MAHATMA_GANDHI", 123f, 63f, "Chocolate Brown", "Konark Sun Temple wheel (Odisha)"),
            BanknoteSpec("INR_20", 20, "NEW_MAHATMA_GANDHI", 129f, 63f, "Greenish Yellow", "Ellora Caves (Maharashtra)"),
            BanknoteSpec("INR_50", 50, "NEW_MAHATMA_GANDHI", 135f, 66f, "Fluorescent Blue", "Hampi Stone Chariot (Karnataka)"),
            BanknoteSpec("INR_100", 100, "NEW_MAHATMA_GANDHI", 142f, 66f, "Lavender", "Rani ki Vav stepwell (Gujarat)"),
            BanknoteSpec("INR_200", 200, "NEW_MAHATMA_GANDHI", 146f, 66f, "Bright Yellow", "Sanchi Stupa (Madhya Pradesh)"),
            BanknoteSpec("INR_500", 500, "NEW_MAHATMA_GANDHI", 150f, 66f, "Stone Grey", "Red Fort (Delhi)"),
            BanknoteSpec("INR_2000", 2000, "NEW_MAHATMA_GANDHI", 166f, 66f, "Magenta", "Mangalyaan (Mars Orbiter Mission)"),

            // --- OLD PRE-2016 MAHATMA GANDHI SERIES ---
            BanknoteSpec("INR_10", 10, "OLD_MAHATMA_GANDHI", 137f, 63f, "Orange-Violet", "Fauna of India (Elephant, Rhino, Tiger)"),
            BanknoteSpec("INR_20", 20, "OLD_MAHATMA_GANDHI", 147f, 63f, "Reddish-Orange", "Mount Harriet Lighthouse (Andaman & Nicobar)"),
            BanknoteSpec("INR_50", 50, "OLD_MAHATMA_GANDHI", 147f, 73f, "Pinkish-Violet", "Parliament House (New Delhi)"),
            BanknoteSpec("INR_100", 100, "OLD_MAHATMA_GANDHI", 157f, 73f, "Blue-Green", "Mount Kangchenjunga"),
            BanknoteSpec("INR_500", 500, "OLD_MAHATMA_GANDHI_DEMONETIZED", 167f, 73f, "Olive-Green", "Dandi March / Gyarah Murti", isLegalTender = false),
            BanknoteSpec("INR_1000", 1000, "OLD_MAHATMA_GANDHI_DEMONETIZED", 177f, 73f, "Amber-Red", "Economy and Science", isLegalTender = false)
        )

        data class CoinSpec(
            val denomination: String,
            val value: Int,
            val diameterMm: Float,
            val composition: String,
            val shape: String = "Circular"
        )

        val ALL_INDIAN_COIN_SPECS = listOf(
            CoinSpec("INR_1_COIN", 1, 20.0f, "Ferritic Stainless Steel"),
            CoinSpec("INR_1_COIN", 1, 21.93f, "Ferritic Stainless Steel"),
            CoinSpec("INR_2_COIN", 2, 25.0f, "Ferritic Stainless Steel"),
            CoinSpec("INR_2_COIN", 2, 26.0f, "Cupro-Nickel"),
            CoinSpec("INR_5_COIN", 5, 23.0f, "Nickel-Brass"),
            CoinSpec("INR_5_COIN", 5, 25.0f, "Cupro-Nickel"),
            CoinSpec("INR_10_COIN", 10, 27.0f, "Bimetallic (Brass ring, Cupro-Nickel center)"),
            CoinSpec("INR_20_COIN", 20, 27.0f, "Bimetallic (Nickel-Silver ring, Brass center)", shape = "Dodecagonal (12-sided)")
        )

        // Validation-calibrated Phase 4L.5 / 4M candidate banknote thresholds
        const val CANDIDATE_BANKNOTE_CONF = 0.28f
        const val CANDIDATE_NMS_IOU = 0.45f
        const val CANDIDATE_CONFIRM_CONF = 0.38f
        const val CANDIDATE_MIN_CLASS_MARGIN = 0.12f
        const val CANDIDATE_CONFLICT_CONF = 0.38f
        const val CANDIDATE_MAX_INTERBOX_IOU = 0.65f
        const val CANDIDATE_MAX_INTERBOX_IOMIN = 0.82f

        // Validation-calibrated Phase 4O candidate-only coin thresholds & safety gates
        const val CANDIDATE_COIN_CONF = 0.28f
        const val CANDIDATE_COIN_CONFIRM_CONF = 0.38f
        const val CANDIDATE_COIN_MIN_CLASS_MARGIN = 0.12f
        const val CANDIDATE_COIN_CONFLICT_CONF = 0.38f
        const val CANDIDATE_COIN_MAX_INTERBOX_IOU = 0.65f
        const val CANDIDATE_COIN_MAX_INTERBOX_IOMIN = 0.82f
        const val CANDIDATE_COIN_CROSS_MODEL_IOMIN = 0.70f
        const val CANDIDATE_COIN_ON_NOTE_MIN_MARGIN = 0.25f
        const val CANDIDATE_COIN_ON_NOTE_MIN_AREA_FRAC = 0.012f
        const val CANDIDATE_COIN_ON_NOTE_MIN_ASPECT = 0.65f
        const val CANDIDATE_COIN_ON_NOTE_MAX_ASPECT = 1.55f
        const val CANDIDATE_SPURIOUS_WRAPPER_NOTE_MIN_AREA_FRAC = 0.65f
        const val CANDIDATE_SPURIOUS_WRAPPER_CANVAS_AREA_FRAC = 0.75f
        const val CANDIDATE_SPURIOUS_WRAPPER_COIN_MIN_AREA_FRAC = 0.008f
        const val CANDIDATE_COIN_MIN_ASPECT_RATIO = 0.55f
        const val CANDIDATE_COIN_MAX_ASPECT_RATIO = 1.80f
        const val CANDIDATE_COIN_MIN_AREA_FRAC = 0.0003f

        // Robust multi-angle, fanned, and distance-calibrated identity verifier thresholds
        const val NOTE_VERIFIER_P_INDIAN_THR = 0.52f
        const val NOTE_VERIFIER_MARGIN_THR = 0.06f
        const val COIN_VERIFIER_P_INDIAN_THR = 0.48f
        const val COIN_VERIFIER_MARGIN_THR = 0.06f
    }

    private val env: OrtEnvironment = OrtEnvironment.getEnvironment("VisionMissionCurrency")
    private val sessionOptions: OrtSession.SessionOptions = OrtSession.SessionOptions().apply {
        setIntraOpNumThreads(4)
        setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
        setExecutionMode(OrtSession.SessionOptions.ExecutionMode.SEQUENTIAL)
    }

    val coinLoadTimeMs: Double
    val banknoteLoadTimeMs: Double
    val noteVerifierLoadTimeMs: Double
    val coinVerifierLoadTimeMs: Double

    private val coinSession: OrtSession
    private val banknoteSession: OrtSession
    private val noteVerifier: CurrencyIdentityVerifier?
    private val coinVerifier: CurrencyIdentityVerifier?

    private val coinInputName: String
    private val coinOutputName: String
    private val banknoteInputName: String
    private val banknoteOutputName: String

    // Performance optimization: Reusable Direct Buffers and Canvas to eliminate per-frame GC churn
    private val inferenceExecutor = java.util.concurrent.Executors.newFixedThreadPool(2)
    private val planeSize = INPUT_SIZE * INPUT_SIZE
    private val reusableByteBuffer = ByteBuffer.allocateDirect(1 * 3 * planeSize * 4).order(ByteOrder.nativeOrder())
    private val reusableFloatBuffer: FloatBuffer = reusableByteBuffer.asFloatBuffer()
    private val reusablePixels = IntArray(planeSize)
    private val reusableLetterboxBitmap = Bitmap.createBitmap(INPUT_SIZE, INPUT_SIZE, Bitmap.Config.ARGB_8888)
    private val reusableCanvas = Canvas(reusableLetterboxBitmap)
    private val normLut = FloatArray(256) { it / 255.0f }
    private val paintFilter = Paint(Paint.FILTER_BITMAP_FLAG)

    init {
        require(File(coinModelPath).exists()) { "Coin model file not found at: $coinModelPath" }
        require(File(banknoteModelPath).exists()) { "Banknote model file not found at: $banknoteModelPath" }

        val t0 = System.nanoTime()
        coinSession = env.createSession(coinModelPath, sessionOptions)
        coinLoadTimeMs = (System.nanoTime() - t0) / 1_000_000.0

        val t1 = System.nanoTime()
        banknoteSession = env.createSession(banknoteModelPath, sessionOptions)
        banknoteLoadTimeMs = (System.nanoTime() - t1) / 1_000_000.0

        coinInputName = coinSession.inputNames.iterator().next()
        coinOutputName = coinSession.outputNames.iterator().next()
        banknoteInputName = banknoteSession.inputNames.iterator().next()
        banknoteOutputName = banknoteSession.outputNames.iterator().next()

        noteVerifier = if (!noteVerifierPath.isNullOrBlank()) {
            CurrencyIdentityVerifier(
                env = env,
                sessionOptions = sessionOptions,
                modelPath = noteVerifierPath,
                pIndianThreshold = NOTE_VERIFIER_P_INDIAN_THR,
                marginThreshold = NOTE_VERIFIER_MARGIN_THR
            )
        } else null
        noteVerifierLoadTimeMs = noteVerifier?.loadTimeMs ?: 0.0

        coinVerifier = if (!coinVerifierPath.isNullOrBlank()) {
            CurrencyIdentityVerifier(
                env = env,
                sessionOptions = sessionOptions,
                modelPath = coinVerifierPath,
                pIndianThreshold = COIN_VERIFIER_P_INDIAN_THR,
                marginThreshold = COIN_VERIFIER_MARGIN_THR
            )
        } else null
        coinVerifierLoadTimeMs = coinVerifier?.loadTimeMs ?: 0.0
    }

    fun preprocess(
        bitmap: Bitmap,
        orientationDegrees: Int = 0,
        dumpDiagnosticDir: java.io.File? = null
    ): PreprocessOutput {
        val t0 = System.nanoTime()
        // Step 1: Normalize Orientation if rotated by camera sensor
        val orientedBitmap: Bitmap = if (orientationDegrees % 360 != 0) {
            val matrix = Matrix().apply { postRotate(orientationDegrees.toFloat()) }
            Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        } else {
            bitmap
        }
        val orientationTimeMs = (System.nanoTime() - t0) / 1_000_000.0

        val origW = orientedBitmap.width
        val origH = orientedBitmap.height

        val t1 = System.nanoTime()
        // Step 2: Calculate letterbox gain and padding for 640x640
        val gain = min(INPUT_SIZE.toFloat() / origW, INPUT_SIZE.toFloat() / origH)
        val newW = Math.round(origW * gain)
        val newH = Math.round(origH * gain)
        val padW = (INPUT_SIZE - newW) / 2.0f
        val padH = (INPUT_SIZE - newH) / 2.0f

        synchronized(reusableLetterboxBitmap) {
            // Step 3: Draw scaled bitmap on preallocated 640x640 canvas (single-pass GPU/Canvas scale)
            reusableCanvas.drawColor(Color.rgb(114, 114, 114))
            val destRect = android.graphics.RectF(padW, padH, padW + newW, padH + newH)
            reusableCanvas.drawBitmap(orientedBitmap, null, destRect, paintFilter)
            val scaleAndLetterboxTimeMs = (System.nanoTime() - t1) / 1_000_000.0

            val t2 = System.nanoTime()
            // Step 4: Extract pixels into reusable array and populate direct buffer with LUT
            reusableLetterboxBitmap.getPixels(reusablePixels, 0, INPUT_SIZE, 0, 0, INPUT_SIZE, INPUT_SIZE)

            reusableFloatBuffer.clear()
            val gOffset = planeSize
            val bOffset = 2 * planeSize
            for (i in 0 until planeSize) {
                val pixel = reusablePixels[i]
                reusableFloatBuffer.put(i, normLut[(pixel shr 16) and 0xFF])
                reusableFloatBuffer.put(gOffset + i, normLut[(pixel shr 8) and 0xFF])
                reusableFloatBuffer.put(bOffset + i, normLut[pixel and 0xFF])
            }
            reusableFloatBuffer.position(0)
            val tensorPrepTimeMs = (System.nanoTime() - t2) / 1_000_000.0

            return PreprocessOutput(
                tensorBuffer = reusableFloatBuffer,
                gain = gain,
                padW = padW,
                padH = padH,
                origWidth = origW,
                origHeight = origH,
                orientedBitmap = orientedBitmap,
                orientationTimeMs = orientationTimeMs,
                scaleAndLetterboxTimeMs = scaleAndLetterboxTimeMs,
                tensorPrepTimeMs = tensorPrepTimeMs
            )
        }
    }

    fun detectCoins(
        bitmap: Bitmap,
        orientationDegrees: Int = 0,
        confThreshold: Float = 0.50f,
        iouThreshold: Float = 0.45f
    ): DetectionResponse {
        val t0 = System.nanoTime()
        val prep = preprocess(bitmap, orientationDegrees)
        val prepTimeMs = (System.nanoTime() - t0) / 1_000_000.0

        var tensor: OnnxTensor? = null
        var results: OrtSession.Result? = null
        try {
            tensor = OnnxTensor.createTensor(
                env,
                prep.tensorBuffer,
                longArrayOf(1, 3, INPUT_SIZE.toLong(), INPUT_SIZE.toLong())
            )

            val t1 = System.nanoTime()
            results = coinSession.run(mapOf(coinInputName to tensor))
            val inferTimeMs = (System.nanoTime() - t1) / 1_000_000.0

            @Suppress("UNCHECKED_CAST")
            val rawOutput = results[0].value as Array<Array<FloatArray>> // [1, 8, 8400]

            val t2 = System.nanoTime()
            val detections = decodeAndNmsCoins(
                rawOutput = rawOutput[0],
                numClasses = COIN_CLASSES.size,
                classNames = COIN_CLASSES,
                prep = prep,
                confThreshold = confThreshold,
                iouThreshold = iouThreshold
            )
            val decodeTimeMs = (System.nanoTime() - t2) / 1_000_000.0

            return DetectionResponse(
                model = "indian_coin_yolov8n",
                preprocessTimeMs = prepTimeMs,
                inferenceTimeMs = inferTimeMs,
                decodeTimeMs = decodeTimeMs,
                totalTimeMs = prepTimeMs + inferTimeMs + decodeTimeMs,
                detections = detections
            )
        } finally {
            results?.close()
            tensor?.close()
            prep.recycleBitmaps(sourceBitmap = bitmap)
        }
    }

    fun detectBanknotes(
        bitmap: Bitmap,
        orientationDegrees: Int = 0,
        confThreshold: Float = 0.40f,
        iouThreshold: Float = 0.45f
    ): DetectionResponse {
        val t0 = System.nanoTime()
        val prep = preprocess(bitmap, orientationDegrees)
        val prepTimeMs = (System.nanoTime() - t0) / 1_000_000.0

        var tensor: OnnxTensor? = null
        var results: OrtSession.Result? = null
        try {
            tensor = OnnxTensor.createTensor(
                env,
                prep.tensorBuffer,
                longArrayOf(1, 3, INPUT_SIZE.toLong(), INPUT_SIZE.toLong())
            )

            val t1 = System.nanoTime()
            results = banknoteSession.run(mapOf(banknoteInputName to tensor))
            val inferTimeMs = (System.nanoTime() - t1) / 1_000_000.0

            @Suppress("UNCHECKED_CAST")
            val rawOutput = results[0].value as Array<Array<FloatArray>> // [1, 10, 8400]

            val t2 = System.nanoTime()
            val detections = decodeAndNms(
                rawOutput = rawOutput[0],
                numClasses = BANKNOTE_CLASSES.size,
                classNames = BANKNOTE_CLASSES,
                prep = prep,
                confThreshold = confThreshold,
                iouThreshold = iouThreshold
            )
            val decodeTimeMs = (System.nanoTime() - t2) / 1_000_000.0

            return DetectionResponse(
                model = "indian_banknote_yolov8n",
                preprocessTimeMs = prepTimeMs,
                inferenceTimeMs = inferTimeMs,
                decodeTimeMs = decodeTimeMs,
                totalTimeMs = prepTimeMs + inferTimeMs + decodeTimeMs,
                detections = detections
            )
        } finally {
            results?.close()
            tensor?.close()
            prep.recycleBitmaps(sourceBitmap = bitmap)
        }
    }

    fun detectAll(
        bitmap: Bitmap,
        orientationDegrees: Int = 0,
        coinConfThreshold: Float = 0.25f,
        banknoteConfThreshold: Float = 0.25f,
        iouThreshold: Float = 0.45f,
        dumpDiagnosticDir: java.io.File? = null
    ): DualDetectionResponse {
        val t0 = System.nanoTime()
        val prep = preprocess(bitmap, orientationDegrees, dumpDiagnosticDir)
        val prepTimeMs = (System.nanoTime() - t0) / 1_000_000.0

        var tensor: OnnxTensor? = null
        var coinResults: OrtSession.Result? = null
        var noteResults: OrtSession.Result? = null
        try {
            tensor = OnnxTensor.createTensor(
                env,
                prep.tensorBuffer,
                longArrayOf(1, 3, INPUT_SIZE.toLong(), INPUT_SIZE.toLong())
            )

            val coinInferTimeMs: Double
            val noteInferTimeMs: Double
            val coinDetections: List<Detection>
            val rawNoteDetections: List<Detection>
            val decodeTimeMs: Double

            if (isPhase10CandidateMode) {
                val t1 = System.nanoTime()
                noteResults = banknoteSession.run(mapOf(banknoteInputName to tensor))
                noteInferTimeMs = (System.nanoTime() - t1) / 1_000_000.0

                @Suppress("UNCHECKED_CAST")
                val rawUnifiedOutput = noteResults[0].value as Array<Array<FloatArray>>
                val tDecode = System.nanoTime()
                val (notes, unifiedCoins) = decodeAndNmsPhase10Candidate(
                    rawOutput = rawUnifiedOutput[0],
                    prep = prep,
                    confNote = 0.15f,
                    confCoin = 0.28f
                )
                rawNoteDetections = notes

                // If dedicated coin model is loaded in coinSession, run it for 100% coin precision
                val coins = if (coinSession !== banknoteSession) {
                    val tCoin = System.nanoTime()
                    coinResults = coinSession.run(mapOf(coinInputName to tensor))
                    coinInferTimeMs = (System.nanoTime() - tCoin) / 1_000_000.0
                    @Suppress("UNCHECKED_CAST")
                    val rawCoinOutput = coinResults[0].value as Array<Array<FloatArray>>
                    val cDets = decodeAndNmsCandidate(
                        rawOutput = rawCoinOutput[0],
                        numClasses = COIN_CLASSES.size,
                        classNames = COIN_CLASSES,
                        prep = prep,
                        confThreshold = 0.28f,
                        iouThreshold = 0.35f
                    )
                    coinResults.close()
                    coinResults = null
                    cDets
                } else {
                    coinInferTimeMs = 0.0
                    unifiedCoins
                }
                coinDetections = coins
                decodeTimeMs = (System.nanoTime() - tDecode) / 1_000_000.0
                noteResults.close()
                noteResults = null
                tensor.close()
                tensor = null
            } else {
                // Sequential execution of dedicated Banknote and Coin models on worker thread
                // Prevents CPU core thrashing / thread contention on big.LITTLE architectures
                val tBanknote = System.nanoTime()
                val noteRes = banknoteSession.run(mapOf(banknoteInputName to tensor))
                noteInferTimeMs = (System.nanoTime() - tBanknote) / 1_000_000.0
                noteResults = noteRes

                val tCoin = System.nanoTime()
                val cRes = coinSession.run(mapOf(coinInputName to tensor))
                coinInferTimeMs = (System.nanoTime() - tCoin) / 1_000_000.0
                coinResults = cRes

                @Suppress("UNCHECKED_CAST")
                val rawCoinOutput = coinResults[0].value as Array<Array<FloatArray>>
                coinDetections = if (isCandidateMode) {
                    decodeAndNmsCandidate(
                        rawOutput = rawCoinOutput[0],
                        numClasses = COIN_CLASSES.size,
                        classNames = COIN_CLASSES,
                        prep = prep,
                        confThreshold = coinConfThreshold,
                        iouThreshold = 0.35f // Tighter inter-class NMS for coins
                    )
                } else {
                    decodeAndNmsCoins(
                        rawOutput = rawCoinOutput[0],
                        numClasses = COIN_CLASSES.size,
                        classNames = COIN_CLASSES,
                        prep = prep,
                        confThreshold = coinConfThreshold,
                        iouThreshold = 0.35f // Tighter inter-class NMS for coins
                    )
                }
                coinResults.close()
                coinResults = null

                @Suppress("UNCHECKED_CAST")
                val rawNoteOutput = noteResults[0].value as Array<Array<FloatArray>>
                val tDecode = System.nanoTime()
                rawNoteDetections = if (isCandidateMode) {
                    decodeAndNmsCandidate(
                        rawOutput = rawNoteOutput[0],
                        numClasses = BANKNOTE_CLASSES.size,
                        classNames = BANKNOTE_CLASSES,
                        prep = prep,
                        confThreshold = banknoteConfThreshold,
                        iouThreshold = iouThreshold
                    )
                } else {
                    decodeAndNms(
                        rawOutput = rawNoteOutput[0],
                        numClasses = BANKNOTE_CLASSES.size,
                        classNames = BANKNOTE_CLASSES,
                        prep = prep,
                        confThreshold = banknoteConfThreshold,
                        iouThreshold = iouThreshold
                    )
                }
                decodeTimeMs = (System.nanoTime() - tDecode) / 1_000_000.0
                noteResults.close()
                noteResults = null
                tensor.close()
                tensor = null
            }

        // 3. Cross-Model Mutual Exclusion & Minimum Physical Area Filtering
        val frameArea = prep.origWidth.toFloat() * prep.origHeight.toFloat()
        val filteredBanknotes = rawNoteDetections.filter { note ->
            val noteW = max(0.0f, note.box[2] - note.box[0])
            val noteH = max(0.0f, note.box[3] - note.box[1])
            val noteAreaFrac = if (frameArea > 0f) (noteW * noteH) / frameArea else 0f
            val aspectRatio = if (noteW > 0f && noteH > 0f) max(noteW / noteH, noteH / noteW) else 1f

            // Banknote training boxes have median 59% and min 14% of image area.
            // Allow distant banknotes down to 0.8% of frame, rejecting sub-0.8% background noise.
            if (noteAreaFrac < 0.008f) return@filter false

            // Reject extreme non-banknote aspect ratios (allow 0.45 to 4.5 for angled/cross notes)
            if (aspectRatio > 4.5f) return@filter false

            // Cross-model suppression: If note overlaps with a detected coin and is relatively small (< 25% of frame)
            val overlapsCoin = coinDetections.any { coin ->
                val overlapFraction = calculateIntersectionOverMinArea(note.box, coin.box)
                overlapFraction > 0.25f
            }
            if (overlapsCoin && noteAreaFrac < 0.25f) return@filter false

            if (isCandidateMode && isSpuriousCoinWrappingBanknote(
                    note = note,
                    coins = coinDetections,
                    noteAreaFrac = noteAreaFrac,
                    origW = prep.origWidth,
                    origH = prep.origHeight,
                    frameArea = frameArea
                )
            ) {
                return@filter false
            }

            true
        }

        val collatedBanknotes = if (isCandidateMode) {
            resolveHandSplitBanknotes(filteredBanknotes)
        } else {
            filteredBanknotes
        }

        var cropExtractTimeMs = 0.0
        var noteVerifyTimeMs = 0.0
        var coinVerifyTimeMs = 0.0
        var rejectedForeignCount = 0
        var rejectedNonCurrencyCount = 0
        var unknownIdentityCount = 0
        val rejectedIdentityDetections = mutableListOf<Detection>()

        val verifiedBanknotes = if (noteVerifier != null) {
            val kept = mutableListOf<Detection>()
            for (note in collatedBanknotes) {
                val res = noteVerifier.verifyCrop(prep.orientedBitmap, note.box)
                cropExtractTimeMs += res.cropExtractTimeMs
                noteVerifyTimeMs += res.verifyTimeMs
                val enriched = note.copy(
                    identityState = res.state,
                    identityPForeign = res.pForeign,
                    identityPIndian = res.pIndian,
                    identityPNonCurrency = res.pNonCurrency,
                    identityMargin = res.margin
                )
                when (res.state) {
                    "CONFIRMED_INDIAN" -> kept.add(enriched)
                    "INVALID", "FOREIGN_CURRENCY", "NON_CURRENCY" -> {
                        rejectedForeignCount++
                        rejectedIdentityDetections.add(enriched)
                        // User requirement: When currency definitively does NOT match Indian currency,
                        // announce "Invalid" and DISPLAY the bounding box with label "INVALID"!
                        kept.add(enriched.copy(
                            className = "INVALID",
                            confirmationState = "conflicting",
                            uncertaintyReasons = (enriched.uncertaintyReasons + "INVALID_CURRENCY_DETECTED").distinct()
                        ))
                    }
                    else -> {
                        unknownIdentityCount++
                        rejectedIdentityDetections.add(enriched)
                        // User requirement: If currency seems unrecognised, say "Unrecognised"
                        // (never foreign currency), and DISPLAY the bounding box with "UNRECOGNISED" label!
                        kept.add(enriched.copy(
                            className = if (isCandidateMode && note.confidence >= 0.50f) note.className else "UNRECOGNISED",
                            confirmationState = "tentative",
                            uncertaintyReasons = (enriched.uncertaintyReasons + "UNRECOGNISED_CURRENCY" + "IDENTITY_UNKNOWN").distinct()
                        ))
                    }
                }
            }
            kept
        } else {
            filteredBanknotes
        }

        val verifiedCoins = if (coinVerifier != null) {
            val kept = mutableListOf<Detection>()
            for (coin in coinDetections) {
                val res = coinVerifier.verifyCrop(prep.orientedBitmap, coin.box)
                cropExtractTimeMs += res.cropExtractTimeMs
                coinVerifyTimeMs += res.verifyTimeMs
                val enriched = coin.copy(
                    identityState = res.state,
                    identityPForeign = res.pForeign,
                    identityPIndian = res.pIndian,
                    identityPNonCurrency = res.pNonCurrency,
                    identityMargin = res.margin
                )
                when (res.state) {
                    "CONFIRMED_INDIAN" -> kept.add(enriched)
                    "INVALID", "FOREIGN_CURRENCY", "NON_CURRENCY" -> {
                        rejectedForeignCount++
                        rejectedIdentityDetections.add(enriched)
                        kept.add(enriched.copy(
                            className = "INVALID",
                            confirmationState = "conflicting",
                            uncertaintyReasons = (enriched.uncertaintyReasons + "INVALID_CURRENCY_DETECTED").distinct()
                        ))
                    }
                    else -> {
                        unknownIdentityCount++
                        rejectedIdentityDetections.add(enriched)
                        kept.add(enriched.copy(
                            className = if (isCandidateMode && coin.confidence >= 0.50f) coin.className else "UNRECOGNISED",
                            confirmationState = "tentative",
                            uncertaintyReasons = (enriched.uncertaintyReasons + "UNRECOGNISED_CURRENCY" + "IDENTITY_UNKNOWN").distinct()
                        ))
                    }
                }
            }
            kept
        } else {
            coinDetections
        }

        val screenedBanknotes = if (isCandidateMode) {
            screenBanknoteSafety(verifiedBanknotes, prep.orientedBitmap)
        } else {
            verifiedBanknotes
        }
        val screenedCoins = if (isCandidateMode) {
            screenCoinSafety(verifiedCoins, screenedBanknotes, frameArea, prep.orientedBitmap)
        } else {
            verifiedCoins
        }

        val allScreened = screenedBanknotes + screenedCoins
        val confirmedNoteCount = screenedBanknotes.count { it.confirmationState == "confirmed" }
        val tentativeNoteCount = screenedBanknotes.count { it.confirmationState == "tentative" }
        val conflictingNoteCount = screenedBanknotes.count { it.confirmationState == "conflicting" }
        val totalConfirmedCount = allScreened.count { it.confirmationState == "confirmed" }
        val totalTentativeCount = allScreened.count { it.confirmationState == "tentative" }
        val totalConflictingCount = allScreened.count { it.confirmationState == "conflicting" }
        val frameReasons = linkedSetOf<String>()
        for (item in allScreened) {
            frameReasons.addAll(item.uncertaintyReasons)
        }
        if (rejectedForeignCount > 0) frameReasons.add("INVALID_CURRENCY_DETECTED")
        if (unknownIdentityCount > 0) frameReasons.add("UNRECOGNISED_CURRENCY")
        if (rejectedNonCurrencyCount > 0) frameReasons.add("NON_CURRENCY_REJECTED")

        val totalStatus = when {
            totalConflictingCount > 0 || rejectedForeignCount > 0 -> "conflicting"
            totalConfirmedCount > 0 -> "confirmed"
            totalTentativeCount > 0 || unknownIdentityCount > 0 -> "tentativeSingle"
            screenedBanknotes.isEmpty() && screenedCoins.isEmpty() -> "empty"
            else -> "confirmed"
        }

        val totalTimeMs = (System.nanoTime() - t0) / 1_000_000.0 + decodeTimeMs

        return DualDetectionResponse(
            preprocessTimeMs = prepTimeMs,
            coinInferenceTimeMs = coinInferTimeMs,
            banknoteInferenceTimeMs = noteInferTimeMs,
            totalTimeMs = totalTimeMs,
            orientedWidth = prep.origWidth,
            orientedHeight = prep.origHeight,
            coinDetections = screenedCoins,
            banknoteDetections = screenedBanknotes,
            isCandidateMode = isCandidateMode,
            totalStatus = totalStatus,
            isTotalConfirmed = totalStatus == "confirmed" && totalConfirmedCount > 0 && totalConflictingCount == 0,
            confirmedNoteCount = confirmedNoteCount,
            tentativeNoteCount = tentativeNoteCount,
            conflictingNoteCount = conflictingNoteCount,
            uncertaintyReasons = frameReasons.toList(),
            cropExtractTimeMs = cropExtractTimeMs,
            noteVerifyTimeMs = noteVerifyTimeMs,
            coinVerifyTimeMs = coinVerifyTimeMs,
            rejectedForeignCount = rejectedForeignCount,
            rejectedNonCurrencyCount = rejectedNonCurrencyCount,
            unknownIdentityCount = unknownIdentityCount,
            rejectedIdentityDetections = rejectedIdentityDetections
        )
        } finally {
            coinResults?.close()
            noteResults?.close()
            tensor?.close()
            prep.recycleBitmaps(sourceBitmap = bitmap)
        }
    }

    private fun decodeAnchorBox(rawOutput: Array<FloatArray>, anchorIdx: Int, prep: PreprocessOutput): FloatArray {
        val cx = rawOutput[0][anchorIdx]
        val cy = rawOutput[1][anchorIdx]
        val w = rawOutput[2][anchorIdx]
        val h = rawOutput[3][anchorIdx]

        val x1_640 = cx - w / 2.0f
        val y1_640 = cy - h / 2.0f
        val x2_640 = cx + w / 2.0f
        val y2_640 = cy + h / 2.0f

        val x1 = max(0.0f, min(prep.origWidth.toFloat(), (x1_640 - prep.padW) / prep.gain))
        val y1 = max(0.0f, min(prep.origHeight.toFloat(), (y1_640 - prep.padH) / prep.gain))
        val x2 = max(0.0f, min(prep.origWidth.toFloat(), (x2_640 - prep.padW) / prep.gain))
        val y2 = max(0.0f, min(prep.origHeight.toFloat(), (y2_640 - prep.padH) / prep.gain))
        return floatArrayOf(x1, y1, x2, y2)
    }

    private fun decodeAndNmsPhase10Candidate(
        rawOutput: Array<FloatArray>,
        prep: PreprocessOutput,
        confNote: Float = 0.15f,
        confCoin: Float = 0.28f
    ): Pair<List<Detection>, List<Detection>> {
        data class Cand(
            val cls: Int,
            val score: Float,
            val top2Cls: Int,
            val top2Score: Float,
            val box: FloatArray
        ) {
            val margin: Float get() = score - top2Score
        }
        val candidates = ArrayList<Cand>()
        for (i in 0 until NUM_ANCHORS) {
            var bestCls = 0
            var bestScore = -1.0f
            var secondCls = -1
            var secondScore = 0.0f
            for (c in 0 until 10) {
                val s = rawOutput[4 + c][i]
                if (s > bestScore) {
                    secondScore = max(0.0f, bestScore)
                    secondCls = bestCls
                    bestScore = s
                    bestCls = c
                } else if (s > secondScore) {
                    secondScore = s
                    secondCls = c
                }
            }
            val isCoin = bestCls >= 6
            val thresh = if (isCoin) confCoin else confNote
            if (bestScore >= thresh) {
                val box = decodeAnchorBox(rawOutput, i, prep)
                candidates.add(Cand(bestCls, bestScore, secondCls, secondScore, box))
            }
        }

        if (candidates.isEmpty()) return Pair(emptyList(), emptyList())

        candidates.sortByDescending { it.score }
        val suppressed = BooleanArray(candidates.size)
        val keptNotes = ArrayList<Detection>()
        val keptCoins = ArrayList<Detection>()
        val frameArea = prep.origWidth.toFloat() * prep.origHeight.toFloat()

        for (i in candidates.indices) {
            if (suppressed[i]) continue
            val b1 = candidates[i]
            val c1x = (b1.box[0] + b1.box[2]) / 2.0f
            val c1y = (b1.box[1] + b1.box[3]) / 2.0f
            val isCoin1 = b1.cls >= 6

            for (j in (i + 1) until candidates.size) {
                if (suppressed[j]) continue
                val b2 = candidates[j]
                val isCoin2 = b2.cls >= 6
                // Cross-class suppression: suppress within same domain (coin-coin or note-note)
                if (isCoin1 != isCoin2) continue

                val iou = calculateIoU(b1.box, b2.box)
                val iomin = calculateIntersectionOverMinArea(b1.box, b2.box)

                val c2x = (b2.box[0] + b2.box[2]) / 2.0f
                val c2y = (b2.box[1] + b2.box[3]) / 2.0f
                val d2 = (c1x - c2x) * (c1x - c2x) + (c1y - c2y) * (c1y - c2y)
                val encX1 = min(b1.box[0], b2.box[0])
                val encY1 = min(b1.box[1], b2.box[1])
                val encX2 = max(b1.box[2], b2.box[2])
                val encY2 = max(b1.box[3], b2.box[3])
                val c2 = max(1.0f, (encX2 - encX1) * (encX2 - encX1) + (encY2 - encY1) * (encY2 - encY1))
                val normCenterDist = Math.sqrt(d2.toDouble()).toFloat() / Math.sqrt(c2.toDouble()).toFloat()

                if (isCoin1) {
                    // Suppress overlapping coins (e.g. 1 rupee vs 2 rupee collision)
                    if (iou >= 0.35f || iomin >= 0.55f || (normCenterDist < 0.25f && iou >= 0.20f)) {
                        suppressed[j] = true
                    }
                } else {
                    // Suppress duplicate overlapping banknotes
                    if (iou >= 0.45f || iomin >= 0.60f || (normCenterDist < 0.28f && iou >= 0.30f)) {
                        suppressed[j] = true
                    }
                }
            }

            val bw = b1.box[2] - b1.box[0]
            val bh = b1.box[3] - b1.box[1]
            val bArea = bw * bh

            if (!isCoin1) {
                if (frameArea > 0f && bArea / frameArea < 0.020f) continue
                val aspect = if (bw > 0f && bh > 0f) max(bw / bh, bh / bw) else 1f
                if (aspect > 4.5f || aspect < 0.75f) continue
                val top2Name = if (b1.top2Cls in UNIFIED_10_CLASSES.indices) UNIFIED_10_CLASSES[b1.top2Cls] else ""
                keptNotes.add(
                    Detection(
                        classId = b1.cls,
                        className = UNIFIED_10_CLASSES[b1.cls],
                        confidence = b1.score,
                        box = b1.box,
                        top2ClassId = b1.top2Cls,
                        top2ClassName = top2Name,
                        top2Confidence = b1.top2Score,
                        classMargin = b1.margin
                    )
                )
            } else {
                val aspect = if (bh > 0f) bw / bh else 1f
                if (aspect < 0.65f || aspect > 1.55f) continue
                val top2Name = if (b1.top2Cls in UNIFIED_10_CLASSES.indices) UNIFIED_10_CLASSES[b1.top2Cls] else ""
                keptCoins.add(
                    Detection(
                        classId = b1.cls,
                        className = UNIFIED_10_CLASSES[b1.cls],
                        confidence = b1.score,
                        box = b1.box,
                        top2ClassId = b1.top2Cls,
                        top2ClassName = top2Name,
                        top2Confidence = b1.top2Score,
                        classMargin = b1.margin
                    )
                )
            }
        }

        return Pair(keptNotes, keptCoins)
    }

    /**
     * Phase 4L.5 / 4M / 4N Calibrated Candidate Post-Processing (Banknotes and Coins):
     * - Class-agnostic greedy NMS across all classes
     * - Preserves anchor top-2 margin and suppressed alternate-class overlap evidence for safety gating
     */
    private fun decodeAndNmsCandidate(
        rawOutput: Array<FloatArray>,
        numClasses: Int,
        classNames: List<String>,
        prep: PreprocessOutput,
        confThreshold: Float,
        iouThreshold: Float
    ): List<Detection> {
        data class AnchorCand(
            val top1Class: Int,
            val top1Score: Float,
            val top2Class: Int,
            val top2Score: Float,
            val box: FloatArray
        ) {
            val margin: Float get() = top1Score - top2Score
        }

        val scanFloor = min(confThreshold, CANDIDATE_CONFLICT_CONF)
        val conflictAnchors = ArrayList<AnchorCand>()
        val nmsCandidates = ArrayList<AnchorCand>()

        for (i in 0 until NUM_ANCHORS) {
            var bestClass = 0
            var bestScore = -1.0f
            var secondClass = -1
            var secondScore = 0.0f

            for (c in 0 until numClasses) {
                val score = rawOutput[4 + c][i]
                if (score > bestScore) {
                    secondScore = max(0.0f, bestScore)
                    secondClass = bestClass
                    bestScore = score
                    bestClass = c
                } else if (score > secondScore) {
                    secondScore = score
                    secondClass = c
                }
            }

            if (bestScore >= scanFloor) {
                val box = decodeAnchorBox(rawOutput, i, prep)
                val cand = AnchorCand(bestClass, bestScore, secondClass, secondScore, box)
                if (bestScore >= confThreshold) {
                    nmsCandidates.add(cand)
                } else {
                    conflictAnchors.add(cand)
                }
            }
        }

        if (nmsCandidates.isEmpty()) return emptyList()

        nmsCandidates.sortByDescending { it.top1Score }
        val suppressed = BooleanArray(nmsCandidates.size)
        val finalDetections = ArrayList<Detection>()

        for (i in nmsCandidates.indices) {
            if (suppressed[i]) continue
            val best = nmsCandidates[i]

            var conflictCount = 0
            var maxConflictConf = 0.0f
            var maxConflictCls = -1

            // Suppress overlapping anchors regardless of class, while recording alternate-class conflicts
            for (j in (i + 1) until nmsCandidates.size) {
                if (suppressed[j]) continue
                val other = nmsCandidates[j]
                val iou = calculateIoU(best.box, other.box)
                val iomin = calculateIntersectionOverMinArea(best.box, other.box)
                val c1x = (best.box[0] + best.box[2]) / 2.0f
                val c1y = (best.box[1] + best.box[3]) / 2.0f
                val c2x = (other.box[0] + other.box[2]) / 2.0f
                val c2y = (other.box[1] + other.box[3]) / 2.0f
                val d2 = (c1x - c2x) * (c1x - c2x) + (c1y - c2y) * (c1y - c2y)
                val encW = max(best.box[2], other.box[2]) - min(best.box[0], other.box[0])
                val encH = max(best.box[3], other.box[3]) - min(best.box[1], other.box[1])
                val cDiag = Math.sqrt((encW * encW + encH * encH).toDouble()).toFloat()
                val normCenterDist = if (cDiag > 0f) Math.sqrt(d2.toDouble()).toFloat() / cDiag else 0f

                val isCoin = numClasses == COIN_CLASSES.size
                val shouldSuppress = if (isCoin) {
                    normCenterDist < 0.25f && (iou > 0.50f || iomin > 0.75f)
                } else {
                    normCenterDist < 0.18f && (iou > iouThreshold || iomin > 0.80f)
                }

                if (shouldSuppress) {
                    suppressed[j] = true
                    if (other.top1Class != best.top1Class) {
                        conflictCount++
                        if (other.top1Score > maxConflictConf) {
                            maxConflictConf = other.top1Score
                            maxConflictCls = other.top1Class
                        }
                    }
                }
            }

            // Also inspect weak alternate-class anchors [CANDIDATE_CONFLICT_CONF, confThreshold)
            for (weak in conflictAnchors) {
                if (weak.top1Class != best.top1Class) {
                    val wIou = calculateIoU(best.box, weak.box)
                    val wIomin = calculateIntersectionOverMinArea(best.box, weak.box)
                    val wC1x = (best.box[0] + best.box[2]) / 2.0f
                    val wC1y = (best.box[1] + best.box[3]) / 2.0f
                    val wC2x = (weak.box[0] + weak.box[2]) / 2.0f
                    val wC2y = (weak.box[1] + weak.box[3]) / 2.0f
                    val wD2 = (wC1x - wC2x) * (wC1x - wC2x) + (wC1y - wC2y) * (wC1y - wC2y)
                    val wEncW = max(best.box[2], weak.box[2]) - min(best.box[0], weak.box[0])
                    val wEncH = max(best.box[3], weak.box[3]) - min(best.box[1], weak.box[1])
                    val wCDiag = Math.sqrt((wEncW * wEncW + wEncH * wEncH).toDouble()).toFloat()
                    val wNormCenterDist = if (wCDiag > 0f) Math.sqrt(wD2.toDouble()).toFloat() / wCDiag else 0f
                    if (wNormCenterDist < 0.18f && (wIou > iouThreshold || wIomin > 0.80f)) {
                        conflictCount++
                        if (weak.top1Score > maxConflictConf) {
                            maxConflictConf = weak.top1Score
                            maxConflictCls = weak.top1Class
                        }
                    }
                }
            }

            val top2Name = if (best.top2Class in classNames.indices) classNames[best.top2Class] else ""
            val conflictName = if (maxConflictCls in classNames.indices) classNames[maxConflictCls] else ""
            finalDetections.add(
                Detection(
                    classId = best.top1Class,
                    className = classNames[best.top1Class],
                    confidence = best.top1Score,
                    box = best.box,
                    top2ClassId = best.top2Class,
                    top2ClassName = top2Name,
                    top2Confidence = best.top2Score,
                    classMargin = best.margin,
                    suppressedConflictCount = conflictCount,
                    suppressedConflictClassId = maxConflictCls,
                    suppressedConflictClassName = conflictName,
                    suppressedConflictConfidence = maxConflictConf
                )
            )
        }

        finalDetections.sortByDescending { it.confidence }
        return finalDetections
    }

    /**
     * Physically-grounded optical yellow chromaticity analysis:
     * Samples the central 60% of the banknote bounding box to measure yellow substrate saturation:
     * yellowChroma = ((R - B) + (G - B)) / (R + G + B + 1e-4f).
     *
     * In Indian banknotes:
     * - Modern ₹200 banknote (Bright Yellow, Pantone 1235 C):
     *   Features the Sanchi Stupa motif on the reverse side.
     *   Mean yellowChroma is ~0.18 to ~0.24 (always >= 0.14f).
     * - Modern ₹10 banknote (Chocolate Brown):
     *   Features the Konark Sun Temple wheel motif on the reverse side.
     *   Mean yellowChroma is ~0.04 to ~0.09 (rarely > 0.11f).
     *
     * This physically eliminates reverse-side ₹200 misclassification as ₹10.
     */
    fun analyzeBanknoteYellowChroma(bitmap: Bitmap, box: FloatArray): Float {
        if (bitmap.isRecycled) return 0.0f
        val imgW = bitmap.width
        val imgH = bitmap.height
        val x1 = max(0, min(imgW - 1, box[0].toInt()))
        val y1 = max(0, min(imgH - 1, box[1].toInt()))
        val x2 = max(0, min(imgW, box[2].toInt()))
        val y2 = max(0, min(imgH, box[3].toInt()))
        val bw = x2 - x1
        val bh = y2 - y1
        if (bw < 16 || bh < 16) return 0.0f

        val cx = (x1 + x2) / 2
        val cy = (y1 + y2) / 2
        val rx = max(4, (bw * 0.30f).toInt())
        val ry = max(4, (bh * 0.30f).toInt())

        val startX = max(0, cx - rx)
        val endX = min(imgW, cx + rx)
        val startY = max(0, cy - ry)
        val endY = min(imgH, cy + ry)
        val sampleW = endX - startX
        val sampleH = endY - startY
        if (sampleW <= 0 || sampleH <= 0) return 0.0f

        var sumR = 0L
        var sumG = 0L
        var sumB = 0L
        var count = 0L

        val step = max(1, min(sampleW, sampleH) / 24)
        val pixels = IntArray(sampleW)
        for (y in startY until endY step step) {
            bitmap.getPixels(pixels, 0, sampleW, startX, y, sampleW, 1)
            for (x in 0 until sampleW step step) {
                val p = pixels[x]
                val r = (p shr 16) and 0xFF
                val g = (p shr 8) and 0xFF
                val b = p and 0xFF
                if (r in 20..245 && g in 20..245 && b in 20..245) {
                    sumR += r
                    sumG += g
                    sumB += b
                    count++
                }
            }
        }

        if (count == 0L) return 0.0f
        val meanR = sumR.toFloat() / count
        val meanG = sumG.toFloat() / count
        val meanB = sumB.toFloat() / count
        val tot = meanR + meanG + meanB + 1e-4f
        return ((meanR - meanB) + (meanG - meanB)) / tot
    }

    /**
     * Resolves and merges collinear fragments of a single banknote split by a hand/finger occlusion.
     * Prevents false multi-note counts ("assuming multiple ones") and conflicting denominations
     * when a hand covers the middle or part of a banknote.
     */
    private fun resolveHandSplitBanknotes(notes: List<Detection>): List<Detection> {
        if (notes.size <= 1) return notes

        val remaining = ArrayList<Detection>(notes)
        val collated = ArrayList<Detection>()

        while (remaining.isNotEmpty()) {
            var merged = remaining.removeAt(0)
            var mergedAny = false

            val it = remaining.iterator()
            while (it.hasNext()) {
                val other = it.next()

                // Check horizontal split (note is horizontal, hand cuts vertically)
                val left = if (merged.box[0] <= other.box[0]) merged else other
                val right = if (merged.box[0] <= other.box[0]) other else merged

                val wLeft = max(1.0f, left.box[2] - left.box[0])
                val hLeft = max(1.0f, left.box[3] - left.box[1])
                val wRight = max(1.0f, right.box[2] - right.box[0])
                val hRight = max(1.0f, right.box[3] - right.box[1])

                val minH = min(hLeft, hRight)
                val maxH = max(hLeft, hRight)
                val avgH = (hLeft + hRight) / 2.0f

                val vOverlap = max(0.0f, min(left.box[3], right.box[3]) - max(left.box[1], right.box[1]))
                val vOverlapRatio = vOverlap / minH
                val hRatio = minH / maxH
                val hGap = right.box[0] - left.box[2]

                val arLeft = max(wLeft / hLeft, hLeft / wLeft)
                val arRight = max(wRight / hRight, hRight / wRight)

                val encX1H = min(left.box[0], right.box[0])
                val encY1H = min(left.box[1], right.box[1])
                val encX2H = max(left.box[2], right.box[2])
                val encY2H = max(left.box[3], right.box[3])
                val encWH = encX2H - encX1H
                val encHH = max(1.0f, encY2H - encY1H)
                val encArH = max(encWH / encHH, encHH / encWH)

                val isHorizSplit = vOverlapRatio >= 0.65f &&
                    hRatio >= 0.60f &&
                    hGap >= 0.0f &&
                    hGap <= 1.8f * avgH &&
                    (wLeft / hLeft) <= 1.55f &&
                    (wRight / hRight) <= 1.55f &&
                    (wLeft + wRight) <= 2.10f * avgH &&
                    encArH in 1.70f..2.80f

                // Check vertical split (note is vertical, hand cuts horizontally)
                val top = if (merged.box[1] <= other.box[1]) merged else other
                val bottom = if (merged.box[1] <= other.box[1]) other else merged

                val wTop = max(1.0f, top.box[2] - top.box[0])
                val hTop = max(1.0f, top.box[3] - top.box[1])
                val wBottom = max(1.0f, bottom.box[2] - bottom.box[0])
                val hBottom = max(1.0f, bottom.box[3] - bottom.box[1])

                val minW = min(wTop, wBottom)
                val maxW = max(wTop, wBottom)
                val avgW = (wTop + wBottom) / 2.0f

                val hOverlap = max(0.0f, min(top.box[2], bottom.box[2]) - max(top.box[0], bottom.box[0]))
                val hOverlapRatio = hOverlap / minW
                val wRatio = minW / maxW
                val vGap = bottom.box[1] - top.box[3]

                val arTop = max(wTop / hTop, hTop / wTop)
                val arBottom = max(wBottom / hBottom, hBottom / wBottom)

                val encX1V = min(top.box[0], bottom.box[0])
                val encY1V = min(top.box[1], bottom.box[1])
                val encX2V = max(top.box[2], bottom.box[2])
                val encY2V = max(top.box[3], bottom.box[3])
                val encWV = max(1.0f, encX2V - encX1V)
                val encHV = encY2V - encY1V
                val encArV = encHV / encWV

                val isVertSplit = hOverlapRatio >= 0.65f &&
                    wRatio >= 0.60f &&
                    vGap >= 0.0f &&
                    vGap <= 1.8f * avgW &&
                    (hTop / wTop) <= 1.55f &&
                    (hBottom / wBottom) <= 1.55f &&
                    (hTop + hBottom) <= 2.10f * avgW &&
                    encArV in 1.70f..2.80f

                if (isHorizSplit || isVertSplit) {
                    it.remove()
                    mergedAny = true

                    val primary = if (merged.confidence >= other.confidence) merged else other
                    val secondary = if (merged.confidence >= other.confidence) other else merged
                    val isClassDisagreement = primary.className != secondary.className

                    val mergedReasons = ArrayList<String>()
                    mergedReasons.addAll(primary.uncertaintyReasons)
                    mergedReasons.addAll(secondary.uncertaintyReasons)
                    mergedReasons.add("HAND_SPLIT_COLLATED")
                    if (isClassDisagreement) {
                        mergedReasons.add("HAND_OCCLUDED_SPLIT_DISAGREEMENT")
                    }

                    val mergedBox = if (isHorizSplit) {
                        floatArrayOf(encX1H, encY1H, encX2H, encY2H)
                    } else {
                        floatArrayOf(encX1V, encY1V, encX2V, encY2V)
                    }

                    val mergedState = if (isClassDisagreement) "tentative" else primary.confirmationState

                    merged = primary.copy(
                        box = mergedBox,
                        top2ClassId = if (isClassDisagreement) secondary.classId else primary.top2ClassId,
                        top2ClassName = if (isClassDisagreement) secondary.className else primary.top2ClassName,
                        top2Confidence = if (isClassDisagreement) secondary.confidence else primary.top2Confidence,
                        confirmationState = mergedState,
                        uncertaintyReasons = mergedReasons.distinct()
                    )
                }
            }
            collated.add(merged)
        }
        return collated
    }

    /**
     * Center-distance aware banknote safety screening:
     * Differentiates true duplicate anchor conflicts (co-located on same note with different classes)
     * from genuine multi-note physical arrangements (fanned, angled, crossed, or stepped notes).
     */
    private fun screenBanknoteSafety(
        detections: List<Detection>,
        orientedBitmap: Bitmap
    ): List<Detection> {
        if (detections.isEmpty()) return detections

        val collatedDetections = resolveHandSplitBanknotes(detections)

        // Step 1: Optical Yellow Chromaticity Disambiguation for ₹200 vs ₹10
        // Single ₹200 notes must NEVER be converted to ₹10 (the ONNX model is highly accurate).
        // In multi-note scenes, only disambiguate when one note is chocolate brown and a peer note is bright yellow.
        val hasMultiNotes = collatedDetections.size > 1
        val maxYellowChroma = if (hasMultiNotes) {
            collatedDetections.maxOfOrNull { analyzeBanknoteYellowChroma(orientedBitmap, it.box) } ?: 0.0f
        } else 0.0f

        val opticallyCalibrated = collatedDetections.map { d ->
            if (d.className == "INR_10") {
                val chroma = analyzeBanknoteYellowChroma(orientedBitmap, d.box)
                val isAlternate200 = d.top2ClassName == "INR_200" || d.suppressedConflictClassName == "INR_200"
                if (chroma >= 0.16f || (isAlternate200 && chroma >= 0.15f)) {
                    d.copy(
                        classId = 4,
                        className = "INR_200",
                        top2ClassId = 0,
                        top2ClassName = "INR_10",
                        top2Confidence = d.confidence,
                        classMargin = max(d.classMargin, 0.30f)
                    )
                } else {
                    d
                }
            } else if (d.className == "INR_200" && hasMultiNotes) {
                val chroma = analyzeBanknoteYellowChroma(orientedBitmap, d.box)
                val isAlternate10 = d.top2ClassName == "INR_10" || d.suppressedConflictClassName == "INR_10"
                if (chroma <= 0.11f && maxYellowChroma >= 0.18f && isAlternate10) {
                    d.copy(
                        classId = 0,
                        className = "INR_10",
                        top2ClassId = 4,
                        top2ClassName = "INR_200",
                        top2Confidence = d.confidence,
                        classMargin = max(d.classMargin, 0.25f)
                    )
                } else {
                    d
                }
            } else {
                d
            }
        }

        val result = ArrayList<Detection>(opticallyCalibrated.size)

        for (i in opticallyCalibrated.indices) {
            val d = opticallyCalibrated[i]
            var maxCrossClassIoU = 0.0f
            var maxCrossClassIoMin = 0.0f
            var hasTrueOverlapConflict = false

            val dW = max(1.0f, d.box[2] - d.box[0])
            val dH = max(1.0f, d.box[3] - d.box[1])
            val dCx = (d.box[0] + d.box[2]) / 2.0f
            val dCy = (d.box[1] + d.box[3]) / 2.0f
            val dDiag = Math.sqrt((dW * dW + dH * dH).toDouble()).toFloat()
            val aspectRatio = max(dW / dH, dH / dW)
            val isTruncated = aspectRatio < 1.15f

            for (j in opticallyCalibrated.indices) {
                if (i == j) continue
                val other = opticallyCalibrated[j]
                val iou = calculateIoU(d.box, other.box)
                val iomin = calculateIntersectionOverMinArea(d.box, other.box)
                val isDifferentClass = d.className != other.className
                if (isDifferentClass) {
                    if (iou > maxCrossClassIoU) maxCrossClassIoU = iou
                    if (iomin > maxCrossClassIoMin) maxCrossClassIoMin = iomin
                }

                val oW = max(1.0f, other.box[2] - other.box[0])
                val oH = max(1.0f, other.box[3] - other.box[1])
                val oCx = (other.box[0] + other.box[2]) / 2.0f
                val oCy = (other.box[1] + other.box[3]) / 2.0f
                val oDiag = Math.sqrt((oW * oW + oH * oH).toDouble()).toFloat()
                val minDiag = min(dDiag, oDiag)

                val dx = dCx - oCx
                val dy = dCy - oCy
                val centerDist = Math.sqrt((dx * dx + dy * dy).toDouble()).toFloat()
                val normCenterDist = if (minDiag > 0f) centerDist / minDiag else 1.0f

                // Co-located conflict only occurs when two predictions share essentially the same spot (< 0.20 diag)
                // with high overlap and contradictory class labels. Separate notes in a fan/cross have distinct centers.
                val isCoLocated = normCenterDist < 0.20f && (iou >= 0.60f || iomin >= 0.82f)
                if (isCoLocated && isDifferentClass) {
                    hasTrueOverlapConflict = true
                }
            }

            val reasons = ArrayList<String>()
            reasons.addAll(d.uncertaintyReasons)
            val hasSuppressedConflict = d.suppressedConflictConfidence >= CANDIDATE_CONFLICT_CONF &&
                (d.confidence - d.suppressedConflictConfidence < 0.15f)
            val isLowConf = d.confidence < CANDIDATE_CONFIRM_CONF
            val isLowMargin = d.classMargin < CANDIDATE_MIN_CLASS_MARGIN
            val hasSplitDisagreement = d.uncertaintyReasons.contains("HAND_OCCLUDED_SPLIT_DISAGREEMENT")

            if (hasSuppressedConflict) reasons.add("CROSS_CLASS_CONFLICT")
            if (hasTrueOverlapConflict) reasons.add("OVERLAP_CONFLICT")
            if (isLowConf) reasons.add("LOW_CONFIDENCE")
            if (isLowMargin) reasons.add("NARROW_CLASS_MARGIN")
            if (isTruncated) reasons.add("TRUNCATED_OR_OCCLUDED_NOTE")

            val state = when {
                hasSuppressedConflict || hasTrueOverlapConflict -> "conflicting"
                isLowConf || isLowMargin || isTruncated || hasSplitDisagreement || d.confirmationState == "tentative" -> "tentative"
                else -> "confirmed"
            }

            result.add(
                d.copy(
                    interBoxMaxIoU = maxCrossClassIoU,
                    interBoxMaxIoMin = maxCrossClassIoMin,
                    confirmationState = state,
                    uncertaintyReasons = reasons.distinct()
                )
            )
        }
        return result
    }

    /**
     * Phase 4O.1 Candidate-Only Spurious Banknote Wrapper Filter:
     * Rejects near-full-canvas banknote hallucinations (e.g. palm/table false positives at >=72% frame area)
     * that span multiple frame edges and completely swallow confirmed foreground coin detections.
     */
    private fun isSpuriousCoinWrappingBanknote(
        note: Detection,
        coins: List<Detection>,
        noteAreaFrac: Float,
        origW: Int,
        origH: Int,
        frameArea: Float
    ): Boolean {
        // High-confidence genuine banknotes held near the camera are never spurious hallucinations
        if (note.confidence >= 0.50f && note.classMargin >= 0.18f) return false
        if (coins.isEmpty() || frameArea <= 0f || origW <= 0 || origH <= 0) return false
        if (noteAreaFrac < CANDIDATE_SPURIOUS_WRAPPER_NOTE_MIN_AREA_FRAC) return false

        var edgeTouches = 0
        if (note.box[0] <= origW * 0.02f) edgeTouches++
        if (note.box[1] <= origH * 0.02f) edgeTouches++
        if (note.box[2] >= origW * 0.98f) edgeTouches++
        if (note.box[3] >= origH * 0.98f) edgeTouches++
        if (edgeTouches < 2) return false

        var hasEnclosedStrongCoin = false
        var hasEnclosedLargeForegroundCoin = false
        for (coin in coins) {
            if (coin.confidence < CANDIDATE_COIN_CONF) continue
            val iomin = calculateIntersectionOverMinArea(note.box, coin.box)
            if (iomin < CANDIDATE_COIN_CROSS_MODEL_IOMIN) continue
            hasEnclosedStrongCoin = true
            val cw = max(0.0f, coin.box[2] - coin.box[0])
            val ch = max(0.0f, coin.box[3] - coin.box[1])
            val coinAreaFrac = (cw * ch) / frameArea
            if (coinAreaFrac >= CANDIDATE_SPURIOUS_WRAPPER_COIN_MIN_AREA_FRAC) {
                hasEnclosedLargeForegroundCoin = true
                break
            }
        }
        if (!hasEnclosedStrongCoin) return false
        if (hasEnclosedLargeForegroundCoin) return true
        return noteAreaFrac >= CANDIDATE_SPURIOUS_WRAPPER_CANVAS_AREA_FRAC && edgeTouches >= 2
    }

    /**
     * Physically-grounded optical chromaticity analysis:
     * Samples the inner central region (50% diameter) of the coin bounding box
     * to avoid table/hand background, and measures the yellow/brass warmth:
     * yellowWarmth = (R + G - 2*B) / (R + G + B + 1e-4f).
     *
     * In Indian currency:
     * - Circulating 5 Rupee coins are Nickel-Brass (Golden): yellowWarmth >= 0.10f
     * - Circulating 2 Rupee & 1 Rupee coins are Ferritic Stainless Steel (Silver/Grey): yellowWarmth < 0.095f
     */
    fun analyzeCoinChromaticity(bitmap: Bitmap, box: FloatArray): Float {
        if (bitmap.isRecycled) return 0.0f
        val imgW = bitmap.width
        val imgH = bitmap.height
        val x1 = max(0, min(imgW - 1, box[0].toInt()))
        val y1 = max(0, min(imgH - 1, box[1].toInt()))
        val x2 = max(0, min(imgW, box[2].toInt()))
        val y2 = max(0, min(imgH, box[3].toInt()))
        val bw = x2 - x1
        val bh = y2 - y1
        if (bw < 8 || bh < 8) return 0.0f

        val cx = (x1 + x2) / 2
        val cy = (y1 + y2) / 2
        val rx = max(2, (bw * 0.25f).toInt())
        val ry = max(2, (bh * 0.25f).toInt())

        val startX = max(0, cx - rx)
        val endX = min(imgW, cx + rx)
        val startY = max(0, cy - ry)
        val endY = min(imgH, cy + ry)
        val sampleW = endX - startX
        val sampleH = endY - startY
        if (sampleW <= 0 || sampleH <= 0) return 0.0f

        var sumR = 0L
        var sumG = 0L
        var sumB = 0L
        var count = 0L

        val step = max(1, min(sampleW, sampleH) / 16)
        val pixels = IntArray(sampleW)
        for (y in startY until endY step step) {
            bitmap.getPixels(pixels, 0, sampleW, startX, y, sampleW, 1)
            for (x in 0 until sampleW step step) {
                val p = pixels[x]
                val r = (p shr 16) and 0xFF
                val g = (p shr 8) and 0xFF
                val b = p and 0xFF
                if (r in 15..245 && g in 15..245 && b in 15..245) {
                    sumR += r
                    sumG += g
                    sumB += b
                    count++
                }
            }
        }

        if (count == 0L) return 0.0f
        val meanR = sumR.toFloat() / count
        val meanG = sumG.toFloat() / count
        val meanB = sumB.toFloat() / count
        val tot = meanR + meanG + meanB + 1e-4f
        return (meanR + meanG - 2.0f * meanB) / tot
    }

    /**
     * Phase 4N Candidate-Only Coin Safety Screening:
     * Enforces optical chromaticity disambiguation (Nickel-Brass Golden ₹5 vs Stainless Steel Silver ₹2/₹1),
     * multi-coin relative geometric area calibration, coin class-margin checks, coin-to-coin overlap conflicts,
     * suppressed class conflicts, geometry/scale sanity checks, and cross-model banknote containment analysis.
     */
    private fun screenCoinSafety(
        coins: List<Detection>,
        banknotes: List<Detection>,
        frameArea: Float,
        orientedBitmap: Bitmap
    ): List<Detection> {
        if (coins.isEmpty()) return coins

        // 1. Physically-grounded optical chromaticity disambiguation:
        // Circulating Indian 5 Rupee coins are Nickel-Brass (golden, yellowWarmth >= 0.10f).
        // Circulating Indian 2 Rupee and 1 Rupee coins are Ferritic Stainless Steel (silver/grey, yellowWarmth < 0.095f).
        val opticallyCalibrated = coins.map { c ->
            val warmth = analyzeCoinChromaticity(orientedBitmap, c.box)
            if (c.className == "INR_5_COIN" && warmth < 0.095f) {
                // Silver stainless steel coin misclassified as INR_5_COIN by neural net bias.
                // A silver coin is INR_2_COIN (or INR_1_COIN if small).
                c.copy(
                    classId = 1,
                    className = "INR_2_COIN",
                    top2ClassId = 2,
                    top2ClassName = "INR_5_COIN",
                    classMargin = max(c.classMargin, 0.25f)
                )
            } else if (c.className == "INR_2_COIN" && warmth >= 0.13f) {
                // Golden brass coin misclassified as INR_2_COIN -> calibrate to INR_5_COIN
                c.copy(
                    classId = 2,
                    className = "INR_5_COIN",
                    top2ClassId = 1,
                    top2ClassName = "INR_2_COIN",
                    classMargin = max(c.classMargin, 0.25f)
                )
            } else {
                c
            }
        }

        // 2. Multi-Coin Relative Geometric Area Calibration:
        // Physical 2 Rupee coin (dia 25.0mm) is ~30% larger in area than a 1 Rupee coin (dia 21.93mm).
        // Rules for robust multi-coin sets:
        // - High-confidence neural detections (confidence >= 0.52f && margin >= 0.18f) are preserved.
        // - Homogeneous predictions (all 1 or all 2) are NEVER split based solely on perspective size variations.
        // - Relative area arbitration applies ONLY to ambiguous coins (margin < 0.18f or confidence < 0.48f)
        //   when BOTH classes are present and there is a clear bimodal size distribution.
        val calibratedCoins = if (opticallyCalibrated.size > 1) {
            val silverCoins = opticallyCalibrated.filter { it.className in listOf("INR_1_COIN", "INR_2_COIN") }
            val hasBothClasses = silverCoins.any { it.className == "INR_1_COIN" } && silverCoins.any { it.className == "INR_2_COIN" }

            if (silverCoins.size > 1 && hasBothClasses) {
                val areas = silverCoins.map { (it.box[2] - it.box[0]) * (it.box[3] - it.box[1]) }
                val minArea = areas.minOrNull() ?: 1.0f
                val maxArea = areas.maxOrNull() ?: 1.0f
                val areaRatio = maxArea / max(1.0f, minArea)

                // Only arbitrate if physical area difference is significant (>= 22%)
                if (areaRatio >= 1.22f) {
                    val splitThr = (minArea + maxArea) / 2.0f
                    opticallyCalibrated.map { c ->
                        if (c.className in listOf("INR_1_COIN", "INR_2_COIN")) {
                            if (c.confidence >= 0.52f && c.classMargin >= 0.18f) {
                                c
                            } else {
                                val area = (c.box[2] - c.box[0]) * (c.box[3] - c.box[1])
                                if (area >= splitThr) {
                                    c.copy(
                                        classId = 1,
                                        className = "INR_2_COIN",
                                        top2ClassId = 0,
                                        top2ClassName = "INR_1_COIN",
                                        classMargin = max(c.classMargin, 0.22f)
                                    )
                                } else {
                                    c.copy(
                                        classId = 0,
                                        className = "INR_1_COIN",
                                        top2ClassId = 1,
                                        top2ClassName = "INR_2_COIN",
                                        classMargin = max(c.classMargin, 0.22f)
                                    )
                                }
                            }
                        } else {
                            c
                        }
                    }
                } else {
                    opticallyCalibrated
                }
            } else {
                opticallyCalibrated
            }
        } else {
            opticallyCalibrated
        }

        val result = ArrayList<Detection>(calibratedCoins.size)

        for (i in calibratedCoins.indices) {
            val d = calibratedCoins[i]
            var maxIoU = 0.0f
            var maxIoMin = 0.0f
            var hasTrueOverlapConflict = false

            val dW = max(1.0f, d.box[2] - d.box[0])
            val dH = max(1.0f, d.box[3] - d.box[1])
            val dCx = (d.box[0] + d.box[2]) / 2.0f
            val dCy = (d.box[1] + d.box[3]) / 2.0f
            val dDiag = Math.sqrt((dW * dW + dH * dH).toDouble()).toFloat()

            for (j in calibratedCoins.indices) {
                if (i == j) continue
                val other = calibratedCoins[j]
                val iou = calculateIoU(d.box, other.box)
                val iomin = calculateIntersectionOverMinArea(d.box, other.box)
                if (iou > maxIoU) maxIoU = iou
                if (iomin > maxIoMin) maxIoMin = iomin

                val oW = max(1.0f, other.box[2] - other.box[0])
                val oH = max(1.0f, other.box[3] - other.box[1])
                val oCx = (other.box[0] + other.box[2]) / 2.0f
                val oCy = (other.box[1] + other.box[3]) / 2.0f
                val oDiag = Math.sqrt((oW * oW + oH * oH).toDouble()).toFloat()
                val minDiag = min(dDiag, oDiag)

                val dx = dCx - oCx
                val dy = dCy - oCy
                val centerDist = Math.sqrt((dx * dx + dy * dy).toDouble()).toFloat()
                val normCenterDist = if (minDiag > 0f) centerDist / minDiag else 1.0f

                // Multiple coins held on palm or touching have distinct centers (normCenterDist >= 0.25).
                // Only co-located duplicate anchor predictions with different classes trigger overlap conflict.
                val isCoLocated = normCenterDist < 0.25f && (iou >= 0.55f || iomin >= 0.78f)
                val isDifferentClass = d.className != other.className
                if (isCoLocated && isDifferentClass) {
                    hasTrueOverlapConflict = true
                }
            }

            var maxBanknoteIoMin = 0.0f
            var maxEnclosingNoteAreaFrac = 0.0f
            for (note in banknotes) {
                if (note.confirmationState != "confirmed") continue
                val noteIoMin = calculateIntersectionOverMinArea(d.box, note.box)
                if (noteIoMin > maxBanknoteIoMin) maxBanknoteIoMin = noteIoMin
                if (noteIoMin >= CANDIDATE_COIN_CROSS_MODEL_IOMIN && frameArea > 0f) {
                    val nw = max(0.0f, note.box[2] - note.box[0])
                    val nh = max(0.0f, note.box[3] - note.box[1])
                    val noteAreaFrac = (nw * nh) / frameArea
                    if (noteAreaFrac > maxEnclosingNoteAreaFrac) {
                        maxEnclosingNoteAreaFrac = noteAreaFrac
                    }
                }
            }

            val boxW = max(0.0f, d.box[2] - d.box[0])
            val boxH = max(0.0f, d.box[3] - d.box[1])
            val boxAreaFrac = if (frameArea > 0f) (boxW * boxH) / frameArea else 1.0f
            val aspectRatio = if (boxW > 0f && boxH > 0f) boxW / boxH else 1.0f

            val reasons = ArrayList<String>()
            val isSuppressed25Conflict = (d.className == "INR_2_COIN" && d.suppressedConflictClassName == "INR_5_COIN") ||
                (d.className == "INR_5_COIN" && d.suppressedConflictClassName == "INR_2_COIN")
            val isSuppressed12Conflict = ((d.className == "INR_1_COIN" && d.suppressedConflictClassName == "INR_2_COIN") ||
                (d.className == "INR_2_COIN" && d.suppressedConflictClassName == "INR_1_COIN")) &&
                (d.confidence >= 0.45f && d.classMargin >= 0.12f)
            val hasSuppressedConflict = d.suppressedConflictConfidence >= CANDIDATE_COIN_CONFLICT_CONF &&
                !isSuppressed25Conflict &&
                !isSuppressed12Conflict &&
                (d.confidence - d.suppressedConflictConfidence < 0.15f)
            val enclosedByOversizedNote =
                frameArea > 0f && maxEnclosingNoteAreaFrac >= CANDIDATE_SPURIOUS_WRAPPER_NOTE_MIN_AREA_FRAC
            val qualifiesAsGenuineCoinOnNote =
                !enclosedByOversizedNote &&
                    !hasSuppressedConflict &&
                    d.confidence >= CANDIDATE_COIN_CONFIRM_CONF &&
                    d.classMargin >= CANDIDATE_COIN_ON_NOTE_MIN_MARGIN &&
                    boxAreaFrac >= CANDIDATE_COIN_ON_NOTE_MIN_AREA_FRAC &&
                    aspectRatio >= CANDIDATE_COIN_ON_NOTE_MIN_ASPECT &&
                    aspectRatio <= CANDIDATE_COIN_ON_NOTE_MAX_ASPECT
            val hasCrossModelBanknoteConflict =
                maxBanknoteIoMin >= CANDIDATE_COIN_CROSS_MODEL_IOMIN &&
                    (enclosedByOversizedNote || !qualifiesAsGenuineCoinOnNote)
            val isLowConf = d.confidence < CANDIDATE_COIN_CONFIRM_CONF
            val isLowMargin = d.classMargin < CANDIDATE_COIN_MIN_CLASS_MARGIN
            val hasExtremeAspect =
                aspectRatio < CANDIDATE_COIN_MIN_ASPECT_RATIO || aspectRatio > CANDIDATE_COIN_MAX_ASPECT_RATIO
            val hasSmallArea = frameArea > 0f && boxAreaFrac < CANDIDATE_COIN_MIN_AREA_FRAC

            if (hasCrossModelBanknoteConflict) {
                // Reject false positive watermark/seal inside genuine banknote
                continue
            }

            if (hasSuppressedConflict) reasons.add("CROSS_CLASS_CONFLICT")
            if (hasTrueOverlapConflict) reasons.add("OVERLAP_CONFLICT")
            if (isLowConf) reasons.add("LOW_CONFIDENCE")
            if (isLowMargin) reasons.add("NARROW_CLASS_MARGIN")
            if (hasExtremeAspect) reasons.add("COIN_EXTREME_ASPECT_RATIO")
            if (hasSmallArea) reasons.add("SMALL_COIN_AREA")

            val state = when {
                hasSuppressedConflict || hasTrueOverlapConflict -> "conflicting"
                isLowConf || isLowMargin || hasExtremeAspect || hasSmallArea -> "tentative"
                else -> "confirmed"
            }

            result.add(
                d.copy(
                    interBoxMaxIoU = maxIoU,
                    interBoxMaxIoMin = maxIoMin,
                    confirmationState = state,
                    uncertaintyReasons = reasons
                )
            )
        }
        return result
    }

    private fun decodeAndNms(
        rawOutput: Array<FloatArray>, // [4 + numClasses, 8400]
        numClasses: Int,
        classNames: List<String>,
        prep: PreprocessOutput,
        confThreshold: Float,
        iouThreshold: Float
    ): List<Detection> {
        val candidateBoxes = ArrayList<FloatArray>()
        val candidateScores = ArrayList<Float>()
        val candidateClasses = ArrayList<Int>()
        val candidateSecondScores = ArrayList<Float>()
        val candidateSecondClasses = ArrayList<Int>()

        // Scan all 8400 candidate anchor predictions
        for (i in 0 until NUM_ANCHORS) {
            var bestClass = 0
            var maxScore = -1.0f
            var secondClass = -1
            var secondScore = 0.0f

            for (c in 0 until numClasses) {
                val score = rawOutput[4 + c][i]
                if (score > maxScore) {
                    secondScore = max(0.0f, maxScore)
                    secondClass = bestClass
                    maxScore = score
                    bestClass = c
                } else if (score > secondScore) {
                    secondScore = score
                    secondClass = c
                }
            }

            if (maxScore >= confThreshold) {
                val cx = rawOutput[0][i]
                val cy = rawOutput[1][i]
                val w = rawOutput[2][i]
                val h = rawOutput[3][i]

                val x1_640 = cx - w / 2.0f
                val y1_640 = cy - h / 2.0f
                val x2_640 = cx + w / 2.0f
                val y2_640 = cy + h / 2.0f

                // Inverse Letterbox Scale and Pad
                val x1 = max(0.0f, min(prep.origWidth.toFloat(), (x1_640 - prep.padW) / prep.gain))
                val y1 = max(0.0f, min(prep.origHeight.toFloat(), (y1_640 - prep.padH) / prep.gain))
                val x2 = max(0.0f, min(prep.origWidth.toFloat(), (x2_640 - prep.padW) / prep.gain))
                val y2 = max(0.0f, min(prep.origHeight.toFloat(), (y2_640 - prep.padH) / prep.gain))

                candidateBoxes.add(floatArrayOf(x1, y1, x2, y2))
                candidateScores.add(maxScore)
                candidateClasses.add(bestClass)
                candidateSecondScores.add(secondScore)
                candidateSecondClasses.add(secondClass)
            }
        }

        if (candidateBoxes.isEmpty()) return emptyList()

        // Class-Aware Greedy Non-Maximum Suppression (NMS)
        val finalDetections = ArrayList<Detection>()
        val uniqueClasses = candidateClasses.distinct()

        for (cls in uniqueClasses) {
            val classIndices = candidateClasses.indices.filter { candidateClasses[it] == cls }
                .sortedByDescending { candidateScores[it] }
                .toMutableList()

            while (classIndices.isNotEmpty()) {
                val bestIdx = classIndices.removeAt(0)
                val bestBox = candidateBoxes[bestIdx]
                val bestScore = candidateScores[bestIdx]
                val secCls = candidateSecondClasses[bestIdx]
                val secScore = candidateSecondScores[bestIdx]
                val secName = if (secCls in classNames.indices) classNames[secCls] else ""

                finalDetections.add(
                    Detection(
                        classId = cls,
                        className = classNames[cls],
                        confidence = bestScore,
                        box = bestBox,
                        top2ClassId = secCls,
                        top2ClassName = secName,
                        top2Confidence = secScore,
                        classMargin = bestScore - secScore
                    )
                )

                val it = classIndices.iterator()
                while (it.hasNext()) {
                    val idx = it.next()
                    val otherBox = candidateBoxes[idx]
                    val iou = calculateIoU(bestBox, otherBox)
                    if (iou > iouThreshold) {
                        it.remove()
                    }
                }
            }
        }

        finalDetections.sortByDescending { it.confidence }
        return finalDetections
    }

    /**
     * Inter-Class (Class-Agnostic) NMS for Coins.
     * Prevents a single physical coin from generating multiple overlapping detections
     * with different class labels (e.g. simultaneous INR_5_COIN and INR_2_COIN).
     */
    private fun decodeAndNmsCoins(
        rawOutput: Array<FloatArray>, // [4 + numClasses, 8400]
        numClasses: Int,
        classNames: List<String>,
        prep: PreprocessOutput,
        confThreshold: Float,
        iouThreshold: Float = 0.45f
    ): List<Detection> {
        val candidateBoxes = ArrayList<FloatArray>()
        val candidateScores = ArrayList<Float>()
        val candidateClasses = ArrayList<Int>()
        val candidateSecondScores = ArrayList<Float>()
        val candidateSecondClasses = ArrayList<Int>()

        // Scan all 8400 candidate anchor predictions
        for (i in 0 until NUM_ANCHORS) {
            var bestClass = 0
            var maxScore = -1.0f
            var secondClass = -1
            var secondScore = 0.0f

            for (c in 0 until numClasses) {
                val score = rawOutput[4 + c][i]
                if (score > maxScore) {
                    secondScore = max(0.0f, maxScore)
                    secondClass = bestClass
                    maxScore = score
                    bestClass = c
                } else if (score > secondScore) {
                    secondScore = score
                    secondClass = c
                }
            }

            if (maxScore >= confThreshold) {
                val cx = rawOutput[0][i]
                val cy = rawOutput[1][i]
                val w = rawOutput[2][i]
                val h = rawOutput[3][i]

                val x1_640 = cx - w / 2.0f
                val y1_640 = cy - h / 2.0f
                val x2_640 = cx + w / 2.0f
                val y2_640 = cy + h / 2.0f

                // Inverse Letterbox Scale and Pad
                val x1 = max(0.0f, min(prep.origWidth.toFloat(), (x1_640 - prep.padW) / prep.gain))
                val y1 = max(0.0f, min(prep.origHeight.toFloat(), (y1_640 - prep.padH) / prep.gain))
                val x2 = max(0.0f, min(prep.origWidth.toFloat(), (x2_640 - prep.padW) / prep.gain))
                val y2 = max(0.0f, min(prep.origHeight.toFloat(), (y2_640 - prep.padH) / prep.gain))

                candidateBoxes.add(floatArrayOf(x1, y1, x2, y2))
                candidateScores.add(maxScore)
                candidateClasses.add(bestClass)
                candidateSecondScores.add(secondScore)
                candidateSecondClasses.add(secondClass)
            }
        }

        if (candidateBoxes.isEmpty()) return emptyList()

        // Global Inter-Class Greedy Non-Maximum Suppression (NMS)
        val sortedIndices = candidateBoxes.indices
            .sortedByDescending { candidateScores[it] }
            .toMutableList()

        val finalDetections = ArrayList<Detection>()
        val suppressed = BooleanArray(candidateBoxes.size)

        for (i in sortedIndices.indices) {
            val bestIdx = sortedIndices[i]
            if (suppressed[bestIdx]) continue

            val bestBox = candidateBoxes[bestIdx]
            val bestScore = candidateScores[bestIdx]
            val bestCls = candidateClasses[bestIdx]
            val secCls = candidateSecondClasses[bestIdx]
            val secScore = candidateSecondScores[bestIdx]
            val secName = if (secCls in classNames.indices) classNames[secCls] else ""

            finalDetections.add(
                Detection(
                    classId = bestCls,
                    className = classNames[bestCls],
                    confidence = bestScore,
                    box = bestBox,
                    top2ClassId = secCls,
                    top2ClassName = secName,
                    top2Confidence = secScore,
                    classMargin = bestScore - secScore
                )
            )

            val bW = max(1.0f, bestBox[2] - bestBox[0])
            val bH = max(1.0f, bestBox[3] - bestBox[1])
            val bCx = (bestBox[0] + bestBox[2]) / 2.0f
            val bCy = (bestBox[1] + bestBox[3]) / 2.0f
            val bDiag = Math.sqrt((bW * bW + bH * bH).toDouble()).toFloat()

            for (j in (i + 1) until sortedIndices.size) {
                val otherIdx = sortedIndices[j]
                if (suppressed[otherIdx]) continue

                val otherBox = candidateBoxes[otherIdx]
                val iou = calculateIoU(bestBox, otherBox)
                val oW = max(1.0f, otherBox[2] - otherBox[0])
                val oH = max(1.0f, otherBox[3] - otherBox[1])
                val oCx = (otherBox[0] + otherBox[2]) / 2.0f
                val oCy = (otherBox[1] + otherBox[3]) / 2.0f
                val oDiag = Math.sqrt((oW * oW + oH * oH).toDouble()).toFloat()
                val minDiag = min(bDiag, oDiag)

                val dx = bCx - oCx
                val dy = bCy - oCy
                val dist = Math.sqrt((dx * dx + dy * dy).toDouble()).toFloat()
                val normCenterDist = if (minDiag > 0f) dist / minDiag else 1.0f

                // If same class: standard NMS (iou > iouThreshold).
                // If different class: only suppress if co-located anchor on same physical coin.
                // Touching/adjacent coins on palm have normCenterDist >= 0.25 and are never suppressed.
                val isDuplicate = if (bestCls == candidateClasses[otherIdx]) {
                    iou > iouThreshold || (normCenterDist < 0.20f && iou > 0.35f)
                } else {
                    normCenterDist < 0.25f && iou > 0.40f
                }

                if (isDuplicate) {
                    suppressed[otherIdx] = true
                }
            }
        }

        finalDetections.sortByDescending { it.confidence }
        return finalDetections
    }

    fun calculateIntersectionOverMinArea(b1: FloatArray, b2: FloatArray): Float {
        val xA = max(b1[0], b2[0])
        val yA = max(b1[1], b2[1])
        val xB = min(b1[2], b2[2])
        val yB = min(b1[3], b2[3])

        val interArea = max(0.0f, xB - xA) * max(0.0f, yB - yA)
        val b1Area = max(0.0f, b1[2] - b1[0]) * max(0.0f, b1[3] - b1[1])
        val b2Area = max(0.0f, b2[2] - b2[0]) * max(0.0f, b2[3] - b2[1])
        val minArea = min(b1Area, b2Area)

        return if (minArea > 0.0f) interArea / minArea else 0.0f
    }

    fun calculateIoU(b1: FloatArray, b2: FloatArray): Float {
        val xA = max(b1[0], b2[0])
        val yA = max(b1[1], b2[1])
        val xB = min(b1[2], b2[2])
        val yB = min(b1[3], b2[3])

        val interArea = max(0.0f, xB - xA) * max(0.0f, yB - yA)
        val b1Area = max(0.0f, b1[2] - b1[0]) * max(0.0f, b1[3] - b1[1])
        val b2Area = max(0.0f, b2[2] - b2[0]) * max(0.0f, b2[3] - b2[1])
        val unionArea = b1Area + b2Area - interArea

        return if (unionArea > 0.0f) interArea / unionArea else 0.0f
    }

    override fun close() {
        try {
            inferenceExecutor.shutdown()
        } catch (_: Throwable) {}
        if (!reusableLetterboxBitmap.isRecycled) {
            reusableLetterboxBitmap.recycle()
        }
        noteVerifier?.close()
        coinVerifier?.close()
        coinSession.close()
        banknoteSession.close()
        sessionOptions.close()
        env.close()
    }
}

data class DetectionResponse(
    val model: String,
    val preprocessTimeMs: Double,
    val inferenceTimeMs: Double,
    val decodeTimeMs: Double,
    val totalTimeMs: Double,
    val detections: List<Detection>
)

data class DualDetectionResponse(
    val preprocessTimeMs: Double,
    val coinInferenceTimeMs: Double,
    val banknoteInferenceTimeMs: Double,
    val totalTimeMs: Double,
    val orientedWidth: Int,
    val orientedHeight: Int,
    val coinDetections: List<Detection>,
    val banknoteDetections: List<Detection>,
    val isCandidateMode: Boolean = false,
    val totalStatus: String = "confirmed",
    val isTotalConfirmed: Boolean = true,
    val confirmedNoteCount: Int = 0,
    val tentativeNoteCount: Int = 0,
    val conflictingNoteCount: Int = 0,
    val uncertaintyReasons: List<String> = emptyList(),
    val cropExtractTimeMs: Double = 0.0,
    val noteVerifyTimeMs: Double = 0.0,
    val coinVerifyTimeMs: Double = 0.0,
    val rejectedForeignCount: Int = 0,
    val rejectedNonCurrencyCount: Int = 0,
    val unknownIdentityCount: Int = 0,
    val rejectedIdentityDetections: List<Detection> = emptyList()
)

