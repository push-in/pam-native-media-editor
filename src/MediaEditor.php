<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

use Closure;
use Pam\Native\Modules\NativeModuleResult;
use Pam\Native\Modules\NativeModules;

final class MediaEditor
{
    private const string MODULE = 'media-editor';

    /** @param Closure(MediaExportResult): void $complete */
    public function export(MediaTimeline $timeline, MediaExportOptions $options, Closure $complete): int
    {
        $jobId = random_int(1, PHP_INT_MAX);
        return NativeModules::call(self::MODULE, 'export', [
            'jobId' => $jobId,
            'timeline' => $timeline->toJson(),
            'destination' => $options->destination,
            'videoCodec' => $options->videoCodec->value,
            'width' => $options->width,
            'height' => $options->height,
            'videoBitRate' => $options->videoBitRate,
            'frameRate' => $options->frameRate,
            'preserveHdr' => $options->preserveHdr,
        ], static fn (NativeModuleResult $result) => $complete(self::result($jobId, $result)));
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

    private static function result(int $jobId, NativeModuleResult $result): MediaExportResult
    {
        $values = $result->values();
        $state = ExportState::tryFrom((int) ($values['state'] ?? ExportState::Failed->value)) ?? ExportState::Failed;
        return new MediaExportResult(
            $jobId,
            $state,
            max(0, min(100, (int) ($values['progress'] ?? 0))),
            is_string($values['path'] ?? null) ? $values['path'] : null,
            $result->succeeded() ? null : $result->message(),
        );
    }
}
