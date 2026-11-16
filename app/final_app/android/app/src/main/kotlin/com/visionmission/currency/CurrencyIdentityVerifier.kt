package com.visionmission.currency

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.graphics.Bitmap
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min

data class IdentityVerifyResult(
    val state: String, // CONFIRMED_INDIAN, FOREIGN_CURRENCY, NON_CURRENCY, UNKNOWN
    val pForeign: Float,
    val pIndian: Float,
    val pNonCurrency: Float,
    val margin: Float,
    val cropExtractTimeMs: Double,
    val verifyTimeMs: Double
)

class CurrencyIdentityVerifier(
    private val env: OrtEnvironment,
    private val sessionOptions: OrtSession.SessionOptions,
    modelPath: String,
    private val pIndianThreshold: Float,
    private val marginThreshold: Float
) : AutoCloseable {

    companion object {
        const val INPUT_SIZE = 224
        const val MIN_CROP_PX = 16
        const val CROP_CONTEXT_PAD = 0.12f
        val MEAN = floatArrayOf(0.485f, 0.456f, 0.406f)
        val STD = floatArrayOf(0.229f, 0.224f, 0.225f)
        val CLASSES = arrayOf("FOREIGN_CURRENCY", "INDIAN_CURRENCY", "NON_CURRENCY")
    }

    val loadTimeMs: Double
    private val session: OrtSession
    private val inputName: String

    init {
        require(File(modelPath).exists()) { "Identity verifier model not found at: $modelPath" }
        val t0 = System.nanoTime()
        session = env.createSession(modelPath, sessionOptions)
        loadTimeMs = (System.nanoTime() - t0) / 1_000_000.0
        inputName = session.inputNames.iterator().next()
    }

    private fun unknownResult(cropExtractMs: Double, verifyMs: Double = 0.0) = IdentityVerifyResult(
        state = "UNKNOWN",
        pForeign = 0.0f,
        pIndian = 0.0f,
        pNonCurrency = 0.0f,
        margin = 0.0f,
        cropExtractTimeMs = cropExtractMs,
        verifyTimeMs = verifyMs
    )

    fun verifyCrop(orientedBitmap: Bitmap, box: FloatArray): IdentityVerifyResult {
        val tCrop0 = System.nanoTime()
        if (orientedBitmap.isRecycled) {
            return unknownResult((System.nanoTime() - tCrop0) / 1_000_000.0)
        }
        val imgW = orientedBitmap.width
        val imgH = orientedBitmap.height
        if (imgW < MIN_CROP_PX || imgH < MIN_CROP_PX || box.size < 4) {
            return unknownResult((System.nanoTime() - tCrop0) / 1_000_000.0)
        }

        val bx1 = box[0]
        val by1 = box[1]
        val bx2 = box[2]
        val by2 = box[3]
        if (!bx1.isFinite() || !by1.isFinite() || !bx2.isFinite() || !by2.isFinite()) {
            return unknownResult((System.nanoTime() - tCrop0) / 1_000_000.0)
        }
        if (bx2 <= bx1 || by2 <= by1) {
            return unknownResult((System.nanoTime() - tCrop0) / 1_000_000.0)
        }

        val cx1 = max(0.0f, min(imgW.toFloat(), bx1))
        val cy1 = max(0.0f, min(imgH.toFloat(), by1))
        val cx2 = max(0.0f, min(imgW.toFloat(), bx2))
        val cy2 = max(0.0f, min(imgH.toFloat(), by2))
        val bw = cx2 - cx1
        val bh = cy2 - cy1
        if (bw < MIN_CROP_PX.toFloat() || bh < MIN_CROP_PX.toFloat()) {
            return unknownResult((System.nanoTime() - tCrop0) / 1_000_000.0)
        }

        val padX = bw * CROP_CONTEXT_PAD
        val padY = bh * CROP_CONTEXT_PAD

        val x1 = max(0, (cx1 - padX).toInt())
        val y1 = max(0, (cy1 - padY).toInt())
        val x2 = min(imgW, (cx2 + padX).toInt())
        val y2 = min(imgH, (cy2 + padY).toInt())
        val cw = x2 - x1
        val ch = y2 - y1
        if (cw < MIN_CROP_PX || ch < MIN_CROP_PX) {
            return unknownResult((System.nanoTime() - tCrop0) / 1_000_000.0)
        }

        val cropped = Bitmap.createBitmap(orientedBitmap, x1, y1, cw, ch)
        val resized = Bitmap.createScaledBitmap(cropped, INPUT_SIZE, INPUT_SIZE, true)
        if (cropped !== orientedBitmap && !cropped.isRecycled) cropped.recycle()

        val pixels = IntArray(INPUT_SIZE * INPUT_SIZE)
        resized.getPixels(pixels, 0, INPUT_SIZE, 0, 0, INPUT_SIZE, INPUT_SIZE)
        if (resized !== orientedBitmap && !resized.isRecycled) resized.recycle()

        val rawBuf = ByteBuffer.allocateDirect(1 * 3 * INPUT_SIZE * INPUT_SIZE * 4)
            .order(ByteOrder.nativeOrder())
        val floatBuf: FloatBuffer = rawBuf.asFloatBuffer()
        val planeSize = INPUT_SIZE * INPUT_SIZE
        val rArr = FloatArray(planeSize)
        val gArr = FloatArray(planeSize)
        val bArr = FloatArray(planeSize)

        for (i in 0 until planeSize) {
            val px = pixels[i]
            val r = ((px shr 16) and 0xFF) / 255.0f
            val g = ((px shr 8) and 0xFF) / 255.0f
            val b = (px and 0xFF) / 255.0f
            rArr[i] = (r - MEAN[0]) / STD[0]
            gArr[i] = (g - MEAN[1]) / STD[1]
            bArr[i] = (b - MEAN[2]) / STD[2]
        }
        floatBuf.put(rArr)
        floatBuf.put(gArr)
        floatBuf.put(bArr)
        floatBuf.rewind()
        val cropExtractMs = (System.nanoTime() - tCrop0) / 1_000_000.0

        val tInf0 = System.nanoTime()
        var logits: FloatArray? = null
        var tensor: OnnxTensor? = null
        var results: OrtSession.Result? = null
        try {
            tensor = OnnxTensor.createTensor(
                env,
                floatBuf,
                longArrayOf(1, 3, INPUT_SIZE.toLong(), INPUT_SIZE.toLong())
            )
            results = session.run(mapOf(inputName to tensor))
            @Suppress("UNCHECKED_CAST")
            val outArr = results[0].value as? Array<FloatArray>
            if (outArr != null && outArr.isNotEmpty()) {
                logits = outArr[0]
            }
        } catch (_: Throwable) {
            return unknownResult(cropExtractMs, (System.nanoTime() - tInf0) / 1_000_000.0)
        } finally {
            results?.close()
            tensor?.close()
        }
        val verifyMs = (System.nanoTime() - tInf0) / 1_000_000.0
        if (logits == null || logits.size != 3 || logits.any { !it.isFinite() }) {
            return unknownResult(cropExtractMs, verifyMs)
        }

        val probs = softmax(logits)
        if (probs.size != 3 || probs.any { !it.isFinite() }) {
            return unknownResult(cropExtractMs, verifyMs)
        }
        val sorted = probs.sortedDescending()
        val margin = sorted[0] - sorted[1]
        var top1Idx = 0
        for (i in 1 until probs.size) {
            if (probs[i] > probs[top1Idx]) top1Idx = i
        }

        val state = when {
            top1Idx == 1 -> {
                if (probs[1] >= pIndianThreshold && margin >= marginThreshold) {
                    "CONFIRMED_INDIAN"
                } else {
                    "UNKNOWN"
                }
            }
            probs[top1Idx] >= 0.50f && margin >= 0.05f -> CLASSES[top1Idx]
            else -> "UNKNOWN"
        }

        return IdentityVerifyResult(
            state = state,
            pForeign = probs[0],
            pIndian = probs[1],
            pNonCurrency = probs[2],
            margin = margin,
            cropExtractTimeMs = cropExtractMs,
            verifyTimeMs = verifyMs
        )
    }

    private fun softmax(logits: FloatArray): FloatArray {
        var maxVal = logits[0]
        for (i in 1 until logits.size) {
            if (logits[i] > maxVal) maxVal = logits[i]
        }
        val exps = FloatArray(logits.size)
        var sum = 0.0f
        for (i in logits.indices) {
            val e = exp((logits[i] - maxVal).toDouble()).toFloat()
            exps[i] = e
            sum += e
        }
        for (i in exps.indices) {
            exps[i] /= max(sum, 1e-12f)
        }
        return exps
    }

    override fun close() {
        session.close()
    }
}
