<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

/**
 * Probe of a whole timeline (its range is ignored): total and per-clip
 * timeline durations, the largest source frame, whether any kept clip has
 * audio, and the source rotation of a single-clip timeline (0 otherwise).
 */
final readonly class MediaTimelineInfo
{
    /** @param list<int> $clipDurationsMillis */
    public function __construct(
        public int $durationMillis,
        public array $clipDurationsMillis,
        public int $width,
        public int $height,
        public bool $hasAudio,
        public int $rotationDegrees,
    ) {}
}
