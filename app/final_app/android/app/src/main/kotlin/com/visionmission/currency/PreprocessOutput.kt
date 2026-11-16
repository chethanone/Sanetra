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
    val orientedBitmap: Bitmap
)

