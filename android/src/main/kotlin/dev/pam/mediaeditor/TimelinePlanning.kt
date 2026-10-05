package dev.pam.mediaeditor

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** Pure (Android-free) timeline, color and overlay math, unit tested on the JVM. */
internal class EditorFailure(val code: Long, message: String, cause: Throwable? = null) : Exception(message, cause) {
    companion object {
        const val UNKNOWN = 1L
        const val UNREADABLE_SOURCE = 2L
        const val INVALID_DURATION = 3L
        const val EMPTY_RANGE = 4L
        const val EXPORT_FAILED = 5L
        const val TIMED_OUT = 6L
        const val CANCELLED = 7L
        const val OUTPUT_MISSING = 8L

        fun codeOf(error: Throwable): Long = (error as? EditorFailure)?.code ?: UNKNOWN
    }
}

/** A clip as it sits on the timeline: its output duration and where it starts in its source. */
internal data class PlannedClip(
    val timelineDurationMs: Long,
    val sourceStartMs: Long = 0L,
    val speed: Float = 1f,
    val image: Boolean = false,
)

/** The part of clip [index] that falls inside the exported range, in source milliseconds. */
internal data class ClipSegment(
    val index: Int,
    val sourceStartMs: Long,
    val sourceEndMs: Long,
    val image: Boolean,
) {
    val durationMs: Long get() = sourceEndMs - sourceStartMs
}

internal object TimelinePlanning {
    /** Slivers shorter than this at the range edges are dropped instead of exported. */
    const val MIN_SEGMENT_MS = 60L

    fun totalMs(clips: List<PlannedClip>): Long = clips.sumOf { it.timelineDurationMs.coerceAtLeast(0L) }

    /** Resolves the requested range against the timeline; null end (or <= 0) means the timeline end. */
    fun range(totalMs: Long, startMs: Long, endMs: Long?): Pair<Long, Long> {
        val start = startMs.coerceAtLeast(0L)
        val end = (endMs?.takeIf { it > 0L } ?: totalMs).coerceAtMost(totalMs)
        return start to end
    }

    fun segments(clips: List<PlannedClip>, startMs: Long, endMs: Long?): List<ClipSegment> {
        val (rangeStart, rangeEnd) = range(totalMs(clips), startMs, endMs)
        if (rangeEnd <= rangeStart) return emptyList()
        var cursorMs = 0L
        return clips.mapIndexedNotNull { index, clip ->
            val clipStart = cursorMs
            val clipEnd = clipStart + clip.timelineDurationMs.coerceAtLeast(0L)
            cursorMs = clipEnd
            val overlapStart = max(rangeStart, clipStart)
            val overlapEnd = min(rangeEnd, clipEnd)
            if (overlapEnd - overlapStart < MIN_SEGMENT_MS) return@mapIndexedNotNull null
            val localStart = overlapStart - clipStart
            val localEnd = overlapEnd - clipStart
            if (clip.image) {
                ClipSegment(index, 0L, localEnd - localStart, true)
            } else {
                ClipSegment(
                    index,
                    clip.sourceStartMs + (localStart * clip.speed).toLong(),
                    clip.sourceStartMs + (localEnd * clip.speed).toLong(),
                    false,
                )
            }
        }
    }
}

/** Effective Media3 parameters for a [brightness, contrast, saturation, temperature, fade] grade. */
internal data class ColorGrade(
    val brightness: Float,
    val contrast: Float,
    val saturationPercent: Float,
    val redScale: Float,
    val blueScale: Float,
) {
    val hasBrightness: Boolean get() = abs(brightness) > EPSILON
    val hasContrast: Boolean get() = abs(contrast) > EPSILON
    val hasSaturation: Boolean get() = saturationPercent != 0f
    val hasTemperature: Boolean get() = redScale != 1f || blueScale != 1f

    companion object {
        private const val EPSILON = 0.001f

        fun from(brightness: Float, contrast: Float, saturation: Float, temperature: Float, fade: Float): ColorGrade {
            val fadeAmount = fade.coerceIn(0f, 1f)
            val warmth = if (abs(temperature) > EPSILON) temperature.coerceIn(-1f, 1f) * 0.14f else 0f
            return ColorGrade(
                brightness = (brightness - fadeAmount * 0.16f).coerceIn(-1f, 1f),
                contrast = (contrast - fadeAmount * 0.18f).coerceIn(-0.95f, 0.95f),
                saturationPercent = if (abs(saturation) > EPSILON) (saturation * 100f).coerceIn(-100f, 100f) else 0f,
                redScale = (1f + warmth).coerceAtLeast(0f),
                blueScale = (1f - warmth).coerceAtLeast(0f),
            )
        }
    }
}

internal object OverlayMath {
    fun visible(timeMs: Long, startMs: Long, endMs: Long): Boolean = timeMs in startMs..endMs

    /** Parses #RRGGBB / #AARRGGBB into ARGB, or [fallback]. */
    fun parseColor(value: String?, fallback: Int): Int {
        val hex = value?.removePrefix("#") ?: return fallback
        if (!value.startsWith("#") || (hex.length != 6 && hex.length != 8) || hex.any { Character.digit(it, 16) < 0 }) return fallback
        val parsed = hex.toLong(16)
        return if (hex.length == 6) (0xFF000000L or parsed).toInt() else parsed.toInt()
    }

    fun mediaWidth(canvasWidth: Int, scale: Float, width: Float, maxWidth: Float, minWidthPixels: Float): Float =
        min(canvasWidth * maxWidth, max(minWidthPixels, canvasWidth * width * scale))

    fun grainPoints(canvasWidth: Int, canvasHeight: Int, strength: Float): Int =
        (canvasWidth * canvasHeight / 3600f * strength).toInt().coerceIn(24, 520)

    fun isGif(bytes: ByteArray): Boolean =
        bytes.size >= 6 && bytes[0] == 'G'.code.toByte() && bytes[1] == 'I'.code.toByte() && bytes[2] == 'F'.code.toByte() && bytes[3] == '8'.code.toByte()

    /** Power-of-two decode subsampling keeping the longest side at or below [maxDimension]. */
    fun sampleSize(width: Int, height: Int, maxDimension: Int): Int {
        var sample = 1
        while (max(width, height) / sample > maxDimension) sample *= 2
        return sample
    }
}
