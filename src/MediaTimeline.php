<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

use InvalidArgumentException;
use JsonException;

final readonly class MediaTimeline
{
    /** @var list<MediaClip> */
    public array $clips;

    /** @param array<array-key, mixed> $clips */
    public function __construct(
        array $clips,
        public ?string $soundtrack = null,
        public float $soundtrackVolume = 1.0,
        public bool $loopSoundtrack = false,
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
        if ($soundtrack !== null) {
            MediaClip::assertPath($soundtrack);
        }
        if (!is_finite($soundtrackVolume) || $soundtrackVolume < 0 || $soundtrackVolume > 1) {
            throw new InvalidArgumentException('Soundtrack volume must be between 0 and 1.');
        }
        $this->clips = $normalized;
    }

    /** @throws JsonException */
    public function toJson(): string
    {
        return json_encode([
            'clips' => array_map(static fn (MediaClip $clip): array => $clip->toArray(), $this->clips),
            'soundtrack' => $this->soundtrack,
            'soundtrackVolume' => $this->soundtrackVolume,
            'loopSoundtrack' => $this->loopSoundtrack,
        ], JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES);
    }
}
