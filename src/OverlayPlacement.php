<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

use InvalidArgumentException;

/**
 * Where and when an overlay is drawn: a normalized center point (0..1 of the
 * frame), a uniform scale, a clockwise rotation around the center and a
 * visibility window in output timeline milliseconds (inclusive; null end = until the end).
 */
final readonly class OverlayPlacement
{
    public function __construct(
        public float $x = 0.5,
        public float $y = 0.5,
        public float $scale = 1.0,
        public float $rotationDegrees = 0.0,
        public int $startMillis = 0,
        public ?int $endMillis = null,
    ) {
        if (!is_finite($x) || !is_finite($y) || $x < 0 || $x > 1 || $y < 0 || $y > 1) {
            throw new InvalidArgumentException('Overlay position must be normalized between 0 and 1.');
        }
        if (!is_finite($scale) || $scale < 0.25 || $scale > 4) {
            throw new InvalidArgumentException('Overlay scale must be between 0.25 and 4.');
        }
        if (!is_finite($rotationDegrees)) {
            throw new InvalidArgumentException('Overlay rotation must be finite.');
        }
        if ($startMillis < 0 || ($endMillis !== null && $endMillis < $startMillis)) {
            throw new InvalidArgumentException('Overlay time range is invalid.');
        }
    }

    /** @return array{x: float, y: float, scale: float, rotationDegrees: float, startMillis: int, endMillis: int|null} */
    public function toArray(): array
    {
        return [
            'x' => $this->x,
            'y' => $this->y,
            'scale' => $this->scale,
            'rotationDegrees' => $this->rotationDegrees,
            'startMillis' => $this->startMillis,
            'endMillis' => $this->endMillis,
        ];
    }

    public static function assertColor(string $color): void
    {
        if (preg_match('/^#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/', $color) !== 1) {
            throw new InvalidArgumentException('Overlay colors must be #RRGGBB or #AARRGGBB.');
        }
    }
}
