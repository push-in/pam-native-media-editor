package dev.pam.mediaeditor

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TimelinePlanningTest {
    private val photo = PlannedClip(5_000L, image = true)
    private val video = PlannedClip(8_000L)

    @Test
    fun fullRangeKeepsEveryClip() {
        val segments = TimelinePlanning.segments(listOf(photo, video), 0L, null)
        assertEquals(listOf(ClipSegment(0, 0L, 5_000L, true), ClipSegment(1, 0L, 8_000L, false)), segments)
    }

    @Test
    fun rangeTrimsEdgeClipsInSourceTime() {
        val segments = TimelinePlanning.segments(listOf(photo, video), 2_000L, 9_000L)
        assertEquals(listOf(ClipSegment(0, 0L, 3_000L, true), ClipSegment(1, 0L, 4_000L, false)), segments)
    }

    @Test
    fun clipsOutsideTheRangeAndSliversAreDropped() {
        assertEquals(listOf(ClipSegment(1, 1_000L, 3_000L, false)), TimelinePlanning.segments(listOf(photo, video), 6_000L, 8_000L))
        assertEquals(listOf(ClipSegment(1, 0L, 2_000L, false)), TimelinePlanning.segments(listOf(photo, video), 4_970L, 7_000L))
    }

    @Test
    fun rangeEndIsClampedAndNonPositiveMeansTimelineEnd() {
        assertEquals(0L to 13_000L, TimelinePlanning.range(13_000L, 0L, 99_000L))
        assertEquals(500L to 13_000L, TimelinePlanning.range(13_000L, 500L, 0L))
        assertTrue(TimelinePlanning.segments(listOf(video), 9_000L, null).isEmpty())
    }

    @Test
    fun sourceOffsetAndSpeedMapTimelineToSource() {
        val fast = PlannedClip(timelineDurationMs = 4_000L, sourceStartMs = 1_000L, speed = 2f)
        assertEquals(listOf(ClipSegment(0, 3_000L, 7_000L, false)), TimelinePlanning.segments(listOf(fast), 1_000L, 3_000L))
    }

    @Test
    fun colorGradeAppliesFadeAndClamps() {
        val neutral = ColorGrade.from(0f, 0f, 0f, 0f, 0f)
        assertFalse(neutral.hasBrightness || neutral.hasContrast || neutral.hasSaturation || neutral.hasTemperature)
        val faded = ColorGrade.from(0f, 0f, 0f, 0f, 0.5f)
        assertEquals(-0.08f, faded.brightness, 1e-6f)
        assertEquals(-0.09f, faded.contrast, 1e-6f)
        assertEquals(0.95f, ColorGrade.from(0f, 1f, 0f, 0f, 0f).contrast, 1e-6f)
        val graded = ColorGrade.from(0.2f, 0f, -1f, 0.5f, 0f)
        assertEquals(-100f, graded.saturationPercent, 1e-6f)
        assertEquals(1.07f, graded.redScale, 1e-6f)
        assertEquals(0.93f, graded.blueScale, 1e-6f)
        assertTrue(graded.hasTemperature && graded.hasSaturation && graded.hasBrightness)
    }

    @Test
    fun overlayMathMatchesTheRenderer() {
        assertTrue(OverlayMath.visible(1_000L, 1_000L, 2_000L))
        assertTrue(OverlayMath.visible(2_000L, 1_000L, 2_000L))
        assertFalse(OverlayMath.visible(2_001L, 1_000L, 2_000L))
        assertEquals(0xFF101713.toInt(), OverlayMath.parseColor("#101713", 0))
        assertEquals(0x80FFFFFF.toInt(), OverlayMath.parseColor("#80FFFFFF", 0))
        assertEquals(7, OverlayMath.parseColor("red", 7))
        assertEquals(7, OverlayMath.parseColor("#12345G", 7))
        assertEquals(367.2f, OverlayMath.mediaWidth(1080, 1f, 0.34f, 0.72f, 96f), 1e-3f)
        assertEquals(777.6f, OverlayMath.mediaWidth(1080, 4f, 0.34f, 0.72f, 96f), 1e-3f)
        assertEquals(96f, OverlayMath.mediaWidth(200, 0.25f, 0.34f, 0.72f, 96f), 1e-3f)
        assertEquals(24, OverlayMath.grainPoints(100, 100, 0.1f))
        assertEquals(520, OverlayMath.grainPoints(1080, 1920, 1f))
        assertTrue(OverlayMath.isGif("GIF89a".toByteArray()))
        assertFalse(OverlayMath.isGif(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0, 0, 0, 0)))
        assertEquals(1, OverlayMath.sampleSize(2048, 1024, 2048))
        assertEquals(2, OverlayMath.sampleSize(4000, 3000, 2048))
        assertEquals(4, OverlayMath.sampleSize(8192, 6000, 2048))
    }

    @Test
    fun failureCodesFollowThePhpEnum() {
        assertEquals(1L, EditorFailure.codeOf(IllegalStateException()))
        assertEquals(6L, EditorFailure.codeOf(EditorFailure(EditorFailure.TIMED_OUT, "timeout")))
        assertEquals(
            (1L..8L).toList(),
            listOf(
                EditorFailure.UNKNOWN, EditorFailure.UNREADABLE_SOURCE, EditorFailure.INVALID_DURATION, EditorFailure.EMPTY_RANGE,
                EditorFailure.EXPORT_FAILED, EditorFailure.TIMED_OUT, EditorFailure.CANCELLED, EditorFailure.OUTPUT_MISSING,
            ),
        )
    }
}
