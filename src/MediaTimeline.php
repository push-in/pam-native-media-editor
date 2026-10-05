<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

use InvalidArgumentException;
use JsonException;

/**
 * Clips played back to back, with an optional soundtrack, a whole-timeline
 * color grade, timed overlays and an exported range.
 *
 * The range (`rangeStartMillis`..`rangeEndMillis`, null end = timeline end) is
 * expressed on the concatenated clip timeline; clips outside it are dropped and
 * the clips at its edges are trimmed. Overlay times are on the exported output
 * timeline, which starts at 0 at `rangeStartMillis`.
 */
final readonly class MediaTimeline
{
    /** @var list<MediaClip> */
    public array $clips;

    /** @var list<MediaOverlay> */
    public array $overlays;

    /**
     * @param array<array-key, mixed> $clips
     * @param array<array-key, mixed> $overlays
     */
    public function __construct(
        array $clips,
        public ?string $soundtrack = null,
        public float $soundtrackVolume = 1.0,
        public bool $loopSoundtrack = false,
        public ?MediaAdjustments $adjustments = null,
        array $overlays = [],
        public int $rangeStartMillis = 0,
        public ?int $rangeEndMillis = null,
    ) {
        if ($clips === [] || count($clips) > 128) {
            throw new InvalidArgumentException('A timeline requires between 1 and 128 clips.');
        }
        $normalized = [];
        foreach ($clips as $clip) {
            if (!$clip instanceof MediaClip) {
                throw new InvalidArgumentException('Timeline clips must be MediaClip instances.');
            }
            $normalized[] = $clip;
        }
        if (count($overlays) > 128) {
            throw new InvalidArgumentException('A timeline accepts at most 128 overlays.');
        }
        $layers = [];
        foreach ($overlays as $overlay) {
            if (!$overlay instanceof MediaOverlay) {
                throw new InvalidArgumentException('Timeline overlays must be MediaOverlay instances.');
            }
            $layers[] = $overlay;
        }
        if ($soundtrack !== null) {
            MediaClip::assertPath($soundtrack);
        }
        if (!is_finite($soundtrackVolume) || $soundtrackVolume < 0 || $soundtrackVolume > 1) {
            throw new InvalidArgumentException('Soundtrack volume must be between 0 and 1.');
        }
        if ($rangeStartMillis < 0 || ($rangeEndMillis !== null && $rangeEndMillis <= $rangeStartMillis)) {
            throw new InvalidArgumentException('Timeline range must be a positive span.');
        }
        $this->clips = $normalized;
        $this->overlays = $layers;
    }

    /** @throws JsonException */
    public function toJson(): string
    {
        return json_encode([
            'clips' => array_map(static fn (MediaClip $clip): array => $clip->toArray(), $this->clips),
            'soundtrack' => $this->soundtrack,
            'soundtrackVolume' => $this->soundtrackVolume,
            'loopSoundtrack' => $this->loopSoundtrack,
            'adjustments' => $this->adjustments?->toArray(),
            'overlays' => array_map(static fn (MediaOverlay $overlay): array => $overlay->toArray(), $this->overlays),
            'rangeStartMillis' => $this->rangeStartMillis,
            'rangeEndMillis' => $this->rangeEndMillis,
        ], JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRESERVE_ZERO_FRACTION);
    }
}
