<?php

declare(strict_types=1);

use Pam\Native\MediaEditor\ExportState;
use Pam\Native\MediaEditor\MediaClip;
use Pam\Native\MediaEditor\MediaCrop;
use Pam\Native\MediaEditor\MediaExportOptions;
use Pam\Native\MediaEditor\MediaFilter;
use Pam\Native\MediaEditor\MediaTimeline;
use Pam\Native\MediaEditor\VideoCodec;

require_once dirname(__DIR__) . '/vendor/autoload.php';

function expect(bool $condition, string $message): void
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

expect(array_column(MediaFilter::cases(), 'value') === range(1, 4), 'MediaFilter values must be sequential.');
expect(array_column(ExportState::cases(), 'value') === range(1, 5), 'ExportState values must be sequential.');
expect(array_column(VideoCodec::cases(), 'value') === range(1, 2), 'VideoCodec values must be sequential.');

$timeline = new MediaTimeline([
    new MediaClip('imports/intro.mp4', 500, 4_000, 0.8, 1.25, 90, new MediaCrop(0.1, 0.1, 0.8, 0.8), MediaFilter::Vivid),
    new MediaClip('imports/outro.mp4'),
], 'imports/music.m4a', 0.35, true);
$payload = json_decode($timeline->toJson(), true, 32, JSON_THROW_ON_ERROR);
expect(count($payload['clips']) === 2, 'Timeline did not preserve its clips.');
expect($payload['clips'][0]['filter'] === MediaFilter::Vivid->value, 'Filter did not use its integer wire value.');

$options = new MediaExportOptions('exports/final.mp4', VideoCodec::Hevc, 1920, 1080, 12_000_000, 60);
expect($options->videoCodec === VideoCodec::Hevc, 'Export codec changed.');

foreach ([
    static fn () => new MediaClip('../escape.mp4'),
    static fn () => new MediaClip('clip.mp4', 100, 100),
    static fn () => new MediaCrop(0.5, 0.5, 0.6, 0.6),
    static fn () => new MediaTimeline([]),
    static fn () => new MediaExportOptions('/tmp/output.mp4'),
] as $invalid) {
    try {
        $invalid();
        throw new RuntimeException('Invalid media editor input was accepted.');
    } catch (InvalidArgumentException) {
    }
}

echo "PAM Native Media Editor contracts passed.\n";
