<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

use Closure;
use Pam\Native\Modules\NativeModuleResult;
use Pam\Native\Modules\NativeModules;

final class MediaEditor
{
    private const string MODULE = 'media-editor';

    /**
     * Starts a native export and returns its job identifier (for `status()` and `cancel()`).
     *
     * `$complete` runs once with the terminal result (Completed, Cancelled or
     * Failed). When `$progress` is given it receives 0-100 while exporting; the
     * native side pushes each change, so PHP never polls on a timer.
     *
     * @param Closure(MediaExportResult): void $complete
     * @param null|Closure(int): void $progress
     */
    public function export(MediaTimeline $timeline, MediaExportOptions $options, Closure $complete, ?Closure $progress = null): int
    {
        $jobId = random_int(1, PHP_INT_MAX);
        $finished = false;
        NativeModules::call(self::MODULE, 'export', [
            'jobId' => $jobId,
            'timeline' => $timeline->toJson(),
            'destination' => $options->destination,
            'videoCodec' => $options->videoCodec->value,
            'width' => $options->width ?? 0,
            'height' => $options->height ?? 0,
            'videoBitRate' => $options->videoBitRate ?? 0,
            'frameRate' => $options->frameRate,
            'preserveHdr' => $options->preserveHdr,
            'timeoutMillis' => $options->timeoutMillis ?? 0,
        ], static function (NativeModuleResult $result) use ($jobId, $complete, &$finished): void {
            if ($finished) {
                return;
            }
            $finished = true;
            $complete(self::result($jobId, $result));
        });
        if ($progress !== null) {
            self::observe($jobId, $progress, $finished);
        }

        return $jobId;
    }

    /**
     * Probes every clip of the timeline without exporting it.
     *
     * @param Closure(?MediaTimelineInfo, ?string, ?MediaEditorFailure): void $complete
     */
    public function probe(MediaTimeline $timeline, Closure $complete): int
    {
        return NativeModules::call(self::MODULE, 'probe', ['timeline' => $timeline->toJson()], static function (NativeModuleResult $result) use ($complete): void {
            if (!$result->succeeded()) {
                $complete(null, $result->message(), MediaEditorFailure::Unknown);

                return;
            }
            $values = $result->values();
            $failure = MediaEditorFailure::tryFrom((int) ($values['failure'] ?? 0));
            if ($failure !== null) {
                $complete(null, (string) ($values['message'] ?? ''), $failure);

                return;
            }
            $clips = json_decode((string) ($values['clipDurations'] ?? '[]'), true);
            $durations = [];
            foreach (is_array($clips) ? $clips : [] as $duration) {
                $durations[] = max(0, is_numeric($duration) ? (int) $duration : 0);
            }
            $complete(new MediaTimelineInfo(
                max(0, (int) ($values['durationMillis'] ?? 0)),
                $durations,
                max(0, (int) ($values['width'] ?? 0)),
                max(0, (int) ($values['height'] ?? 0)),
                (bool) ($values['hasAudio'] ?? false),
                (int) ($values['rotationDegrees'] ?? 0),
            ), null, null);
        });
    }

    /** @param Closure(MediaExportResult): void $complete */
    public function status(int $jobId, Closure $complete): int
    {
        return NativeModules::call(self::MODULE, 'status', ['jobId' => $jobId], static fn (NativeModuleResult $result) => $complete(self::result($jobId, $result)));
    }

    /** @param Closure(bool, ?string): void $complete */
    public function cancel(int $jobId, Closure $complete): int
    {
        return NativeModules::call(self::MODULE, 'cancel', ['jobId' => $jobId], static fn (NativeModuleResult $result) => $complete($result->succeeded(), $result->succeeded() ? null : $result->message()));
    }

    /** @param Closure(int): void $progress */
    private static function observe(int $jobId, Closure $progress, bool &$finished): void
    {
        NativeModules::call(self::MODULE, 'observe', ['jobId' => $jobId], static function (NativeModuleResult $result) use ($jobId, $progress, &$finished): void {
            if ($finished || !$result->succeeded()) {
                return;
            }
            $values = $result->values();
            $state = ExportState::tryFrom((int) ($values['state'] ?? 0));
            if ($state !== ExportState::Queued && $state !== ExportState::Exporting) {
                return;
            }
            $progress(max(0, min(100, (int) ($values['progress'] ?? 0))));
            self::observe($jobId, $progress, $finished);
        });
    }

    private static function result(int $jobId, NativeModuleResult $result): MediaExportResult
    {
        if (!$result->succeeded()) {
            return new MediaExportResult($jobId, ExportState::Failed, 0, null, $result->message(), MediaEditorFailure::Unknown);
        }
        $values = $result->values();
        $state = ExportState::tryFrom((int) ($values['state'] ?? ExportState::Failed->value)) ?? ExportState::Failed;
        $message = is_string($values['message'] ?? null) && $values['message'] !== '' ? $values['message'] : null;
        $failure = MediaEditorFailure::tryFrom((int) ($values['failure'] ?? 0));
        if ($state === ExportState::Failed && $failure === null) {
            $failure = MediaEditorFailure::Unknown;
        }
        if ($state === ExportState::Cancelled && $failure === null) {
            $failure = MediaEditorFailure::Cancelled;
        }
        $path = is_string($values['path'] ?? null) && $values['path'] !== '' ? $values['path'] : null;

        return new MediaExportResult(
            $jobId,
            $state,
            max(0, min(100, (int) ($values['progress'] ?? 0))),
            $path,
            $message,
            $failure,
            max(0, (int) ($values['bytes'] ?? 0)),
            max(0, (int) ($values['durationMillis'] ?? 0)),
            max(0, (int) ($values['width'] ?? 0)),
            max(0, (int) ($values['height'] ?? 0)),
            (bool) ($values['hasAudio'] ?? false),
            (int) ($values['rotationDegrees'] ?? 0),
        );
    }
}
