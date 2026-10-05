# Changelog

## 0.1.1 - 2026-10-05

- Add image clips (`MediaClip::image($path, $durationMillis)`), per-clip `removeAudio`, and an
  exported `rangeStartMillis`/`rangeEndMillis` on the concatenated timeline (edge clips are trimmed,
  slivers under 60 ms dropped).
- Add `MediaAdjustments` (brightness, contrast, saturation, temperature, fade, grain, vignette) as a
  whole-timeline grade.
- Add timed `TextOverlay` / `ImageOverlay` layers positioned by `OverlayPlacement` (normalized
  center, scale, rotation, output-time window); images load from the sandbox or HTTPS and GIFs animate.
- Add `MediaEditor::probe()` returning `MediaTimelineInfo` (total and per-clip durations, frame size,
  audio, rotation).
- `MediaEditor::export()` now returns the job identifier, accepts a pushed `progress` listener
  (native long-poll, no PHP timers) and completes with the output probe (bytes, duration, size,
  audio, rotation) or a typed `MediaEditorFailure`; cancelled exports complete their callback.
- `MediaExportOptions` accepts `width`/`height`/`videoBitRate` = null (keep source size / encoder
  default) and `timeoutMillis`.
- Fix: Android resolves paths in the PAM file sandbox (`filesDir/pam-files`), matching `FileReference`.
- Android probing, image loading and export preparation run off the main thread.
- Align Media3 with pam-native-media (1.10.1) and require PAM Native `>=1.0.35 <2.0.0`.
- Add Android JVM unit tests for timeline planning, grading and overlay math.

## 0.1.0

- Initial non-destructive timeline export (clips, crop, rotation, filters, speed, soundtrack).
