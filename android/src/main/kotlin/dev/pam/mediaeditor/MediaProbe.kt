package dev.pam.mediaeditor

import android.graphics.BitmapFactory
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import java.io.File

internal data class ProbedMedia(
    val durationMs: Long,
    val width: Long,
    val height: Long,
    val rotation: Long,
    val hasAudio: Boolean,
)

/** Video and image metadata, with container and sample-scan fallbacks for missing durations. */
internal object MediaProbe {
    fun video(source: File): ProbedMedia {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(source.path)
            fun long(key: Int) = retriever.extractMetadata(key)?.toLongOrNull()
            val metadataDuration = long(MediaMetadataRetriever.METADATA_KEY_DURATION)?.coerceAtLeast(0L) ?: 0L
            ProbedMedia(
                durationMs = metadataDuration.takeIf { it > 0L } ?: trackDurationMs(source),
                width = long(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.coerceAtLeast(0L) ?: 0L,
                height = long(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.coerceAtLeast(0L) ?: 0L,
                rotation = long(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION) ?: 0L,
                hasAudio = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes",
            )
        } catch (error: RuntimeException) {
            throw EditorFailure(EditorFailure.UNREADABLE_SOURCE, "Cannot read media ${source.name}", error)
        } finally {
            retriever.release()
        }
    }

    fun image(source: File): ProbedMedia {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(source.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw EditorFailure(EditorFailure.UNREADABLE_SOURCE, "Cannot read image ${source.name}")
        }
        return ProbedMedia(0L, bounds.outWidth.toLong(), bounds.outHeight.toLong(), 0L, false)
    }

    private fun trackDurationMs(source: File): Long {
        val extractor = MediaExtractor()
        val declared = try {
            extractor.setDataSource(source.path)
            (0 until extractor.trackCount)
                .asSequence()
                .map { extractor.getTrackFormat(it) }
                .filter { it.containsKey(MediaFormat.KEY_DURATION) }
                .map { it.getLong(MediaFormat.KEY_DURATION) }
                .maxOrNull()
                ?.coerceAtLeast(0L)
                ?.div(1_000L)
                ?: 0L
        } finally {
            extractor.release()
        }
        return declared.takeIf { it > 0L } ?: scanSampleDurationMs(source)
    }

    private fun scanSampleDurationMs(source: File): Long {
        val counter = MediaExtractor()
        val trackCount = try {
            counter.setDataSource(source.path)
            counter.trackCount
        } finally {
            counter.release()
        }
        return (0 until trackCount).maxOfOrNull { trackIndex ->
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(source.path)
                extractor.selectTrack(trackIndex)
                var previousTimeUs = -1L
                var lastTimeUs = -1L
                while (extractor.sampleTime >= 0L) {
                    previousTimeUs = lastTimeUs
                    lastTimeUs = extractor.sampleTime
                    if (!extractor.advance()) break
                }
                val lastSampleDurationUs = if (previousTimeUs >= 0L) (lastTimeUs - previousTimeUs).coerceAtLeast(0L) else 0L
                (lastTimeUs + lastSampleDurationUs).coerceAtLeast(0L) / 1_000L
            } finally {
                extractor.release()
            }
        } ?: 0L
    }
}
