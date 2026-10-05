<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

use InvalidArgumentException;

/**
 * Centered single-line text (emoji included). The rendered size is
 * `fontSize * placement.scale` pixels; an optional rounded background box is
 * padded by `20 * scale` pixels.
 */
final readonly class TextOverlay implements MediaOverlay
{
    public function __construct(
        public string $text,
        public OverlayPlacement $placement = new OverlayPlacement(),
        public string $color = '#FFFFFF',
        public float $fontSize = 48.0,
        public ?string $backgroundColor = null,
        public bool $bold = true,
    ) {
        if ($text === '' || mb_strlen($text) > 500) {
            throw new InvalidArgumentException('Overlay text must contain between 1 and 500 characters.');
        }
        if (!is_finite($fontSize) || $fontSize < 4 || $fontSize > 512) {
            throw new InvalidArgumentException('Overlay font size must be between 4 and 512.');
        }
        OverlayPlacement::assertColor($color);
        if ($backgroundColor !== null) {
            OverlayPlacement::assertColor($backgroundColor);
        }
    }

    public function kind(): OverlayKind
    {
        return OverlayKind::Text;
    }

    public function toArray(): array
    {
        return ['kind' => OverlayKind::Text->value, 'text' => $this->text, 'color' => $this->color, 'fontSize' => $this->fontSize, 'backgroundColor' => $this->backgroundColor, 'bold' => $this->bold] + $this->placement->toArray();
    }
}
