package dev.pam.mediaeditor

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.DefaultGainProvider
import androidx.media3.common.audio.GainProcessor
import androidx.media3.common.audio.SpeedProvider
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Brightness
import androidx.media3.effect.Contrast
import androidx.media3.effect.Crop
import androidx.media3.effect.HslAdjustment
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.Presentation
import androidx.media3.effect.RgbAdjustment
import androidx.media3.effect.RgbFilter
import androidx.media3.effect.RgbMatrix
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
import java.util.concurrent.Executors
import org.json.JSONArray
import org.json.JSONObject

@UnstableApi
class MediaEditorModule(context: Context) : NativeModule, AutoCloseable {
    private val appContext = context.applicationContext
    private val root = File(appContext.filesDir, "pam-files").apply { mkdirs() }.canonicalFile
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newFixedThreadPool(2) { runnable -> Thread(runnable, "pam-media-editor") }
    private val jobs = ConcurrentHashMap<Long, ExportJob>()

    override fun invoke(method: String, payload: ByteArray, completion: ModuleCompletion) {
        val values = runCatching { WireMap.decode(payload) }.getOrElse {
            completion.failure(it)
            return
        }
        runCatching {
            when (method) {
                "export" -> {
                    val jobId = values.integer("jobId")
                    val job = ExportJob(jobId, values.text("destination"), completion)
                    require(jobs.putIfAbsent(jobId, job) == null) { "Export job already exists" }
                    executor.execute { prepareExport(job, values) }
                }
                "observe" -> (jobs[values.integer("jobId")] ?: error("Unknown export job")).observe(completion)
                "status" -> {
                    val job = jobs[values.integer("jobId")] ?: error("Unknown export job")
                    main.post {
                        job.sampleProgress()
                        completion.success(job.snapshot())
                    }
                }
                "cancel" -> {
                    val job = jobs[values.integer("jobId")] ?: error("Unknown export job")
                    main.post {
                        job.finishFailure(EditorFailure(EditorFailure.CANCELLED, "Export cancelled"), CANCELLED)
                        completion.success(job.snapshot())
                    }
                }
                "probe" -> executor.execute {
                    runCatching { probe(JSONObject(values.text("timeline"))) }
                        .onSuccess { completion.success(it) }
                        .onFailure { completion.success(failurePayload(it)) }
                }
                else -> error("Unknown media editor method: $method")
            }
        }.onFailure { completion.failure(it) }
    }

    private class ResolvedClip(
        val json: JSONObject,
        val file: File,
        val image: Boolean,
        val media: ProbedMedia,
        val planned: PlannedClip,
    )

    private fun resolveClips(timeline: JSONObject, strict: Boolean): List<ResolvedClip> {
        val clips = timeline.getJSONArray("clips")
        if (clips.length() !in 1..128) throw EditorFailure(EditorFailure.EMPTY_RANGE, "Timeline requires between 1 and 128 clips")
        return (0 until clips.length()).map { index ->
            val clip = clips.getJSONObject(index)
            val file = file(clip.getString("source"), true)
            if (!clip.isNull("imageDurationMillis")) {
                val media = MediaProbe.image(file)
                val duration = clip.getLong("imageDurationMillis").coerceAtLeast(1L)
                ResolvedClip(clip, file, true, media, PlannedClip(duration, image = true))
            } else {
                val media = MediaProbe.video(file)
                val start = clip.optLong("startMillis", 0L).coerceAtLeast(0L)
                val end = (if (clip.isNull("endMillis")) media.durationMs else clip.getLong("endMillis")).coerceAtMost(media.durationMs)
                val speed = clip.optDouble("speed", 1.0).toFloat().coerceIn(0.25f, 4f)
                val duration = ((end - start).coerceAtLeast(0L) / speed).toLong()
                if (strict && duration <= 0L) throw EditorFailure(EditorFailure.INVALID_DURATION, "Clip $index has no valid duration")
                ResolvedClip(clip, file, false, media, PlannedClip(duration, start, speed, false))
            }
        }
    }

    private fun probe(timeline: JSONObject): Map<String, WireValue> {
        val clips = resolveClips(timeline, strict = false)
        return mapOf(
            "durationMillis" to WireValue.Integer(TimelinePlanning.totalMs(clips.map { it.planned })),
            "clipDurations" to WireValue.Text(JSONArray(clips.map { it.planned.timelineDurationMs }).toString()),
            "width" to WireValue.Integer(clips.maxOf { it.media.width }),
            "height" to WireValue.Integer(clips.maxOf { it.media.height }),
            "hasAudio" to WireValue.Flag(clips.any { !it.image && it.media.hasAudio && !it.json.optBoolean("removeAudio", false) }),
            "rotationDegrees" to WireValue.Integer(if (clips.size == 1) clips[0].media.rotation else 0L),
        )
    }

    private fun prepareExport(job: ExportJob, values: Map<String, WireValue>) {
        runCatching {
            val timeline = JSONObject(values.text("timeline"))
            val clips = resolveClips(timeline, strict = true)
            if (TimelinePlanning.totalMs(clips.map { it.planned }) <= 0L) throw EditorFailure(EditorFailure.INVALID_DURATION, "Timeline has no valid duration")
            val rangeEnd = if (timeline.isNull("rangeEndMillis")) null else timeline.optLong("rangeEndMillis")
            val segments = TimelinePlanning.segments(clips.map { it.planned }, timeline.optLong("rangeStartMillis", 0L), rangeEnd)
            if (segments.isEmpty()) throw EditorFailure(EditorFailure.EMPTY_RANGE, "The timeline range contains no exportable clips")
            val soundtrack = timeline.optString("soundtrack").takeIf { !timeline.isNull("soundtrack") && it.isNotEmpty() }?.let { file(it, true) }
            val destination = file(job.path, false).also {
                it.parentFile?.mkdirs()
                if (it.exists() && !it.delete()) throw EditorFailure(EditorFailure.OUTPUT_MISSING, "Cannot replace export destination")
            }
            val adjustments = timeline.optJSONObject("adjustments") ?: JSONObject()
            val overlay = TimelineOverlay.create(
                timeline.optJSONArray("overlays"),
                adjustments.optDouble("grain", 0.0).toFloat(),
                adjustments.optDouble("vignette", 0.0).toFloat(),
            ) { path -> file(path, true) }
            val shared = gradeEffects(adjustments).toMutableList<Effect>().apply {
                if (overlay.hasContent) add(OverlayEffect(listOf(overlay)))
            }
            job.overlay = overlay
            job.output = destination
            main.post { startExport(job, values, timeline, clips, segments, soundtrack, shared, destination) }
        }.onFailure { job.finishFailure(it) }
    }

    // The list/vararg sequence builders and forced audio track are the device-validated pipeline
    // for mixed image + video timelines (silent gaps between image clips keep an audio track).
    @Suppress("DEPRECATION")
    private fun startExport(
        job: ExportJob,
        values: Map<String, WireValue>,
        timeline: JSONObject,
        clips: List<ResolvedClip>,
        segments: List<ClipSegment>,
        soundtrack: File?,
        shared: List<Effect>,
        destination: File,
    ) {
        if (job.isTerminal()) {
            job.overlay?.close()
            return
        }
        runCatching {
            val frameRate = values.integer("frameRate").toInt()
            val items = segments.map { segment -> editedItem(clips[segment.index], segment, shared, frameRate) }
            val primary = EditedMediaItemSequence.Builder(items)
            if (segments.any { !it.image && !clips[it.index].json.optBoolean("removeAudio", false) }) {
                primary.experimentalSetForceAudioTrack(true)
            }
            val composition = if (soundtrack != null) {
                val gain = timeline.optDouble("soundtrackVolume", 1.0).toFloat().coerceIn(0f, 1f)
                val audio = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(soundtrack)))
                    .setRemoveVideo(true)
                    .setEffects(Effects(listOf(GainProcessor(DefaultGainProvider.Builder(gain).build())), emptyList()))
                    .build()
                val audioSequence = EditedMediaItemSequence.Builder(audio)
                    .setIsLooping(timeline.optBoolean("loopSoundtrack", false))
                    .build()
                Composition.Builder(primary.build(), audioSequence)
            } else {
                Composition.Builder(primary.build())
            }
            val width = values.integer("width").toInt()
            val height = values.integer("height").toInt()
            if (width > 0 && height > 0) {
                composition.setEffects(Effects(emptyList(), listOf(Presentation.createForWidthAndHeight(width, height, Presentation.LAYOUT_SCALE_TO_FIT))))
            }
            composition.setHdrMode(if (values.flag("preserveHdr")) Composition.HDR_MODE_KEEP_HDR else Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL)
            val builder = Transformer.Builder(appContext)
                .setVideoMimeType(if (values.integer("videoCodec") == 2L) MimeTypes.VIDEO_H265 else MimeTypes.VIDEO_H264)
                .setAudioMimeType(MimeTypes.AUDIO_AAC)
                .addListener(object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                        runCatching { executor.execute { completeExport(job, destination) } }
                            .onFailure { job.finishFailure(EditorFailure(EditorFailure.CANCELLED, "Media editor closed"), CANCELLED) }
                    }

                    override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                        job.finishFailure(EditorFailure(EditorFailure.EXPORT_FAILED, exportException.message ?: "Media export failed", exportException))
                    }
                })
            val bitRate = values.integer("videoBitRate").toInt()
            if (bitRate > 0) {
                builder.setEncoderFactory(
                    DefaultEncoderFactory.Builder(appContext)
                        .setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate(bitRate).build())
                        .build(),
                )
            }
            val transformer = builder.build()
            job.start(transformer)
            transformer.start(composition.build(), destination.path)
            val timeout = values.integer("timeoutMillis")
            if (timeout > 0L) {
                main.postDelayed({ job.finishFailure(EditorFailure(EditorFailure.TIMED_OUT, "Export timed out")) }, timeout)
            }
            main.postDelayed(object : Runnable {
                override fun run() {
                    if (!job.isExporting()) return
                    job.sampleProgress()
                    main.postDelayed(this, PROGRESS_INTERVAL_MS)
                }
            }, PROGRESS_INTERVAL_MS)
        }.onFailure { job.finishFailure(it) }
    }

    private fun editedItem(clip: ResolvedClip, segment: ClipSegment, shared: List<Effect>, frameRate: Int): EditedMediaItem {
        val media = MediaItem.Builder().setUri(Uri.fromFile(clip.file))
        if (segment.image) {
            media.setImageDurationMs(segment.durationMs)
        } else {
            media.setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionMs(segment.sourceStartMs)
                    .setEndPositionMs(segment.sourceEndMs)
                    .build(),
            )
        }
        val removeAudio = segment.image || clip.json.optBoolean("removeAudio", false)
        val audio = mutableListOf<AudioProcessor>()
        val volume = clip.json.optDouble("volume", 1.0).toFloat().coerceIn(0f, 1f)
        if (!removeAudio && volume != 1f) audio += GainProcessor(DefaultGainProvider.Builder(volume).build())
        val builder = EditedMediaItem.Builder(media.build())
            .setRemoveAudio(removeAudio)
            .setEffects(Effects(audio, clipEffects(clip.json) + shared))
        if (segment.image) builder.setFrameRate(frameRate)
        val speed = clip.planned.speed
        if (!segment.image && speed != 1f) {
            builder.setSpeed(object : SpeedProvider {
                override fun getSpeed(timeUs: Long): Float = speed
                override fun getNextSpeedChangeTimeUs(timeUs: Long): Long = C.TIME_UNSET
            })
        }
        return builder.build()
    }

    private fun clipEffects(clip: JSONObject): List<Effect> {
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
            3 -> effects += SEPIA
            4 -> effects += RgbAdjustment.Builder().setRedScale(1.08f).setGreenScale(1.04f).setBlueScale(1.1f).build()
        }
        return effects
    }

    private fun gradeEffects(adjustments: JSONObject): List<Effect> {
        val grade = ColorGrade.from(
            adjustments.optDouble("brightness", 0.0).toFloat(),
            adjustments.optDouble("contrast", 0.0).toFloat(),
            adjustments.optDouble("saturation", 0.0).toFloat(),
            adjustments.optDouble("temperature", 0.0).toFloat(),
            adjustments.optDouble("fade", 0.0).toFloat(),
        )
        val effects = mutableListOf<Effect>()
        if (grade.hasBrightness) effects += Brightness(grade.brightness)
        if (grade.hasContrast) effects += Contrast(grade.contrast)
        if (grade.hasSaturation) effects += HslAdjustment.Builder().adjustSaturation(grade.saturationPercent).build()
        if (grade.hasTemperature) {
            effects += RgbAdjustment.Builder().setRedScale(grade.redScale).setGreenScale(1f).setBlueScale(grade.blueScale).build()
        }
        return effects
    }

    private fun completeExport(job: ExportJob, destination: File) {
        runCatching {
            if (!destination.isFile || destination.length() <= 0L) throw EditorFailure(EditorFailure.OUTPUT_MISSING, "The exported file was not written")
            val output = MediaProbe.video(destination)
            job.finishSuccess(
                mapOf(
                    "bytes" to WireValue.Integer(destination.length()),
                    "durationMillis" to WireValue.Integer(output.durationMs),
                    "width" to WireValue.Integer(output.width),
                    "height" to WireValue.Integer(output.height),
                    "hasAudio" to WireValue.Flag(output.hasAudio),
                    "rotationDegrees" to WireValue.Integer(output.rotation),
                ),
            )
        }.onFailure { job.finishFailure(it) }
    }

    private fun file(path: String, mustExist: Boolean): File {
        if (path.isEmpty() || path.length > 1024 || path.startsWith("/") || '\u0000' in path) {
            throw EditorFailure(EditorFailure.UNREADABLE_SOURCE, "Media paths must be relative sandbox paths")
        }
        val target = File(root, path).canonicalFile
        if (!target.path.startsWith(root.path + File.separator)) throw EditorFailure(EditorFailure.UNREADABLE_SOURCE, "Media path escapes app files")
        if (mustExist && !target.isFile) throw EditorFailure(EditorFailure.UNREADABLE_SOURCE, "Media source does not exist")
        return target
    }

    private fun failurePayload(error: Throwable) = mapOf(
        "failure" to WireValue.Integer(EditorFailure.codeOf(error)),
        "message" to WireValue.Text(error.message ?: "Media editor failure"),
    )

    override fun close() {
        jobs.values.forEach { job -> main.post { job.finishFailure(EditorFailure(EditorFailure.CANCELLED, "Media editor closed"), CANCELLED) } }
        executor.shutdown()
    }

    /** One export: owns its Transformer, pushes progress to a single `observe` long-poll and completes `export` once. */
    private inner class ExportJob(val id: Long, val path: String, private var exportCompletion: ModuleCompletion?) {
        @Volatile var overlay: TimelineOverlay? = null
        @Volatile var output: File? = null
        private var transformer: Transformer? = null
        private var state = QUEUED
        private var progress = 0
        private var message = ""
        private var failure = 0L
        private var terminal: Map<String, WireValue>? = null
        private var waiter: ModuleCompletion? = null
        private var observed = true

        @Synchronized fun isTerminal() = terminal != null

        @Synchronized fun isExporting() = state == EXPORTING && terminal == null

        @Synchronized fun start(transformer: Transformer) {
            this.transformer = transformer
            state = EXPORTING
        }

        /** Main thread only. */
        fun sampleProgress() {
            val current = synchronized(this) { transformer.takeIf { state == EXPORTING } } ?: return
            val holder = ProgressHolder()
            if (current.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) progress(holder.progress)
        }

        fun progress(percent: Int) {
            val deliver = synchronized(this) {
                val value = percent.coerceIn(0, 99)
                if (terminal != null || value == progress) return
                progress = value
                observed = false
                waiter?.also { waiter = null; observed = true }?.let { it to snapshot() }
            }
            deliver?.let { (completion, payload) -> completion.success(payload) }
        }

        fun observe(completion: ModuleCompletion) {
            val payload = synchronized(this) {
                when {
                    terminal != null -> terminal
                    !observed -> snapshot().also { observed = true }
                    waiter != null -> return completion.failure(IllegalStateException("Export observation already pending"))
                    else -> null.also { waiter = completion }
                }
            }
            payload?.let { completion.success(it) }
        }

        fun finishSuccess(extra: Map<String, WireValue>) = finish(COMPLETED, 100, "", 0L, extra)

        fun finishFailure(error: Throwable, terminalState: Long = FAILED) {
            val code = if (terminalState == CANCELLED) EditorFailure.CANCELLED else EditorFailure.codeOf(error)
            finish(terminalState, null, error.message ?: "Media export failed", code, emptyMap())
        }

        private fun finish(newState: Long, newProgress: Int?, newMessage: String, code: Long, extra: Map<String, WireValue>) {
            val (payload, completions, running) = synchronized(this) {
                if (terminal != null) return
                state = newState
                newProgress?.let { progress = it }
                message = newMessage
                failure = code
                val payload = snapshot() + extra
                terminal = payload
                val completions = listOfNotNull(exportCompletion, waiter)
                exportCompletion = null
                waiter = null
                Triple(payload, completions, transformer.also { transformer = null })
            }
            val drawn = overlay
            overlay = null
            val cleanup = {
                if (newState != COMPLETED) output?.delete()
                drawn?.close()
            }
            // The overlay bitmaps are recycled only once the Transformer stopped drawing them.
            if (running != null && newState != COMPLETED) {
                main.post {
                    running.cancel()
                    cleanup()
                }
            } else {
                cleanup()
            }
            completions.forEach { it.success(payload) }
        }

        @Synchronized fun snapshot(): Map<String, WireValue> = buildMap {
            put("jobId", WireValue.Integer(id))
            put("state", WireValue.Integer(state))
            put("progress", WireValue.Integer(progress.toLong()))
            put("path", WireValue.Text(path))
            put("message", WireValue.Text(message))
            if (failure != 0L) put("failure", WireValue.Integer(failure))
        }
    }

    private companion object {
        const val PROGRESS_INTERVAL_MS = 250L
        val SEPIA = RgbMatrix { _, _ ->
            floatArrayOf(
                0.393f, 0.349f, 0.272f, 0f,
                0.769f, 0.686f, 0.534f, 0f,
                0.189f, 0.168f, 0.131f, 0f,
                0f, 0f, 0f, 1f,
            )
        }
    }
}

private const val QUEUED = 1L
private const val EXPORTING = 2L
private const val COMPLETED = 3L
private const val CANCELLED = 4L
private const val FAILED = 5L

private fun Map<String, WireValue>.text(key: String) = (get(key) as? WireValue.Text)?.value ?: error("$key is required")

private fun Map<String, WireValue>.integer(key: String) = (get(key) as? WireValue.Integer)?.value ?: error("$key is required")

private fun Map<String, WireValue>.flag(key: String) = (get(key) as? WireValue.Flag)?.value ?: false

private fun ModuleCompletion.success(values: Map<String, WireValue>) = complete(ModuleResultStatus.SUCCESS, WireMap.encode(values))

private fun ModuleCompletion.failure(error: Throwable) = complete(ModuleResultStatus.FAILURE, (error.message ?: "Media editor failure").toByteArray())
