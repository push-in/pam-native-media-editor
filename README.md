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

All sources and destinations are relative to the application sandbox. States, filters and codecs
are sequential integer-backed enums. Poll `status()` for progress and use `cancel()` with the same
job identifier for lifecycle-safe cancellation.

Platform support: Android API 26+, iOS 15+, PHP 8.5+, and PAM Native 0.8.x.

- [PAM introduction](https://push-in.github.io/pam-docs/introduction/)
- [PAM Native overview](https://push-in.github.io/pam-docs/native/overview/)
- [Report an issue](https://github.com/push-in/pam-native-media-editor/issues)
