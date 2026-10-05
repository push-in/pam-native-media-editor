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

### Mixed timelines, grading, overlays and progress (Android)

```php
use Pam\Native\MediaEditor\ImageOverlay;
use Pam\Native\MediaEditor\MediaAdjustments;
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
$editor->probe($timeline, function (?MediaTimelineInfo $info, ?string $error): void {
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
- iOS currently supports the original clip/crop/filter/soundtrack export; probe, image clips,
  grading, overlays, ranges and progress are Android-only for now.

Platform support: Android API 26+, iOS 15+, PHP 8.5+, and PAM Native 1.0.35+.

- [PAM introduction](https://push-in.github.io/pam-docs/introduction/)
- [PAM Native overview](https://push-in.github.io/pam-docs/native/overview/)
- [Report an issue](https://github.com/push-in/pam-native-media-editor/issues)
