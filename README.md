# PAM Native Media Editor

## Start here

Install PAM, initialize a native application, then add this single horizontal capability:

```bash
curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 15 --max-time 60 --max-filesize 1048576 -fsSL \
    https://github.com/push-in/pam/releases/latest/download/install.sh | sh

pam init my-app --template native
cd my-app
pam composer require pushinbr/pam-native-media-editor
pam doctor --fix
```

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
