<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

use InvalidArgumentException;

/**
 * A still or animated (GIF) image from the sandbox or an HTTPS URL.
 *
 * The drawn width is `width * placement.scale` of the frame width, clamped
 * between `minWidthPixels` and `maxWidth` of the frame width; the height keeps
 * the image aspect ratio. Animated GIFs loop over the output timeline. An image
 * that cannot be loaded is skipped instead of failing the export.
 */
final readonly class ImageOverlay implements MediaOverlay
{
    public function __construct(
        public string $source,
        public OverlayPlacement $placement = new OverlayPlacement(),
        public float $width = 0.34,
        public float $maxWidth = 0.72,
        public int $minWidthPixels = 96,
    ) {
        if (str_starts_with($source, 'https://')) {
            if (strlen($source) > 8192 || filter_var($source, FILTER_VALIDATE_URL) === false) {
                throw new InvalidArgumentException('Overlay image URL is invalid.');
            }
        } else {
            MediaClip::assertPath($source);
        }
        if (!is_finite($width) || !is_finite($maxWidth) || $width <= 0 || $maxWidth <= 0 || $width > 1 || $maxWidth > 1) {
            throw new InvalidArgumentException('Overlay widths must be fractions of the frame width.');
        }
        if ($minWidthPixels < 0 || $minWidthPixels > 8192) {
            throw new InvalidArgumentException('Overlay minimum width is out of range.');
        }
    }

    public function kind(): OverlayKind
    {
        return OverlayKind::Image;
    }

    public function toArray(): array
    {
        return ['kind' => OverlayKind::Image->value, 'source' => $this->source, 'width' => $this->width, 'maxWidth' => $this->maxWidth, 'minWidthPixels' => $this->minWidthPixels] + $this->placement->toArray();
    }
}
