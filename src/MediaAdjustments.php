<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

use InvalidArgumentException;

/**
 * Whole-timeline color grade and film effects.
 *
 * Brightness, contrast, saturation and temperature are signed amounts in -1..1
 * (0 = unchanged, saturation -1 = grayscale, temperature > 0 = warmer).
 * Fade lifts and flattens the image, grain draws animated film noise and
 * vignette darkens the frame edges; all three are strengths in 0..1.
 */
final readonly class MediaAdjustments
{
    public function __construct(
        public float $brightness = 0.0,
        public float $contrast = 0.0,
        public float $saturation = 0.0,
        public float $temperature = 0.0,
        public float $fade = 0.0,
        public float $grain = 0.0,
        public float $vignette = 0.0,
    ) {
        foreach ([$brightness, $contrast, $saturation, $temperature] as $value) {
            if (!is_finite($value) || $value < -1 || $value > 1) {
                throw new InvalidArgumentException('Brightness, contrast, saturation and temperature must be between -1 and 1.');
            }
        }
        foreach ([$fade, $grain, $vignette] as $value) {
            if (!is_finite($value) || $value < 0 || $value > 1) {
                throw new InvalidArgumentException('Fade, grain and vignette must be between 0 and 1.');
            }
        }
    }

    public function isNeutral(): bool
    {
        return $this->brightness === 0.0
            && $this->contrast === 0.0
            && $this->saturation === 0.0
            && $this->temperature === 0.0
            && $this->fade === 0.0
            && $this->grain === 0.0
            && $this->vignette === 0.0;
    }

    /** @return array{brightness: float, contrast: float, saturation: float, temperature: float, fade: float, grain: float, vignette: float} */
    public function toArray(): array
    {
        return [
            'brightness' => $this->brightness,
            'contrast' => $this->contrast,
            'saturation' => $this->saturation,
            'temperature' => $this->temperature,
            'fade' => $this->fade,
            'grain' => $this->grain,
            'vignette' => $this->vignette,
        ];
    }
}
