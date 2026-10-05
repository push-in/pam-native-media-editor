<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

use InvalidArgumentException;

/**
 * Output settings. Pass `width: null, height: null` to keep the source frame
 * size, `videoBitRate: null` to let the encoder pick, and `timeoutMillis` to
 * cancel and fail an export that runs longer than that.
 */
final readonly class MediaExportOptions
{
    public function __construct(
        public string $destination,
        public VideoCodec $videoCodec = VideoCodec::H264,
        public ?int $width = 1080,
        public ?int $height = 1920,
        public ?int $videoBitRate = 8_000_000,
        public int $frameRate = 30,
        public bool $preserveHdr = true,
        public ?int $timeoutMillis = null,
    ) {
        MediaClip::assertPath($destination);
        if (($width === null) !== ($height === null)) {
            throw new InvalidArgumentException('Export width and height must both be set or both be null.');
        }
        if (($width !== null && ($width < 16 || $width > 8192)) || ($height !== null && ($height < 16 || $height > 8192))) {
            throw new InvalidArgumentException('Export dimensions are outside supported bounds.');
        }
        if (($videoBitRate !== null && ($videoBitRate < 100_000 || $videoBitRate > 200_000_000)) || $frameRate < 1 || $frameRate > 120) {
            throw new InvalidArgumentException('Export bitrate or frame rate is outside supported bounds.');
        }
        if ($timeoutMillis !== null && ($timeoutMillis < 1_000 || $timeoutMillis > 86_400_000)) {
            throw new InvalidArgumentException('Export timeout must be between 1 second and 24 hours.');
        }
    }
}
