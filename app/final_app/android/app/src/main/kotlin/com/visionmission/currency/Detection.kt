package com.visionmission.currency

data class Detection(
    val classId: Int,
    val className: String,
    val confidence: Float,
    val box: FloatArray, // [x1, y1, x2, y2] in original image coordinates
    val top2ClassId: Int = -1,
    val top2ClassName: String = "",
    val top2Confidence: Float = 0.0f,
    val classMargin: Float = 1.0f,
    val suppressedConflictCount: Int = 0,
    val suppressedConflictClassId: Int = -1,
    val suppressedConflictClassName: String = "",
    val suppressedConflictConfidence: Float = 0.0f,
    val interBoxMaxIoU: Float = 0.0f,
    val interBoxMaxIoMin: Float = 0.0f,
    val confirmationState: String = "confirmed",
    val uncertaintyReasons: List<String> = emptyList(),
    val identityState: String = "CONFIRMED_INDIAN",
    val identityPForeign: Float = 0.0f,
    val identityPIndian: Float = 1.0f,
    val identityPNonCurrency: Float = 0.0f,
    val identityMargin: Float = 1.0f
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as Detection

        if (classId != other.classId) return false
        if (className != other.className) return false
        if (confidence != other.confidence) return false
        if (!box.contentEquals(other.box)) return false
        if (top2ClassId != other.top2ClassId) return false
        if (top2Confidence != other.top2Confidence) return false
        if (classMargin != other.classMargin) return false
        if (suppressedConflictCount != other.suppressedConflictCount) return false
        if (suppressedConflictConfidence != other.suppressedConflictConfidence) return false
        if (interBoxMaxIoU != other.interBoxMaxIoU) return false
        if (interBoxMaxIoMin != other.interBoxMaxIoMin) return false
        if (confirmationState != other.confirmationState) return false
        if (uncertaintyReasons != other.uncertaintyReasons) return false

        return true
    }

    override fun hashCode(): Int {
        var result = classId
        result = 31 * result + className.hashCode()
        result = 31 * result + confidence.hashCode()
        result = 31 * result + box.contentHashCode()
        result = 31 * result + top2ClassId
        result = 31 * result + classMargin.hashCode()
        result = 31 * result + suppressedConflictCount
        result = 31 * result + suppressedConflictConfidence.hashCode()
        result = 31 * result + confirmationState.hashCode()
        return result
    }

    override fun toString(): String {
        return "Detection(classId=$classId, className='$className', conf=$confidence, margin=$classMargin, state='$confirmationState', box=[${box.joinToString { String.format("%.1f", it) }}])"
    }
}

