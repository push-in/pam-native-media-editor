<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

/**
 * Export state. When `state` is Completed, `path` holds the sandbox-relative
 * MP4 and the output probe fields (bytes, duration, frame size, audio) are set.
 */
final readonly class MediaExportResult
{
    public function __construct(
        public int $jobId,
        public ExportState $state,
        public int $progress,
        public ?string $path = null,
        public ?string $message = null,
        public ?MediaEditorFailure $failure = null,
        public int $bytes = 0,
        public int $durationMillis = 0,
        public int $width = 0,
        public int $height = 0,
        public bool $hasAudio = false,
        public int $rotationDegrees = 0,
    ) {}

    public function completed(): bool
    {
        return $this->state === ExportState::Completed && $this->path !== null && $this->path !== '';
    }
}
