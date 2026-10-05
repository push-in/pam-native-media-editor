<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

use InvalidArgumentException;

final readonly class MediaClip
{
    public function __construct(
        public string $source,
        public int $startMillis = 0,
        public ?int $endMillis = null,
        public float $volume = 1.0,
        public float $speed = 1.0,
        public int $rotationDegrees = 0,
        public ?MediaCrop $crop = null,
        public MediaFilter $filter = MediaFilter::None,
        public bool $removeAudio = false,
        public ?int $imageDurationMillis = null,
    ) {
        self::assertPath($source);
        if ($startMillis < 0 || ($endMillis !== null && $endMillis <= $startMillis)) {
            throw new InvalidArgumentException('Clip bounds must form a positive range.');
        }
        if (!is_finite($volume) || $volume < 0 || $volume > 1 || !is_finite($speed) || $speed < 0.25 || $speed > 4) {
            throw new InvalidArgumentException('Clip volume or speed is outside the supported range.');
        }
        if (!in_array($rotationDegrees, [0, 90, 180, 270], true)) {
            throw new InvalidArgumentException('Clip rotation must be 0, 90, 180, or 270 degrees.');
        }
        if ($imageDurationMillis !== null && ($imageDurationMillis < 1 || $imageDurationMillis > 3_600_000 || $startMillis !== 0 || $endMillis !== null)) {
            throw new InvalidArgumentException('Image clips need a duration between 1 ms and 1 hour and no source bounds.');
        }
    }

    /**
     * A still image shown for a fixed duration inside the timeline. Images carry no audio.
     */
    public static function image(
        string $source,
        int $durationMillis,
        int $rotationDegrees = 0,
        ?MediaCrop $crop = null,
        MediaFilter $filter = MediaFilter::None,
    ): self {
        return new self(
            source: $source,
            rotationDegrees: $rotationDegrees,
            crop: $crop,
            filter: $filter,
            removeAudio: true,
            imageDurationMillis: $durationMillis,
        );
    }

    public function isImage(): bool
    {
        return $this->imageDurationMillis !== null;
    }

    /** @return array<string, string|int|float|bool|array{x: float, y: float, width: float, height: float}|null> */
    public function toArray(): array
    {
        return [
            'source' => $this->source,
            'startMillis' => $this->startMillis,
            'endMillis' => $this->endMillis,
            'volume' => $this->volume,
            'speed' => $this->speed,
            'rotationDegrees' => $this->rotationDegrees,
            'crop' => $this->crop?->toArray(),
            'filter' => $this->filter->value,
            'removeAudio' => $this->removeAudio,
            'imageDurationMillis' => $this->imageDurationMillis,
        ];
    }

    public static function assertPath(string $path): void
    {
        $segments = preg_split('~[/\\\\]+~', $path);
        if ($path === '' || strlen($path) > 1024 || str_contains($path, "\0") || str_starts_with($path, '/') || str_contains($path, '://') || $segments === false || in_array('..', $segments, true)) {
            throw new InvalidArgumentException('Media paths must be relative sandbox paths.');
        }
    }
}
