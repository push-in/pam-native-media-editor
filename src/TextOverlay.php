<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

use InvalidArgumentException;

/**
 * Centered text (emoji included). Optional maxWidth/referenceWidth enable bounded wrapping.
 * Without those fields, the legacy single-line pixel sizing is preserved. The rendered size is
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
        public ?float $maxWidth = null,
        public ?float $referenceWidth = null,
        public int $maxLines = 8,
    ) {
        if ($text === '' || mb_strlen($text) > 500) {
            throw new InvalidArgumentException('Overlay text must contain between 1 and 500 characters.');
        }
        if (!is_finite($fontSize) || $fontSize < 4 || $fontSize > 512) {
            throw new InvalidArgumentException('Overlay font size must be between 4 and 512.');
        }
        if (($maxWidth === null) !== ($referenceWidth === null)
            || ($maxWidth !== null && (!is_finite($maxWidth) || $maxWidth <= 0 || $maxWidth > 1))
            || ($referenceWidth !== null && (!is_finite($referenceWidth) || $referenceWidth < 1 || $referenceWidth > 8192))
            || $maxLines < 1 || $maxLines > 32) {
            throw new InvalidArgumentException('Wrapped text requires a width fraction, reference width and 1–32 lines.');
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
        $layout = $this->maxWidth === null ? [] : ['maxWidth' => $this->maxWidth, 'referenceWidth' => $this->referenceWidth, 'maxLines' => $this->maxLines];
        return $layout + ['kind' => OverlayKind::Text->value, 'text' => $this->text, 'color' => $this->color, 'fontSize' => $this->fontSize, 'backgroundColor' => $this->backgroundColor, 'bold' => $this->bold] + $this->placement->toArray();
    }
}
