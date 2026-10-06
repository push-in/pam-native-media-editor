# Story export demo

A one-screen PAM Native app for `pushinbr/pam-native-media-editor`: pick up to
five photos and videos with the core picker, probe the timeline, then export a
1080×1920 story (photos last 3 s, warm grade with vignette, a timed caption,
first 15 seconds) with pushed progress and cancellation.

```bash
cd example
pam composer install
pam doctor --fix
pam dev            # or: pam build
```

The app installs the released package from Packagist. The exported MP4 is written to `exports/` in the PAM file
sandbox; share or upload it with the core `Share`/`Files` APIs.
