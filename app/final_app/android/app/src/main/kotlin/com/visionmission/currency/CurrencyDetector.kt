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
    noteVerifierPath: String? = null,
    coinVerifierPath: String? = null
) : AutoCloseable {

    companion object {
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

        // Validation-calibrated Phase 4L.5 / 4M candidate banknote thresholds
        const val CANDIDATE_BANKNOTE_CONF = 0.30f
        const val CANDIDATE_NMS_IOU = 0.45f
        const val CANDIDATE_CONFIRM_CONF = 0.45f
        const val CANDIDATE_MIN_CLASS_MARGIN = 0.15f
        const val CANDIDATE_CONFLICT_CONF = 0.25f
        const val CANDIDATE_MAX_INTERBOX_IOU = 0.25f
        const val CANDIDATE_MAX_INTERBOX_IOMIN = 0.70f

        // Validation-calibrated Phase 4O candidate-only coin thresholds & safety gates (production behavior untouched)
        const val CANDIDATE_COIN_CONF = 0.35f
        const val CANDIDATE_COIN_CONFIRM_CONF = 0.60f
        const val CANDIDATE_COIN_MIN_CLASS_MARGIN = 0.15f
        const val CANDIDATE_COIN_CONFLICT_CONF = 0.25f
        const val CANDIDATE_COIN_MAX_INTERBOX_IOU = 0.25f
        const val CANDIDATE_COIN_MAX_INTERBOX_IOMIN = 0.70f
        const val CANDIDATE_COIN_CROSS_MODEL_IOMIN = 0.70f
        const val CANDIDATE_COIN_ON_NOTE_MIN_MARGIN = 0.25f
        const val CANDIDATE_COIN_ON_NOTE_MIN_AREA_FRAC = 0.012f
        const val CANDIDATE_COIN_ON_NOTE_MIN_ASPECT = 0.70f
        const val CANDIDATE_COIN_ON_NOTE_MAX_ASPECT = 1.45f
        const val CANDIDATE_SPURIOUS_WRAPPER_NOTE_MIN_AREA_FRAC = 0.72f
        const val CANDIDATE_SPURIOUS_WRAPPER_CANVAS_AREA_FRAC = 0.88f
        const val CANDIDATE_SPURIOUS_WRAPPER_COIN_MIN_AREA_FRAC = 0.022f
        const val CANDIDATE_COIN_MIN_ASPECT_RATIO = 0.60f
        const val CANDIDATE_COIN_MAX_ASPECT_RATIO = 1.65f
        const val CANDIDATE_COIN_MIN_AREA_FRAC = 0.002f

        // Phase 4O.17D Combination B calibrated thresholds (N5 + original Phase 4O.10 coin verifier)
        const val NOTE_VERIFIER_P_INDIAN_THR = 0.85f
        const val NOTE_VERIFIER_MARGIN_THR = 0.10f
        const val COIN_VERIFIER_P_INDIAN_THR = 0.60f
        const val COIN_VERIFIER_MARGIN_THR = 0.30f
    }

    private val env: OrtEnvironment = OrtEnvironment.getEnvironment("VisionMissionCurrency")
    private val sessionOptions: OrtSession.SessionOptions = OrtSession.SessionOptions().apply {
        setIntraOpNumThreads(numThreads)
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
        // Step 1: Normalize Orientation if rotated by camera sensor
        val orientedBitmap: Bitmap = if (orientationDegrees % 360 != 0) {
            val matrix = Matrix().apply { postRotate(orientationDegrees.toFloat()) }
            Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        } else {
            bitmap
        }

        val origW = orientedBitmap.width
        val origH = orientedBitmap.height

        // Step 2: Calculate letterbox gain and padding for 640x640
        val gain = min(INPUT_SIZE.toFloat() / origW, INPUT_SIZE.toFloat() / origH)
        val newW = Math.round(origW * gain)
        val newH = Math.round(origH * gain)
        val padW = (INPUT_SIZE - newW) / 2.0f
        val padH = (INPUT_SIZE - newH) / 2.0f

        // Step 3: Draw scaled bitmap on 640x640 canvas padded with constant color (114, 114, 114)
        val scaledBitmap = Bitmap.createScaledBitmap(orientedBitmap, newW, newH, true)
        val letterboxedBitmap = Bitmap.createBitmap(INPUT_SIZE, INPUT_SIZE, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(letterboxedBitmap)
        canvas.drawColor(Color.rgb(114, 114, 114))
        canvas.drawBitmap(scaledBitmap, padW, padH, Paint(Paint.FILTER_BITMAP_FLAG))

        // Step 4: Extract pixels and fill direct FloatBuffer in [1, 3, 640, 640] CHW layout normalized to [0.0f, 1.0f]
        val pixels = IntArray(INPUT_SIZE * INPUT_SIZE)
        letterboxedBitmap.getPixels(pixels, 0, INPUT_SIZE, 0, 0, INPUT_SIZE, INPUT_SIZE)

        val rawByteBuffer = ByteBuffer.allocateDirect(1 * 3 * INPUT_SIZE * INPUT_SIZE * 4)
            .order(ByteOrder.nativeOrder())
        val floatBuffer = rawByteBuffer.asFloatBuffer()

        val rOffset = 0
        val gOffset = INPUT_SIZE * INPUT_SIZE
        val bOffset = 2 * INPUT_SIZE * INPUT_SIZE

        val rArray = FloatArray(INPUT_SIZE * INPUT_SIZE)
        val gArray = FloatArray(INPUT_SIZE * INPUT_SIZE)
        val bArray = FloatArray(INPUT_SIZE * INPUT_SIZE)

        for (i in pixels.indices) {
            val pixel = pixels[i]
            rArray[i] = ((pixel shr 16) and 0xFF) / 255.0f
            gArray[i] = ((pixel shr 8) and 0xFF) / 255.0f
            bArray[i] = (pixel and 0xFF) / 255.0f
        }

        floatBuffer.put(rArray)
        floatBuffer.put(gArray)
        floatBuffer.put(bArray)
        floatBuffer.rewind()

        if (isCandidateMode && dumpDiagnosticDir != null) {
            dumpDiagnosticDir.mkdirs()
            java.io.FileOutputStream(java.io.File(dumpDiagnosticDir, "stage_b_rotated.png")).use { fos ->
                orientedBitmap.compress(Bitmap.CompressFormat.PNG, 100, fos)
            }
            java.io.FileOutputStream(java.io.File(dumpDiagnosticDir, "stage_c_letterbox_640.png")).use { fos ->
                letterboxedBitmap.compress(Bitmap.CompressFormat.PNG, 100, fos)
            }
            val dumpBuf = rawByteBuffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
            dumpBuf.rewind()
            val bytesOut = ByteArray(dumpBuf.remaining())
            dumpBuf.get(bytesOut)
            java.io.File(dumpDiagnosticDir, "stage_c_tensor_1x3x640x640_nchw.bin").writeBytes(bytesOut)
        }

        return PreprocessOutput(
            tensorBuffer = floatBuffer,
            gain = gain,
            padW = padW,
            padH = padH,
            origWidth = origW,
            origHeight = origH,
            orientedBitmap = orientedBitmap
        )
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

        val tensor = OnnxTensor.createTensor(
            env,
            prep.tensorBuffer,
            longArrayOf(1, 3, INPUT_SIZE.toLong(), INPUT_SIZE.toLong())
        )

        val t1 = System.nanoTime()
        val results = coinSession.run(mapOf(coinInputName to tensor))
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

        results.close()
        tensor.close()

        return DetectionResponse(
            model = "indian_coin_yolov8n",
            preprocessTimeMs = prepTimeMs,
            inferenceTimeMs = inferTimeMs,
            decodeTimeMs = decodeTimeMs,
            totalTimeMs = prepTimeMs + inferTimeMs + decodeTimeMs,
            detections = detections
        )
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

        val tensor = OnnxTensor.createTensor(
            env,
            prep.tensorBuffer,
            longArrayOf(1, 3, INPUT_SIZE.toLong(), INPUT_SIZE.toLong())
        )

        val t1 = System.nanoTime()
        val results = banknoteSession.run(mapOf(banknoteInputName to tensor))
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

        results.close()
        tensor.close()

        return DetectionResponse(
            model = "indian_banknote_yolov8n",
            preprocessTimeMs = prepTimeMs,
            inferenceTimeMs = inferTimeMs,
            decodeTimeMs = decodeTimeMs,
            totalTimeMs = prepTimeMs + inferTimeMs + decodeTimeMs,
            detections = detections
        )
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

        val tensor = OnnxTensor.createTensor(
            env,
            prep.tensorBuffer,
            longArrayOf(1, 3, INPUT_SIZE.toLong(), INPUT_SIZE.toLong())
        )

        // 1. Coin Model
        val t1 = System.nanoTime()
        val coinResults = coinSession.run(mapOf(coinInputName to tensor))
        val coinInferTimeMs = (System.nanoTime() - t1) / 1_000_000.0

        @Suppress("UNCHECKED_CAST")
        val rawCoinOutput = coinResults[0].value as Array<Array<FloatArray>>
        val coinDetections = if (isCandidateMode) {
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

        // 2. Banknote Model (reuses exact same preprocessed tensor!)
        val t2 = System.nanoTime()
        val noteResults = banknoteSession.run(mapOf(banknoteInputName to tensor))
        val noteInferTimeMs = (System.nanoTime() - t2) / 1_000_000.0

        @Suppress("UNCHECKED_CAST")
        val rawNoteOutput = noteResults[0].value as Array<Array<FloatArray>>
        val tDecode = System.nanoTime()
        val rawNoteDetections = if (isCandidateMode) {
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
        val decodeTimeMs = (System.nanoTime() - tDecode) / 1_000_000.0
        noteResults.close()
        tensor.close()

        // 3. Cross-Model Mutual Exclusion & Minimum Physical Area Filtering
        val frameArea = prep.origWidth.toFloat() * prep.origHeight.toFloat()
        val filteredBanknotes = rawNoteDetections.filter { note ->
            val noteW = max(0.0f, note.box[2] - note.box[0])
            val noteH = max(0.0f, note.box[3] - note.box[1])
            val noteAreaFrac = if (frameArea > 0f) (noteW * noteH) / frameArea else 0f
            val aspectRatio = if (noteW > 0f && noteH > 0f) max(noteW / noteH, noteH / noteW) else 1f

            // Banknote training boxes have median 59% and min 14% of image area.
            // Reject tiny boxes (< 4.0% of frame), which are spurious activations on coins or background.
            if (noteAreaFrac < 0.04f) return@filter false

            // Reject extreme non-banknote aspect ratios
            if (aspectRatio > 4.5f || aspectRatio < 0.7f) return@filter false

            // Cross-model suppression: If note overlaps with a detected coin and is relatively small (< 15% of frame)
            val overlapsCoin = coinDetections.any { coin ->
                val overlapFraction = calculateIntersectionOverMinArea(note.box, coin.box)
                overlapFraction > 0.20f
            }
            if (overlapsCoin && noteAreaFrac < 0.15f) return@filter false

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

        var cropExtractTimeMs = 0.0
        var noteVerifyTimeMs = 0.0
        var coinVerifyTimeMs = 0.0
        var rejectedForeignCount = 0
        var rejectedNonCurrencyCount = 0
        var unknownIdentityCount = 0
        val rejectedIdentityDetections = mutableListOf<Detection>()

        val verifiedBanknotes = if (noteVerifier != null) {
            val kept = mutableListOf<Detection>()
            for (note in filteredBanknotes) {
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
                    "FOREIGN_CURRENCY" -> {
                        rejectedForeignCount++
                        rejectedIdentityDetections.add(enriched)
                    }
                    "NON_CURRENCY" -> {
                        rejectedNonCurrencyCount++
                        rejectedIdentityDetections.add(enriched)
                    }
                    else -> {
                        unknownIdentityCount++
                        rejectedIdentityDetections.add(enriched)
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
                    "FOREIGN_CURRENCY" -> {
                        rejectedForeignCount++
                        rejectedIdentityDetections.add(enriched)
                    }
                    "NON_CURRENCY" -> {
                        rejectedNonCurrencyCount++
                        rejectedIdentityDetections.add(enriched)
                    }
                    else -> {
                        unknownIdentityCount++
                        rejectedIdentityDetections.add(enriched)
                    }
                }
            }
            kept
        } else {
            coinDetections
        }

        val screenedBanknotes = if (isCandidateMode) {
            screenBanknoteSafety(verifiedBanknotes)
        } else {
            verifiedBanknotes
        }
        val screenedCoins = if (isCandidateMode) {
            screenCoinSafety(verifiedCoins, screenedBanknotes, frameArea)
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
        if (rejectedForeignCount > 0) frameReasons.add("FOREIGN_CURRENCY_DETECTED")
        if (unknownIdentityCount > 0) frameReasons.add("IDENTITY_UNKNOWN")
        if (rejectedNonCurrencyCount > 0) frameReasons.add("NON_CURRENCY_REJECTED")

        val totalStatus = when {
            rejectedForeignCount > 0 || totalConflictingCount > 0 -> "conflicting"
            unknownIdentityCount > 0 -> "tentative"
            screenedBanknotes.isEmpty() && screenedCoins.isEmpty() -> "empty"
            !isCandidateMode -> "confirmed"
            totalTentativeCount > 0 || confirmedNoteCount + screenedCoins.count { it.confirmationState == "confirmed" } != allScreened.size -> "tentative"
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
            isTotalConfirmed = totalStatus == "confirmed" && totalConfirmedCount > 0 && (screenedBanknotes.isNotEmpty() || screenedCoins.isNotEmpty()) && rejectedForeignCount == 0 && unknownIdentityCount == 0,
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
                if (iou > iouThreshold) {
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
                if (weak.top1Class != best.top1Class && calculateIoU(best.box, weak.box) > iouThreshold) {
                    conflictCount++
                    if (weak.top1Score > maxConflictConf) {
                        maxConflictConf = weak.top1Score
                        maxConflictCls = weak.top1Class
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
     * Evaluate pairwise inter-box overlap (IoU > 0.25 or IoMin > 0.70) and assign explicit
     * per-object confirmation states ("confirmed", "tentative", "conflicting").
     */
    private fun screenBanknoteSafety(detections: List<Detection>): List<Detection> {
        if (detections.isEmpty()) return detections
        val result = ArrayList<Detection>(detections.size)

        for (i in detections.indices) {
            val d = detections[i]
            var maxIoU = 0.0f
            var maxIoMin = 0.0f

            for (j in detections.indices) {
                if (i == j) continue
                val iou = calculateIoU(d.box, detections[j].box)
                val iomin = calculateIntersectionOverMinArea(d.box, detections[j].box)
                if (iou > maxIoU) maxIoU = iou
                if (iomin > maxIoMin) maxIoMin = iomin
            }

            val reasons = ArrayList<String>()
            val hasSuppressedConflict = d.suppressedConflictConfidence >= CANDIDATE_CONFLICT_CONF
            val hasOverlapConflict = maxIoU > CANDIDATE_MAX_INTERBOX_IOU || maxIoMin > CANDIDATE_MAX_INTERBOX_IOMIN
            val isLowConf = d.confidence < CANDIDATE_CONFIRM_CONF
            val isLowMargin = d.classMargin < CANDIDATE_MIN_CLASS_MARGIN

            if (hasSuppressedConflict) reasons.add("CROSS_CLASS_CONFLICT")
            if (hasOverlapConflict) reasons.add("OVERLAP_CONFLICT")
            if (isLowConf) reasons.add("LOW_CONFIDENCE")
            if (isLowMargin) reasons.add("NARROW_CLASS_MARGIN")

            val state = when {
                hasSuppressedConflict || hasOverlapConflict -> "conflicting"
                isLowConf || isLowMargin -> "tentative"
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
            if (coin.confidence < CANDIDATE_COIN_CONFIRM_CONF) continue
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
        return noteAreaFrac >= CANDIDATE_SPURIOUS_WRAPPER_CANVAS_AREA_FRAC && edgeTouches >= 3
    }

    /**
     * Phase 4N Candidate-Only Coin Safety Screening:
     * Enforces coin class-margin checks, coin-to-coin overlap conflicts, suppressed class conflicts,
     * geometry/scale sanity checks, and cross-model banknote containment conflict analysis so coin
     * false positives cannot independently inflate confirmed monetary totals.
     */
    private fun screenCoinSafety(
        coins: List<Detection>,
        banknotes: List<Detection>,
        frameArea: Float
    ): List<Detection> {
        if (coins.isEmpty()) return coins
        val result = ArrayList<Detection>(coins.size)

        for (i in coins.indices) {
            val d = coins[i]
            var maxIoU = 0.0f
            var maxIoMin = 0.0f

            for (j in coins.indices) {
                if (i == j) continue
                val iou = calculateIoU(d.box, coins[j].box)
                val iomin = calculateIntersectionOverMinArea(d.box, coins[j].box)
                if (iou > maxIoU) maxIoU = iou
                if (iomin > maxIoMin) maxIoMin = iomin
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
            val hasSuppressedConflict = d.suppressedConflictConfidence >= CANDIDATE_COIN_CONFLICT_CONF
            val hasOverlapConflict = maxIoU > CANDIDATE_COIN_MAX_INTERBOX_IOU || maxIoMin > CANDIDATE_COIN_MAX_INTERBOX_IOMIN
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

            if (hasSuppressedConflict) reasons.add("CROSS_CLASS_CONFLICT")
            if (hasOverlapConflict) reasons.add("OVERLAP_CONFLICT")
            if (hasCrossModelBanknoteConflict) reasons.add("CROSS_MODEL_BANKNOTE_CONFLICT")
            if (isLowConf) reasons.add("LOW_CONFIDENCE")
            if (isLowMargin) reasons.add("NARROW_CLASS_MARGIN")
            if (hasExtremeAspect) reasons.add("COIN_EXTREME_ASPECT_RATIO")
            if (hasSmallArea) reasons.add("SMALL_COIN_AREA")

            val state = when {
                hasSuppressedConflict || hasOverlapConflict || hasCrossModelBanknoteConflict -> "conflicting"
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

        // Scan all 8400 candidate anchor predictions
        for (i in 0 until NUM_ANCHORS) {
            var bestClass = 0
            var maxScore = -1.0f

            for (c in 0 until numClasses) {
                val score = rawOutput[4 + c][i]
                if (score > maxScore) {
                    maxScore = score
                    bestClass = c
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

                finalDetections.add(
                    Detection(
                        classId = cls,
                        className = classNames[cls],
                        confidence = bestScore,
                        box = bestBox
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
        iouThreshold: Float = 0.35f
    ): List<Detection> {
        val candidateBoxes = ArrayList<FloatArray>()
        val candidateScores = ArrayList<Float>()
        val candidateClasses = ArrayList<Int>()

        // Scan all 8400 candidate anchor predictions
        for (i in 0 until NUM_ANCHORS) {
            var bestClass = 0
            var maxScore = -1.0f

            for (c in 0 until numClasses) {
                val score = rawOutput[4 + c][i]
                if (score > maxScore) {
                    maxScore = score
                    bestClass = c
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

            finalDetections.add(
                Detection(
                    classId = bestCls,
                    className = classNames[bestCls],
                    confidence = bestScore,
                    box = bestBox
                )
            )

            for (j in (i + 1) until sortedIndices.size) {
                val otherIdx = sortedIndices[j]
                if (suppressed[otherIdx]) continue

                val otherBox = candidateBoxes[otherIdx]
                val iou = calculateIoU(bestBox, otherBox)
                if (iou > iouThreshold) {
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

