package dev.pam.mediaeditor

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import androidx.media3.common.util.UnstableApi
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@UnstableApi
@RunWith(AndroidJUnit4::class)
class TimelineTextOverlayTest {
    private fun render(width: Int, maxLines: Int = 8, rotation: Int = 0, wrapped: Boolean = true): Bitmap {
        val spec = JSONObject().put("kind", TimelineOverlay.KIND_TEXT)
            .put("text", "PAM_QA_VIDEO_EXPORT long words across narrow video")
            .put("fontSize", 38).put("x", .5).put("y", .5)
            .put("rotationDegrees", rotation).put("color", "#FFFFFF")
        if (wrapped) spec.put("maxWidth", .78).put("referenceWidth", 720).put("maxLines", maxLines)
        val overlay = TimelineOverlay.create(JSONArray().put(spec), 0f, 0f) { File(it) }
        return Bitmap.createBitmap(width, width * 2, Bitmap.Config.ARGB_8888).also { bitmap ->
            overlay.onDraw(Canvas(bitmap), 0)
            // Reuse the same layout cache on the next frame.
            overlay.onDraw(Canvas(bitmap), 1_000)
            overlay.close()
        }
    }
    private fun bounds(bitmap: Bitmap): IntArray {
        var left = bitmap.width; var right = -1; var top = bitmap.height; var bottom = -1
        for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
            if (Color.alpha(bitmap.getPixel(x, y)) > 20) {
                left = minOf(left, x); right = maxOf(right, x); top = minOf(top, y); bottom = maxOf(bottom, y)
            }
        }
        return intArrayOf(left, top, right, bottom)
    }
    @Test fun extremeReferenceAndFontHaveBoundedGlyphsAndLayout() {
        val spec = JSONObject().put("kind", TimelineOverlay.KIND_TEXT).put("text", "W".repeat(500))
            .put("fontSize", 512).put("scale", 4).put("referenceWidth", 1)
            .put("maxWidth", 1).put("maxLines", 32)
        val overlay = TimelineOverlay.create(JSONArray().put(spec), 0f, 0f) { File(it) }
        val bitmap = Bitmap.createBitmap(270, 480, Bitmap.Config.ARGB_8888)
        overlay.onDraw(Canvas(bitmap), 0)
        val layers = overlay.javaClass.getDeclaredField("layers").apply { isAccessible = true }.get(overlay) as List<*>
        val layer = layers.single()!!
        val layout = layer.javaClass.getDeclaredField("textLayout").apply { isAccessible = true }.get(layer) as android.text.StaticLayout
        assertTrue(layout.paint.textSize <= 270f)
        assertTrue(layout.height <= 480)
        assertTrue(layout.lineCount in 1..32)
        overlay.close(); bitmap.recycle()
    }
    @Test fun narrowVideoWrapsWithinCanvasAndRemainsCentered() {
        val bitmap = render(270); val b = bounds(bitmap)
        assertTrue(b[0] > 20 && b[2] < 250)
        assertTrue(b[3] - b[1] > 20)
        assertTrue(kotlin.math.abs((b[0] + b[2]) / 2 - 135) < 8)
        bitmap.recycle()
    }
    @Test fun boundedLinesTruncateAndRotationStillDraws() {
        val one = render(270, 1); val multiple = render(270); val rotated = render(270, rotation = 30)
        val a = bounds(one); val b = bounds(multiple); val c = bounds(rotated)
        assertTrue(a[3] - a[1] < b[3] - b[1])
        assertTrue(c[0] > 0 && c[2] < 269 && c[3] > c[1])
        one.recycle(); multiple.recycle(); rotated.recycle()
    }
    @Test fun referenceSizingScalesWithOutputWidthAndLegacyRemainsSingleLine() {
        val small = render(270); val large = render(540); val legacy = render(270, wrapped = false)
        val a = bounds(small); val b = bounds(large); val c = bounds(legacy)
        assertTrue(b[3] - b[1] > (a[3] - a[1]) * 1.5)
        assertTrue(c[0] == 0 || c[2] == 269)
        small.recycle(); large.recycle(); legacy.recycle()
    }
}
