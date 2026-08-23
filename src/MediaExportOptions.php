<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

use InvalidArgumentException;

final readonly class MediaExportOptions
{
    public function __construct(
        public string $destination,
        public VideoCodec $videoCodec = VideoCodec::H264,
        public int $width = 1080,
        public int $height = 1920,
        public int $videoBitRate = 8_000_000,
        public int $frameRate = 30,
        public bool $preserveHdr = true,
    ) {
        MediaClip::assertPath($destination);
        if ($width < 16 || $height < 16 || $width > 8192 || $height > 8192 || $videoBitRate < 100_000 || $videoBitRate > 200_000_000 || $frameRate < 1 || $frameRate > 120) {
            throw new InvalidArgumentException('Export dimensions, bitrate, or frame rate are outside supported bounds.');
        }
    }
}
