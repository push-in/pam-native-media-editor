package dev.pam.mediaeditor

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Movie
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.CanvasOverlay
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.max
import kotlin.random.Random
import org.json.JSONArray
import org.json.JSONObject

/**
 * Draws timed text/image overlays, film grain and a vignette over every output
 * frame. `presentationTimeUs` is on the exported output timeline.
 */
@UnstableApi
@Suppress("DEPRECATION")
internal class TimelineOverlay private constructor(
    private val layers: List<Layer>,
    private val grain: Float,
    private val vignette: Float,
) : CanvasOverlay(true), AutoCloseable {
    private class Layer(
        val kind: Int,
        val x: Float,
        val y: Float,
        val scale: Float,
        val rotationDegrees: Float,
        val startMs: Long,
        val endMs: Long,
        val text: String = "",
        val color: Int = Color.WHITE,
        val fontSize: Float = 48f,
        val backgroundColor: Int? = null,
        val bold: Boolean = true,
        val bitmap: Bitmap? = null,
        val movie: Movie? = null,
        val width: Float = 0.34f,
        val maxWidth: Float = 0.72f,
        val minWidthPixels: Float = 96f,
    )

    val hasContent: Boolean get() = layers.isNotEmpty() || grain > 0.001f || vignette > 0.001f

    override fun onDraw(canvas: Canvas, presentationTimeUs: Long) {
        canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
        val timeMs = presentationTimeUs / 1_000L
        layers.forEach { layer ->
            if (!OverlayMath.visible(timeMs, layer.startMs, layer.endMs)) return@forEach
            canvas.save()
            val centerX = layer.x * canvas.width
            val centerY = layer.y * canvas.height
            canvas.rotate(layer.rotationDegrees, centerX, centerY)
            if (layer.kind == KIND_IMAGE) drawImage(canvas, layer, timeMs, centerX, centerY) else drawText(canvas, layer, centerX, centerY)
            canvas.restore()
        }
        drawGrain(canvas, timeMs)
        drawVignette(canvas)
    }

    private fun drawText(canvas: Canvas, layer: Layer, centerX: Float, centerY: Float) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = layer.color
            textAlign = Paint.Align.CENTER
            textSize = layer.fontSize * layer.scale
            typeface = if (layer.bold) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
        }
        val baseline = centerY - (paint.ascent() + paint.descent()) / 2f
        layer.backgroundColor?.let { background ->
            val width = paint.measureText(layer.text)
            val padding = 20f * layer.scale
            canvas.drawRoundRect(
                RectF(centerX - width / 2f - padding, baseline + paint.ascent() - padding / 2f, centerX + width / 2f + padding, baseline + paint.descent() + padding / 2f),
                14f,
                14f,
                Paint(Paint.ANTI_ALIAS_FLAG).apply { color = background },
            )
        }
        canvas.drawText(layer.text, centerX, baseline, paint)
    }

    private fun drawImage(canvas: Canvas, layer: Layer, timeMs: Long, centerX: Float, centerY: Float) {
        val sourceWidth = layer.bitmap?.width ?: layer.movie?.width() ?: return
        val sourceHeight = layer.bitmap?.height ?: layer.movie?.height() ?: return
        if (sourceWidth <= 0 || sourceHeight <= 0) return
        val width = OverlayMath.mediaWidth(canvas.width, layer.scale, layer.width, layer.maxWidth, layer.minWidthPixels)
        val height = width * sourceHeight / sourceWidth
        val rect = RectF(centerX - width / 2f, centerY - height / 2f, centerX + width / 2f, centerY + height / 2f)
        layer.bitmap?.let { canvas.drawBitmap(it, null, rect, Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)) }
        layer.movie?.let { movie ->
            movie.setTime((timeMs % max(1, movie.duration())).toInt())
            canvas.save()
            canvas.translate(rect.left, rect.top)
            canvas.scale(rect.width() / sourceWidth, rect.height() / sourceHeight)
            movie.draw(canvas, 0f, 0f)
            canvas.restore()
        }
    }

    private fun drawGrain(canvas: Canvas, timeMs: Long) {
        val strength = grain.coerceIn(0f, 1f)
        if (strength <= 0.001f) return
        val random = Random(timeMs / 42L)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            alpha = (strength * 46f).toInt().coerceIn(0, 46)
            strokeWidth = 1.2f
        }
        repeat(OverlayMath.grainPoints(canvas.width, canvas.height, strength)) {
            canvas.drawPoint(random.nextFloat() * canvas.width, random.nextFloat() * canvas.height, paint)
        }
    }

    private fun drawVignette(canvas: Canvas) {
        val strength = vignette.coerceIn(0f, 1f)
        if (strength <= 0.001f) return
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = RadialGradient(
                canvas.width / 2f,
                canvas.height / 2f,
                max(canvas.width, canvas.height) * 0.72f,
                intArrayOf(Color.TRANSPARENT, Color.TRANSPARENT, Color.argb((strength * 210f).toInt(), 0, 0, 0)),
                floatArrayOf(0f, 0.52f, 1f),
                Shader.TileMode.CLAMP,
            )
        }
        canvas.drawRect(0f, 0f, canvas.width.toFloat(), canvas.height.toFloat(), paint)
    }

    override fun close() {
        layers.forEach { layer -> layer.bitmap?.takeUnless(Bitmap::isRecycled)?.recycle() }
    }

    companion object {
        const val KIND_TEXT = 1
        const val KIND_IMAGE = 2
        private const val MAX_IMAGE_BYTES = 32 * 1024 * 1024
        private const val MAX_IMAGE_DIMENSION = 2048

        /** Parses the overlay JSON and loads images (blocking: call off the main thread). */
        fun create(overlays: JSONArray?, grain: Float, vignette: Float, resolve: (String) -> File): TimelineOverlay {
            val layers = mutableListOf<Layer>()
            for (index in 0 until (overlays?.length() ?: 0)) {
                val item = overlays?.optJSONObject(index) ?: continue
                parse(item, resolve)?.let(layers::add)
            }
            return TimelineOverlay(layers, grain, vignette)
        }

        private fun parse(item: JSONObject, resolve: (String) -> File): Layer? {
            val kind = item.optInt("kind", KIND_TEXT)
            val x = item.optDouble("x", 0.5).toFloat().coerceIn(0f, 1f)
            val y = item.optDouble("y", 0.5).toFloat().coerceIn(0f, 1f)
            val scale = item.optDouble("scale", 1.0).toFloat().coerceIn(0.25f, 4f)
            val rotation = item.optDouble("rotationDegrees", 0.0).toFloat()
            val start = item.optLong("startMillis", 0L)
            val end = if (item.isNull("endMillis")) Long.MAX_VALUE else item.optLong("endMillis", Long.MAX_VALUE)
            if (kind == KIND_IMAGE) {
                val bytes = runCatching { readBytes(item.optString("source"), resolve) }.getOrNull() ?: return null
                val movie = if (OverlayMath.isGif(bytes)) Movie.decodeByteArray(bytes, 0, bytes.size)?.takeIf { it.width() > 0 && it.height() > 0 } else null
                val bitmap = if (movie == null) decodeBitmap(bytes) ?: return null else null
                return Layer(
                    kind = KIND_IMAGE, x = x, y = y, scale = scale, rotationDegrees = rotation, startMs = start, endMs = end,
                    bitmap = bitmap, movie = movie,
                    width = item.optDouble("width", 0.34).toFloat().coerceIn(0.01f, 1f),
                    maxWidth = item.optDouble("maxWidth", 0.72).toFloat().coerceIn(0.01f, 1f),
                    minWidthPixels = item.optInt("minWidthPixels", 96).coerceIn(0, 8192).toFloat(),
                )
            }
            val text = item.optString("text", "").take(500)
            if (text.isEmpty()) return null
            return Layer(
                kind = KIND_TEXT, x = x, y = y, scale = scale, rotationDegrees = rotation, startMs = start, endMs = end,
                text = text,
                color = OverlayMath.parseColor(item.optString("color", "#FFFFFF"), Color.WHITE),
                fontSize = item.optDouble("fontSize", 48.0).toFloat().coerceIn(4f, 512f),
                backgroundColor = if (item.isNull("backgroundColor")) null else OverlayMath.parseColor(item.optString("backgroundColor"), Color.WHITE),
                bold = item.optBoolean("bold", true),
            )
        }

        private fun decodeBitmap(bytes: ByteArray): Bitmap? {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            val options = BitmapFactory.Options().apply { inSampleSize = OverlayMath.sampleSize(bounds.outWidth, bounds.outHeight, MAX_IMAGE_DIMENSION) }
            return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        }

        private fun readBytes(source: String, resolve: (String) -> File): ByteArray? {
            if (!source.startsWith("https://")) {
                val file = resolve(source)
                return if (file.length() in 1..MAX_IMAGE_BYTES.toLong()) file.readBytes() else null
            }
            val connection = URL(source).openConnection() as HttpURLConnection
            return try {
                connection.connectTimeout = 12_000
                connection.readTimeout = 18_000
                if (connection.responseCode !in 200..299) return null
                connection.inputStream.use { input ->
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(16 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        output.write(buffer, 0, read)
                        if (output.size() > MAX_IMAGE_BYTES) return null
                    }
                    output.toByteArray()
                }
            } finally {
                connection.disconnect()
            }
        }
    }
}
