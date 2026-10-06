<!-- pam:product-page:start -->
<div align="center">

# PAM Native Media Editor

**Non-destructive editing with native export pipelines.**

Describe crops, trims, transforms, filters, and export jobs in PHP while decoding and rendering stay native.

[![Latest version](https://img.shields.io/packagist/v/pushinbr/pam-native-media-editor?style=flat-square&label=stable)](https://packagist.org/packages/pushinbr/pam-native-media-editor)
[![CI](https://img.shields.io/github/actions/workflow/status/push-in/pam-native-media-editor/ci.yml?branch=main&style=flat-square&label=CI)](https://github.com/push-in/pam-native-media-editor/actions)
![PHP](https://img.shields.io/badge/PHP-8.5-777BB4?style=flat-square&logo=php&logoColor=white)
![Android](https://img.shields.io/badge/Android-API%2026%2B-3DDC84?style=flat-square&logo=android&logoColor=white)
![iOS](https://img.shields.io/badge/iOS-15%2B-000000?style=flat-square&logo=apple&logoColor=white)

**[Documentation](https://push-in.github.io/pam-docs/native/overview/) · [Quick start](#quick-start) · [What you can build](#what-you-can-build) · [PAM ecosystem](https://push-in.github.io/pam-docs/ecosystem/) · [Issues](https://github.com/push-in/pam-native-media-editor/issues)**

</div>

---

## Why PAM Native Media Editor

Describe crops, trims, transforms, filters, and export jobs in PHP while decoding and rendering stay native. The public API is strictly typed for PHP 8.5; expensive or frame-sensitive work stays in Rust or the platform SDK instead of crossing the application boundary every frame.

| | |
| --- | --- |
| **Best for** | A focused capability you can add to any PAM Native application |
| **Native path** | Media3/MediaCodec · AVFoundation/Core Image |
| **Application model** | Composer package + generated native integration |
| **Design rule** | Independent module; no feed, vertical, or application template bundled |

## What you can build

- Creator and social editing flows
- Commerce image preparation
- Trim, crop, rotate, and export workflows

## Quick start

Already have a PAM Native project? Add only this capability:

```bash
pam composer require pushinbr/pam-native-media-editor
pam doctor --fix
```

New to PAM? Follow the **[five-minute PAM Native setup](https://push-in.github.io/pam-docs/native/overview/)** once, then return here. Your application stays a normal Composer project with a committed lockfile.
<!-- pam:product-page:end -->

## Install

```bash
pam composer require pushinbr/pam-native-media-editor
pam doctor --fix
```

The package is a PAM Native plugin (module `media-editor`) discovered from
Composer; nothing is added to `pam-native.json`. It requires
`pushinbr/pam-native` `>=1.0.35 <2.0.0` and PHP 8.5.

- **Android:** no permissions. Dependencies: Media3 `1.10.1`
  (`media3-common`, `media3-effect`, `media3-transformer`), the same version as
  `pam-native-media`, so both packages share one Media3 copy. HTTPS overlay
  images need the `INTERNET` permission, which PAM Native apps already have.
- **iOS:** frameworks `AVFoundation`, `CoreImage`, `CoreMedia`, `CoreVideo`,
  `ImageIO`; no Info.plist keys. Media picked with the core picker is already
  inside the sandbox, so no photo-library usage string is needed for editing.


## See it in action

This package is a non-destructive native editing primitive. It does not install a feed, social,
commerce, or streaming application template. Android uses Media3 Transformer; iOS uses
AVFoundation and Core Image. Encoded media does not cross the PHP boundary frame by frame.

```php
use Pam\Native\MediaEditor\MediaClip;
use Pam\Native\MediaEditor\MediaCrop;
use Pam\Native\MediaEditor\MediaEditor;
use Pam\Native\MediaEditor\MediaExportOptions;
use Pam\Native\MediaEditor\MediaFilter;
use Pam\Native\MediaEditor\MediaTimeline;

$timeline = new MediaTimeline([
    new MediaClip(
        source: 'imports/clip.mp4',
        startMillis: 1_000,
        endMillis: 8_000,
        crop: new MediaCrop(0.1, 0.1, 0.8, 0.8),
        filter: MediaFilter::Vivid,
    ),
], soundtrack: 'imports/music.m4a', soundtrackVolume: 0.35);

(new MediaEditor())->export(
    $timeline,
    new MediaExportOptions('exports/final.mp4'),
    function ($result): void {
        // Persist or share $result->path after ExportState::Completed.
    },
);
```

All sources and destinations are relative to the PAM file sandbox (the `FileReference::$path`
space). States, filters, codecs, overlay kinds and failures are sequential integer-backed enums.

### Mixed timelines, grading, overlays and progress

```php
use Pam\Native\MediaEditor\ImageOverlay;
use Pam\Native\MediaEditor\MediaAdjustments;
use Pam\Native\MediaEditor\MediaEditorFailure;
use Pam\Native\MediaEditor\MediaExportResult;
use Pam\Native\MediaEditor\MediaTimelineInfo;
use Pam\Native\MediaEditor\OverlayPlacement;
use Pam\Native\MediaEditor\TextOverlay;

$timeline = new MediaTimeline(
    [MediaClip::image('imports/cover.jpg', 5_000), new MediaClip('imports/clip.mp4', removeAudio: true)],
    soundtrack: 'imports/song.m4a',
    soundtrackVolume: 0.8,
    loopSoundtrack: true,
    adjustments: new MediaAdjustments(brightness: 0.1, saturation: -0.2, temperature: 0.3, fade: 0.2, grain: 0.3, vignette: 0.5),
    overlays: [
        new TextOverlay('Hello', new OverlayPlacement(x: 0.5, y: 0.4, scale: 1.2, rotationDegrees: 10, startMillis: 500, endMillis: 3_500), backgroundColor: '#FFFFFF', color: '#101713'),
        new ImageOverlay('https://media.example.com/sticker.gif', new OverlayPlacement(0.3, 0.7)),
    ],
    rangeStartMillis: 1_000,   // exported range on the concatenated clip timeline
    rangeEndMillis: 11_000,
);

$editor = new MediaEditor();
$editor->probe($timeline, function (?MediaTimelineInfo $info, ?string $error, ?MediaEditorFailure $failure): void {
    // $info->durationMillis, $info->clipDurationsMillis, $info->width/height, $info->hasAudio
});

$jobId = $editor->export(
    $timeline,
    new MediaExportOptions('exports/edit.mp4', width: null, height: null, videoBitRate: null, timeoutMillis: 120_000),
    function (MediaExportResult $result): void {
        // $result->completed(), ->path, ->bytes, ->durationMillis, ->width, ->height, ->hasAudio
        // or ->failure (MediaEditorFailure) and ->message
    },
    progress: function (int $percent): void {},
);
```

- Image clips last `durationMillis`; video clips keep or drop (`removeAudio`) their audio. When any
  kept clip has audio, image gaps are filled with silence so the output keeps one audio track.
- Overlay times are on the output timeline (0 = `rangeStartMillis`). Images load from the sandbox or
  HTTPS (GIFs animate); an image that fails to load is skipped. Grain and vignette are drawn above
  the overlays.
- `width: null, height: null` keeps the source frame size; `videoBitRate: null` lets the encoder pick.
- Progress is pushed by the native side through a single long-poll (`observe`), not timer polling.
  `status()` and `cancel()` take the identifier returned by `export()`.
- iOS (0.2+) implements the same timeline: image clips (stretched over a cached black clip and
  replaced per frame), ranges, per-clip speed/volume/`removeAudio`, soundtrack, grading, timed
  text/image/GIF overlays, grain and vignette are rendered with Core Image and written by
  AVAssetReader/AVAssetWriter (H.264/HEVC, requested size and bitrate, `moov` first), with the
  same pushed progress, typed failures and output probe. `preserveHdr` is ignored on iOS (SDR
  output). The iOS implementation has not been validated on a device yet; see
  `ios/Tests/MediaEditorTests.swift`.

## A real example: Zé Chat

Zé Chat's story/reel composer builds one timeline from the picked photos and
videos, the trim handles, an effect preset, the adjustment sliders, a
soundtrack and the text/sticker layers the user placed, then exports at the
source size:

```php
use Pam\Native\FileReference;
use Pam\Native\MediaEditor\{MediaClip, MediaEditor, MediaEditorFailure, MediaExportOptions, MediaExportResult, MediaTimeline, VideoCodec};

$timeline = new MediaTimeline(
    array_map(fn (array $s) => $s['video']
        ? new MediaClip($s['path'], removeAudio: $muteAudio)
        : MediaClip::image($s['path'], 5_000), $sources),
    soundtrack: $audioTrackPath !== '' ? $audioTrackPath : null,
    soundtrackVolume: $audioTrackVolume / 100,
    loopSoundtrack: true,
    adjustments: $adjustments,                       // null when every slider is neutral
    overlays: $layers,                               // TextOverlay / ImageOverlay (GIF stickers)
    rangeStartMillis: $trimStartMs,
    rangeEndMillis: $trimEndMs > $trimStartMs ? $trimEndMs : null,
);

(new MediaEditor())->export(
    $timeline,
    new MediaExportOptions(
        destination: 'video-editor/zechat-video-'.hrtime(true).'.mp4',
        videoCodec: VideoCodec::H264,
        width: null, height: null, videoBitRate: null,   // keep the source size, encoder bitrate
        timeoutMillis: 120_000,
    ),
    function (MediaExportResult $result): void {
        if ($result->completed()) {
            $this->media[$index] = new FileReference((string) $result->path, basename((string) $result->path), 'video/mp4', $result->bytes);
            return;
        }
        $this->error = match ($result->failure) {
            MediaEditorFailure::InvalidDuration => 'O vídeo selecionado não tem duração válida.',
            MediaEditorFailure::EmptyRange => 'A timeline selecionada não contém clipes exportáveis.',
            MediaEditorFailure::UnreadableSource => 'Não foi possível ler uma mídia da timeline.',
            MediaEditorFailure::TimedOut => 'A edição do vídeo excedeu o tempo limite.',
            default => 'Não foi possível editar o vídeo.',
        };
    },
    progress: fn (int $percent) => $this->exportProgress = $percent,
);
```

Before showing the trim bar, the composer probes the untrimmed timeline
(`MediaEditor::probe()`) to get the total and per-clip durations. A runnable
minimal app is in [`example/`](example).

## API reference

All classes live in `Pam\Native\MediaEditor`. Value objects are
`readonly` and validate in their constructor. Paths are relative to the PAM
file sandbox.

### `MediaEditor` (module `media-editor`)

| Method | Description |
| --- | --- |
| `export(MediaTimeline $timeline, MediaExportOptions $options, Closure(MediaExportResult) $complete, ?Closure(int) $progress = null): int` | Starts an export and returns its job id. `$complete` runs once (also for cancelled and failed jobs). `$progress` receives 0–100, pushed natively. |
| `probe(MediaTimeline $timeline, Closure(?MediaTimelineInfo, ?string, ?MediaEditorFailure) $complete): int` | Total and per-clip durations, frame size, audio, rotation. |
| `status(int $jobId, Closure(MediaExportResult) $complete): int` | Current state of a job. |
| `cancel(int $jobId, Closure(bool, ?string) $complete): int` | Cancels a job; its `export()` callback completes with `Cancelled`. |

### `MediaTimeline`

`new MediaTimeline(array $clips, ?string $soundtrack = null, float $soundtrackVolume = 1.0, bool $loopSoundtrack = false, ?MediaAdjustments $adjustments = null, array $overlays = [], int $rangeStartMillis = 0, ?int $rangeEndMillis = null)`.
1–128 `MediaClip`s concatenated in order, at most 128 overlays, soundtrack
volume 0–1, range on the concatenated timeline (edge clips are trimmed,
slivers under 60 ms dropped). `toJson()`.

### `MediaClip`

`new MediaClip(string $source, int $startMillis = 0, ?int $endMillis = null, float $volume = 1.0, float $speed = 1.0, int $rotationDegrees = 0, ?MediaCrop $crop = null, MediaFilter $filter = None, bool $removeAudio = false, ?int $imageDurationMillis = null)`;
`MediaClip::image(string $source, int $durationMillis, int $rotationDegrees = 0, ?MediaCrop $crop = null, MediaFilter $filter = None)`
(1 ms–1 h); `isImage()`, `toArray()`, `assertPath()`. Volume 0–1, speed
0.25–4, rotation 0/90/180/270.

### `MediaCrop`, `MediaAdjustments`

`MediaCrop(float $x, float $y, float $width, float $height)`: a normalized
rectangle inside the source frame. `MediaAdjustments(brightness, contrast,
saturation, temperature` (−1…1)`, fade, grain, vignette` (0…1)`)`;
`isNeutral()`, `toArray()`.

### Overlays (`MediaOverlay`)

| Class | Constructor |
| --- | --- |
| `TextOverlay` | `(string $text, OverlayPlacement $placement = new OverlayPlacement(), string $color = '#FFFFFF', float $fontSize = 48.0, ?string $backgroundColor = null, bool $bold = true)`; 1–500 characters, font size 4–512, colors `#RRGGBB` or `#AARRGGBB`. |
| `ImageOverlay` | `(string $source, OverlayPlacement $placement = new OverlayPlacement(), float $width = 0.34, float $maxWidth = 0.72, int $minWidthPixels = 96)`; sandbox path or HTTPS URL, widths are fractions of the frame width. GIFs animate. |
| `OverlayPlacement` | `(float $x = 0.5, float $y = 0.5, float $scale = 1.0, float $rotationDegrees = 0.0, int $startMillis = 0, ?int $endMillis = null)`; normalized center, scale 0.25–4, output-time window. |

Both overlays implement `MediaOverlay` (`kind(): OverlayKind`, `toArray()`).

### `MediaExportOptions`

`(string $destination, VideoCodec $videoCodec = H264, ?int $width = 1080, ?int $height = 1920, ?int $videoBitRate = 8_000_000, int $frameRate = 30, bool $preserveHdr = true, ?int $timeoutMillis = null)`.
Width/height 16–8192 and set together (`null` = source size), bitrate
100 kbps–200 Mbps (`null` = encoder default), 1–120 fps, timeout 1 s–24 h.
`preserveHdr` is ignored on iOS (SDR output).

### Results

`MediaExportResult` (readonly): `jobId`, `state` (`ExportState`), `progress`,
`path`, `message`, `failure` (`MediaEditorFailure`), `bytes`,
`durationMillis`, `width`, `height`, `hasAudio`, `rotationDegrees`;
`completed()`. `MediaTimelineInfo` (readonly): `durationMillis`,
`clipDurationsMillis`, `width`, `height`, `hasAudio`, `rotationDegrees`.

### Enums (int-backed)

| Enum | Cases |
| --- | --- |
| `ExportState` | `Queued = 1`, `Exporting`, `Completed`, `Cancelled`, `Failed = 5` |
| `MediaEditorFailure` | `Unknown = 1`, `UnreadableSource`, `InvalidDuration`, `EmptyRange`, `ExportFailed`, `TimedOut`, `Cancelled`, `OutputMissing = 8` |
| `MediaFilter` | `None = 1`, `Monochrome`, `Sepia`, `Vivid = 4` |
| `VideoCodec` | `H264 = 1`, `Hevc = 2` |
| `OverlayKind` | `Text = 1`, `Image = 2` |

### Errors

Constructors throw `InvalidArgumentException` for absolute or traversal paths,
invalid clip bounds, volumes, speeds, rotations and image durations, crops
outside the frame, out-of-range adjustments, overlay positions, scales,
times, colors, font sizes and texts, invalid overlay URLs, more than 128 clips
or overlays, an empty range and invalid export options. Native problems never
throw: they complete with `state = Failed` and a typed `failure`.

## Limits and troubleshooting

- **`EmptyRange`:** the range removes every clip; check
  `rangeStartMillis`/`rangeEndMillis` against `probe()`.
- **`UnreadableSource`:** the file is missing, not in the sandbox, or uses a
  codec the device cannot decode.
- **`TimedOut`:** raise `timeoutMillis` for long exports or lower the output
  size/bitrate.
- **HEVC fails on older devices:** use `VideoCodec::H264`.
- **An overlay image is missing:** images that fail to load are skipped (not an
  error); use HTTPS or a sandbox path.
- **iOS validation:** the iOS implementation mirrors the Android planning tests
  (`ios/Tests/MediaEditorTests.swift`) but has not been validated on a device yet.

## Compatibility

| `pushinbr/pam-native-media-editor` | `pushinbr/pam-native` | Android | iOS |
| --- | --- | --- | --- |
| 0.2.x | `>=1.0.35 <2.0.0` (tested with 1.14.x) | API 26+ | 15+, full timeline |
| 0.1.1 | `>=1.0.35 <2.0.0` | API 26+ | Clips, crop, filters, speed and soundtrack only |

## Tests

`pam tests/run.php` runs the PHP contract suite. Android JVM tests
(`android/src/test`: timeline planning, grading and overlay math) run from a
PAM Android host that includes this plugin; `ios/Tests/MediaEditorTests.swift`
mirrors them with XCTest.

## License

Apache-2.0. See [LICENSE](LICENSE).

- [PAM introduction](https://push-in.github.io/pam-docs/introduction/)
- [PAM Native overview](https://push-in.github.io/pam-docs/native/overview/)
- [Report an issue](https://github.com/push-in/pam-native-media-editor/issues)
