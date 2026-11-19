package com.visionmission.currency

import android.graphics.Bitmap
import java.nio.FloatBuffer

data class PreprocessOutput(
    val tensorBuffer: FloatBuffer,
    val gain: Float,
    val padW: Float,
    val padH: Float,
    val origWidth: Int,
    val origHeight: Int,
    val orientedBitmap: Bitmap,
    val orientationTimeMs: Double = 0.0,
    val scaleAndLetterboxTimeMs: Double = 0.0,
    val tensorPrepTimeMs: Double = 0.0
) {
    /**
     * Safely recycles the orientedBitmap if it was newly allocated during rotation
     * and is distinct from the caller's sourceBitmap.
     */
    fun recycleBitmaps(sourceBitmap: Bitmap? = null) {
        if (orientedBitmap !== sourceBitmap && !orientedBitmap.isRecycled) {
            orientedBitmap.recycle()
        }
    }
}


