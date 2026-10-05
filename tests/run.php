<?php

declare(strict_types=1);

use Pam\Native\Internal\Wire;
use Pam\Native\MediaEditor\ExportState;
use Pam\Native\MediaEditor\ImageOverlay;
use Pam\Native\MediaEditor\MediaAdjustments;
use Pam\Native\MediaEditor\MediaClip;
use Pam\Native\MediaEditor\MediaCrop;
use Pam\Native\MediaEditor\MediaEditor;
use Pam\Native\MediaEditor\MediaEditorFailure;
use Pam\Native\MediaEditor\MediaExportOptions;
use Pam\Native\MediaEditor\MediaExportResult;
use Pam\Native\MediaEditor\MediaFilter;
use Pam\Native\MediaEditor\MediaTimeline;
use Pam\Native\MediaEditor\MediaTimelineInfo;
use Pam\Native\MediaEditor\OverlayKind;
use Pam\Native\MediaEditor\OverlayPlacement;
use Pam\Native\MediaEditor\TextOverlay;
use Pam\Native\MediaEditor\VideoCodec;
use Pam\Native\ModuleResultStatus;
use Pam\Native\Modules\NativeModules;
use Pam\Native\Modules\NativeModuleTransport;

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
expect(array_column(OverlayKind::cases(), 'value') === range(1, 2), 'OverlayKind values must be sequential.');
expect(array_column(MediaEditorFailure::cases(), 'value') === range(1, 8), 'MediaEditorFailure values must be sequential.');

$idl = json_decode((string) file_get_contents(dirname(__DIR__) . '/pam-native.idl.json'), true, 16, JSON_THROW_ON_ERROR);
foreach ([MediaFilter::class, VideoCodec::class, ExportState::class, OverlayKind::class, MediaEditorFailure::class] as $enum) {
    $short = substr($enum, strrpos($enum, '\\') + 1);
    $cases = [];
    foreach ($enum::cases() as $case) {
        $cases[$case->name] = $case->value;
    }
    expect(($idl['enums'][$short] ?? null) === $cases, "IDL enum {$short} drifted from PHP.");
}

$timeline = new MediaTimeline([
    new MediaClip('imports/intro.mp4', 500, 4_000, 0.8, 1.25, 90, new MediaCrop(0.1, 0.1, 0.8, 0.8), MediaFilter::Vivid),
    new MediaClip('imports/outro.mp4'),
], 'imports/music.m4a', 0.35, true);
$payload = json_decode($timeline->toJson(), true, 32, JSON_THROW_ON_ERROR);
expect(count($payload['clips']) === 2, 'Timeline did not preserve its clips.');
expect($payload['clips'][0]['filter'] === MediaFilter::Vivid->value, 'Filter did not use its integer wire value.');
expect($payload['adjustments'] === null && $payload['overlays'] === [] && $payload['rangeStartMillis'] === 0 && $payload['rangeEndMillis'] === null, 'Optional timeline fields changed defaults.');

$composite = new MediaTimeline(
    [
        MediaClip::image('imports/cover.jpg', 5_000),
        new MediaClip('imports/clip.mp4', removeAudio: true),
    ],
    soundtrack: 'imports/song.m4a',
    soundtrackVolume: 0.8,
    loopSoundtrack: true,
    adjustments: new MediaAdjustments(brightness: 0.1, contrast: -0.2, saturation: -1.0, temperature: 0.5, fade: 0.3, grain: 0.4, vignette: 1.0),
    overlays: [
        new TextOverlay('Olá 😍', new OverlayPlacement(0.5, 0.42, 1.2, 15.0, 1_000, 4_000), '#101713', 72.0, '#FFFFFF'),
        new ImageOverlay('https://media.example.com/a.gif', new OverlayPlacement(0.3, 0.6, 2.0, -30.0, 0, null)),
        new ImageOverlay('imports/sticker.png'),
    ],
    rangeStartMillis: 1_500,
    rangeEndMillis: 9_000,
);
$wire = json_decode($composite->toJson(), true, 32, JSON_THROW_ON_ERROR);
expect($wire['clips'][0]['imageDurationMillis'] === 5_000 && $wire['clips'][0]['removeAudio'] === true, 'Image clip lost its duration or silence.');
expect(MediaClip::image('a.jpg', 10)->isImage() && !(new MediaClip('a.mp4'))->isImage(), 'Image clip detection failed.');
expect($wire['clips'][1]['removeAudio'] === true && $wire['clips'][1]['imageDurationMillis'] === null, 'Video clip mute flag lost.');
expect($wire['adjustments'] === ['brightness' => 0.1, 'contrast' => -0.2, 'saturation' => -1.0, 'temperature' => 0.5, 'fade' => 0.3, 'grain' => 0.4, 'vignette' => 1.0], 'Adjustments changed on the wire.');
expect($wire['overlays'][0] === [
    'kind' => 1, 'text' => 'Olá 😍', 'color' => '#101713', 'fontSize' => 72.0, 'backgroundColor' => '#FFFFFF', 'bold' => true,
    'x' => 0.5, 'y' => 0.42, 'scale' => 1.2, 'rotationDegrees' => 15.0, 'startMillis' => 1_000, 'endMillis' => 4_000,
], 'Text overlay changed on the wire.');
expect($wire['overlays'][1]['kind'] === 2 && $wire['overlays'][1]['source'] === 'https://media.example.com/a.gif' && $wire['overlays'][1]['endMillis'] === null && $wire['overlays'][1]['width'] === 0.34, 'Image overlay changed on the wire.');
expect($wire['rangeStartMillis'] === 1_500 && $wire['rangeEndMillis'] === 9_000 && $wire['loopSoundtrack'] === true, 'Range or soundtrack loop lost.');
expect((new MediaAdjustments())->isNeutral() && !(new MediaAdjustments(grain: 0.1))->isNeutral(), 'Neutral adjustments misdetected.');

$options = new MediaExportOptions('exports/final.mp4', VideoCodec::Hevc, 1920, 1080, 12_000_000, 60);
expect($options->videoCodec === VideoCodec::Hevc, 'Export codec changed.');
$source = new MediaExportOptions('exports/source.mp4', width: null, height: null, videoBitRate: null, timeoutMillis: 120_000);
expect($source->width === null && $source->videoBitRate === null && $source->timeoutMillis === 120_000, 'Source-size export options rejected.');

foreach ([
    static fn () => new MediaClip('../escape.mp4'),
    static fn () => new MediaClip('clip.mp4', 100, 100),
    static fn () => new MediaClip('photo.jpg', 100, imageDurationMillis: 5_000),
    static fn () => MediaClip::image('photo.jpg', 0),
    static fn () => new MediaCrop(0.5, 0.5, 0.6, 0.6),
    static fn () => new MediaTimeline([]),
    static fn () => new MediaTimeline([new MediaClip('a.mp4')], overlays: ['text']),
    static fn () => new MediaTimeline([new MediaClip('a.mp4')], rangeStartMillis: 500, rangeEndMillis: 500),
    static fn () => new MediaExportOptions('/tmp/output.mp4'),
    static fn () => new MediaExportOptions('out.mp4', width: null),
    static fn () => new MediaExportOptions('out.mp4', timeoutMillis: 10),
    static fn () => new MediaAdjustments(brightness: 1.5),
    static fn () => new MediaAdjustments(grain: -0.1),
    static fn () => new OverlayPlacement(1.2, 0.5),
    static fn () => new OverlayPlacement(scale: 5.0),
    static fn () => new OverlayPlacement(startMillis: 900, endMillis: 100),
    static fn () => new TextOverlay(''),
    static fn () => new TextOverlay('Hi', color: 'red'),
    static fn () => new ImageOverlay('http://insecure.example.com/a.png'),
    static fn () => new ImageOverlay('/etc/passwd'),
] as $invalid) {
    try {
        $invalid();
        throw new RuntimeException('Invalid media editor input was accepted.');
    } catch (InvalidArgumentException) {
    }
}

/** Records native calls and lets the test resolve them in any order. */
final class FakeTransport implements NativeModuleTransport
{
    /** @var list<array{method: string, payload: array<string, string|int|float|bool>, complete: Closure}> */
    public array $calls = [];

    public function invoke(int $requestId, string $module, string $method, string $payload, Closure $complete): void
    {
        expect($module === 'media-editor', 'Calls must target the media-editor module.');
        $this->calls[] = ['method' => $method, 'payload' => Wire::decodeMap($payload), 'complete' => $complete];
    }

    /** @param array<string, string|int|float|bool> $values */
    public function reply(string $method, array $values, bool $success = true): void
    {
        foreach ($this->calls as $index => $call) {
            if ($call['method'] === $method) {
                unset($this->calls[$index]);
                $this->calls = array_values($this->calls);
                ($call['complete'])($success ? ModuleResultStatus::Success : ModuleResultStatus::Failure, $success ? Wire::map($values) : (string) ($values['message'] ?? ''));

                return;
            }
        }
        throw new RuntimeException("No pending {$method} call.");
    }
}

$transport = new FakeTransport();
NativeModules::useTransport($transport);
$editor = new MediaEditor();

$results = [];
$progress = [];
$jobId = $editor->export($composite, $source, static function (MediaExportResult $result) use (&$results): void {
    $results[] = $result;
}, static function (int $percent) use (&$progress): void {
    $progress[] = $percent;
});
expect(array_column($transport->calls, 'method') === ['export', 'observe'], 'Export with progress must start one observation.');
$exportPayload = $transport->calls[0]['payload'];
expect($exportPayload['jobId'] === $jobId && $exportPayload['width'] === 0 && $exportPayload['height'] === 0 && $exportPayload['videoBitRate'] === 0 && $exportPayload['timeoutMillis'] === 120_000, 'Export wire options changed.');
expect($transport->calls[1]['payload'] === ['jobId' => $jobId], 'Observation must target the export job.');
$transport->reply('observe', ['jobId' => $jobId, 'state' => 2, 'progress' => 40, 'path' => 'exports/source.mp4', 'message' => '']);
$transport->reply('observe', ['jobId' => $jobId, 'state' => 2, 'progress' => 80, 'path' => 'exports/source.mp4', 'message' => '']);
expect($progress === [40, 80] && array_column($transport->calls, 'method') === ['export', 'observe'], 'Progress pushes must re-arm one observation.');
$completed = ['jobId' => $jobId, 'state' => 3, 'progress' => 100, 'path' => 'exports/source.mp4', 'message' => '', 'bytes' => 2_048, 'durationMillis' => 7_500, 'width' => 720, 'height' => 1280, 'hasAudio' => true, 'rotationDegrees' => 0];
$transport->reply('export', $completed);
$transport->reply('observe', $completed);
expect(count($results) === 1 && $results[0]->completed() && $results[0]->bytes === 2_048 && $results[0]->durationMillis === 7_500 && $results[0]->width === 720 && $results[0]->hasAudio && $results[0]->failure === null, 'Completed export lost its output probe.');
expect($progress === [40, 80] && $transport->calls === [], 'Terminal observation must stop the progress chain.');

$results = [];
$editor->export($composite, $source, static function (MediaExportResult $result) use (&$results): void {
    $results[] = $result;
});
expect(array_column($transport->calls, 'method') === ['export'], 'Export without progress must not observe.');
$transport->reply('export', ['jobId' => 1, 'state' => 5, 'progress' => 12, 'path' => 'exports/source.mp4', 'message' => 'Export timed out', 'failure' => MediaEditorFailure::TimedOut->value]);
expect($results[0]->state === ExportState::Failed && $results[0]->failure === MediaEditorFailure::TimedOut && $results[0]->message === 'Export timed out' && !$results[0]->completed(), 'Typed export failure lost.');

$results = [];
$editor->export($composite, $source, static function (MediaExportResult $result) use (&$results): void {
    $results[] = $result;
});
$transport->reply('export', ['message' => 'jobId is required'], false);
expect($results[0]->state === ExportState::Failed && $results[0]->failure === MediaEditorFailure::Unknown && $results[0]->message === 'jobId is required', 'Transport failure must map to Unknown.');

$probes = [];
$editor->probe($composite, static function (?MediaTimelineInfo $info, ?string $error, ?MediaEditorFailure $failure) use (&$probes): void {
    $probes[] = [$info, $error, $failure];
});
expect(json_decode((string) $transport->calls[0]['payload']['timeline'], true)['clips'][0]['source'] === 'imports/cover.jpg', 'Probe must send the timeline.');
$transport->reply('probe', ['durationMillis' => 13_000, 'clipDurations' => '[5000,8000]', 'width' => 1080, 'height' => 1920, 'hasAudio' => false, 'rotationDegrees' => 0]);
$info = $probes[0][0];
expect($info instanceof MediaTimelineInfo && $info->durationMillis === 13_000 && $info->clipDurationsMillis === [5_000, 8_000] && $info->height === 1920 && !$info->hasAudio && $probes[0][1] === null, 'Probe result lost fields.');
$editor->probe($composite, static function (?MediaTimelineInfo $info, ?string $error, ?MediaEditorFailure $failure) use (&$probes): void {
    $probes[] = [$info, $error, $failure];
});
$transport->reply('probe', ['failure' => MediaEditorFailure::UnreadableSource->value, 'message' => 'Media source does not exist']);
expect($probes[1][0] === null && $probes[1][2] === MediaEditorFailure::UnreadableSource && $probes[1][1] === 'Media source does not exist', 'Probe failure lost its code.');
NativeModules::useTransport(null);

echo "PAM Native Media Editor contracts passed.\n";
