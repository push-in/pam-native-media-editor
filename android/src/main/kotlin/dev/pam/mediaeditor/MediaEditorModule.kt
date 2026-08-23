package dev.pam.mediaeditor

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.DefaultGainProvider
import androidx.media3.common.audio.GainProcessor
import androidx.media3.common.audio.SpeedProvider
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Crop
import androidx.media3.effect.Presentation
import androidx.media3.effect.RgbAdjustment
import androidx.media3.effect.RgbFilter
import androidx.media3.effect.ScaleAndRotateTransformation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import dev.pam.nativeapp.modules.ModuleCompletion
import dev.pam.nativeapp.modules.ModuleResultStatus
import dev.pam.nativeapp.modules.NativeModule
import dev.pam.nativeapp.protocol.WireMap
import dev.pam.nativeapp.protocol.WireValue
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import org.json.JSONArray
import org.json.JSONObject

@UnstableApi
class MediaEditorModule(context: Context) : NativeModule {
    private val root = context.applicationContext.filesDir.canonicalFile
    private val appContext = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val jobs = ConcurrentHashMap<Long, ExportJob>()

    override fun invoke(method: String, payload: ByteArray, completion: ModuleCompletion) {
        runCatching { WireMap.decode(payload) }
            .onFailure { completion.failure(it) }
            .onSuccess { values ->
                when (method) {
                    "export" -> main.post { startExport(values, completion) }
                    "status" -> main.post { status(values.integer("jobId"), completion) }
                    "cancel" -> main.post { cancel(values.integer("jobId"), completion) }
                    else -> completion.failure(IllegalArgumentException("Unknown media editor method: $method"))
                }
            }
    }

    private fun startExport(values: Map<String, WireValue>, completion: ModuleCompletion) {
        runCatching {
            val jobId = values.integer("jobId")
            require(jobs.putIfAbsent(jobId, ExportJob()) == null) { "Export job already exists" }
            val destination = file(values.text("destination"), false).also {
                it.parentFile?.mkdirs()
                if (it.exists()) require(it.delete()) { "Cannot replace export destination" }
            }
            val timeline = JSONObject(values.text("timeline"))
            val job = jobs.getValue(jobId)
            job.path = values.text("destination")
            val transformer = Transformer.Builder(appContext)
                .setEncoderFactory(
                    DefaultEncoderFactory.Builder(appContext)
                        .setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate(values.integer("videoBitRate").toInt()).build())
                        .build(),
                )
                .setVideoMimeType(if (values.integer("videoCodec") == 2L) MimeTypes.VIDEO_H265 else MimeTypes.VIDEO_H264)
                .setAudioMimeType(MimeTypes.AUDIO_AAC)
                .addListener(object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                        job.state = COMPLETED
                        job.progress = 100
                        completion.success(result(jobId, job, values.text("destination")))
                    }

                    override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                        job.state = FAILED
                        job.message = exportException.message.orEmpty()
                        completion.failure(exportException)
                    }
                })
                .build()
            job.transformer = transformer
            job.state = EXPORTING
            transformer.start(composition(timeline, values), destination.path)
        }.onFailure { error ->
            values.longOrNull("jobId")?.let { jobs[it]?.apply { state = FAILED; message = error.message.orEmpty() } }
            completion.failure(error)
        }
    }

    private fun composition(timeline: JSONObject, values: Map<String, WireValue>): Composition {
        val clips = timeline.getJSONArray("clips")
        require(clips.length() in 1..128) { "Timeline requires between 1 and 128 clips" }
        val videoItems = ArrayList<EditedMediaItem>(clips.length())
        for (index in 0 until clips.length()) videoItems += editedClip(clips.getJSONObject(index), values.integer("frameRate").toInt())
        val sequences = mutableListOf(EditedMediaItemSequence.withAudioAndVideoFrom(videoItems))
        timeline.optString("soundtrack").takeIf { it.isNotEmpty() && it != "null" }?.let { soundtrack ->
            val gain = timeline.optDouble("soundtrackVolume", 1.0).toFloat().coerceIn(0f, 1f)
            val audio = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(file(soundtrack, true))))
                .setRemoveVideo(true)
                .setEffects(Effects(listOf(GainProcessor(DefaultGainProvider.Builder(gain).build())), emptyList()))
                .build()
            sequences += EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO))
                .addItem(audio)
                .setIsLooping(timeline.optBoolean("loopSoundtrack", false))
                .build()
        }
        val outputEffects = Effects(
            emptyList(),
            listOf(Presentation.createForWidthAndHeight(values.integer("width").toInt(), values.integer("height").toInt(), Presentation.LAYOUT_SCALE_TO_FIT)),
        )
        return Composition.Builder(sequences)
            .setEffects(outputEffects)
            .setHdrMode(if (values.flag("preserveHdr")) Composition.HDR_MODE_KEEP_HDR else Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL)
            .build()
    }

    private fun editedClip(clip: JSONObject, frameRate: Int): EditedMediaItem {
        val clipping = MediaItem.ClippingConfiguration.Builder()
            .setStartPositionMs(clip.getLong("startMillis"))
        if (!clip.isNull("endMillis")) clipping.setEndPositionMs(clip.getLong("endMillis"))
        val mediaItem = MediaItem.Builder()
            .setUri(Uri.fromFile(file(clip.getString("source"), true)))
            .setClippingConfiguration(clipping.build())
            .build()
        val audio = listOf(GainProcessor(DefaultGainProvider.Builder(clip.optDouble("volume", 1.0).toFloat().coerceIn(0f, 1f)).build()))
        val video = videoEffects(clip)
        val builder = EditedMediaItem.Builder(mediaItem).setEffects(Effects(audio, video)).setFrameRate(frameRate)
        val speed = clip.optDouble("speed", 1.0).toFloat().coerceIn(0.25f, 4f)
        if (speed != 1f) builder.setSpeed(object : SpeedProvider {
            override fun getSpeed(timeUs: Long): Float = speed
            override fun getNextSpeedChangeTimeUs(timeUs: Long): Long = C.TIME_UNSET
        })
        return builder.build()
    }

    private fun videoEffects(clip: JSONObject): List<Effect> {
        val effects = mutableListOf<Effect>()
        clip.optJSONObject("crop")?.let { crop ->
            val left = crop.getDouble("x").toFloat() * 2f - 1f
            val right = (crop.getDouble("x") + crop.getDouble("width")).toFloat() * 2f - 1f
            val top = 1f - crop.getDouble("y").toFloat() * 2f
            val bottom = 1f - (crop.getDouble("y") + crop.getDouble("height")).toFloat() * 2f
            effects += Crop(left, right, bottom, top)
        }
        val rotation = clip.optInt("rotationDegrees", 0)
        if (rotation != 0) effects += ScaleAndRotateTransformation.Builder().setRotationDegrees(rotation.toFloat()).build()
        when (clip.optInt("filter", 1)) {
            2 -> effects += RgbFilter.createGrayscaleFilter()
            3 -> effects += MatrixFilter.SEPIA
            4 -> effects += RgbAdjustment.Builder().setRedScale(1.08f).setGreenScale(1.04f).setBlueScale(1.1f).build()
        }
        return effects
    }

    private fun status(jobId: Long, completion: ModuleCompletion) {
        val job = jobs[jobId] ?: return completion.failure(IllegalArgumentException("Unknown export job"))
        job.transformer?.let { transformer ->
            if (job.state == EXPORTING) {
                val holder = ProgressHolder()
                if (transformer.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) job.progress = holder.progress
            }
        }
        completion.success(result(jobId, job, job.path))
    }

    private fun cancel(jobId: Long, completion: ModuleCompletion) {
        val job = jobs[jobId] ?: return completion.failure(IllegalArgumentException("Unknown export job"))
        job.transformer?.cancel()
        job.state = CANCELLED
        completion.success(result(jobId, job, job.path))
    }

    private fun result(jobId: Long, job: ExportJob, path: String) = mapOf(
        "jobId" to WireValue.Integer(jobId),
        "state" to WireValue.Integer(job.state),
        "progress" to WireValue.Integer(job.progress.toLong()),
        "path" to WireValue.Text(path),
        "message" to WireValue.Text(job.message),
    )

    private fun file(path: String, mustExist: Boolean): File {
        require(path.isNotEmpty() && path.length <= 1024 && !path.contains('\u0000')) { "Invalid media path" }
        val target = File(root, path).canonicalFile
        require(target.path.startsWith(root.path + File.separator)) { "Media path escapes app files" }
        if (mustExist) require(target.isFile) { "Media source does not exist" }
        return target
    }

    private fun Map<String, WireValue>.text(key: String) = (get(key) as? WireValue.Text)?.value ?: error("$key is required")
    private fun Map<String, WireValue>.integer(key: String) = (get(key) as? WireValue.Integer)?.value ?: error("$key is required")
    private fun Map<String, WireValue>.flag(key: String) = (get(key) as? WireValue.Flag)?.value ?: false
    private fun Map<String, WireValue>.longOrNull(key: String) = (get(key) as? WireValue.Integer)?.value
    private fun ModuleCompletion.success(values: Map<String, WireValue>) = complete(ModuleResultStatus.SUCCESS, WireMap.encode(values))
    private fun ModuleCompletion.failure(error: Throwable) = complete(ModuleResultStatus.FAILURE, (error.message ?: "Media export failed").toByteArray())

    private class ExportJob {
        var transformer: Transformer? = null
        var state: Long = QUEUED
        var progress: Int = 0
        var path: String = ""
        var message: String = ""
    }

    private object MatrixFilter {
        val SEPIA = androidx.media3.effect.RgbMatrix { _, _ -> floatArrayOf(
            0.393f, 0.349f, 0.272f, 0f,
            0.769f, 0.686f, 0.534f, 0f,
            0.189f, 0.168f, 0.131f, 0f,
            0f, 0f, 0f, 1f,
        ) }
    }

    private companion object {
        const val QUEUED = 1L
        const val EXPORTING = 2L
        const val COMPLETED = 3L
        const val CANCELLED = 4L
        const val FAILED = 5L
    }
}
