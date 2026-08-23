<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

use InvalidArgumentException;

final readonly class MediaCrop
{
    public function __construct(
        public float $x,
        public float $y,
        public float $width,
        public float $height,
    ) {
        foreach ([$x, $y, $width, $height] as $value) {
            if (!is_finite($value)) {
                throw new InvalidArgumentException('Crop values must be finite.');
            }
        }
        if ($x < 0 || $y < 0 || $width <= 0 || $height <= 0 || $x + $width > 1 || $y + $height > 1) {
            throw new InvalidArgumentException('Crop must be a normalized rectangle inside the source frame.');
        }
    }

    /** @return array{x: float, y: float, width: float, height: float} */
    public function toArray(): array
    {
        return ['x' => $this->x, 'y' => $this->y, 'width' => $this->width, 'height' => $this->height];
    }
}
