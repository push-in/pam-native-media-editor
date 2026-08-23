<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

final readonly class MediaExportResult
{
    public function __construct(
        public int $jobId,
        public ExportState $state,
        public int $progress,
        public ?string $path = null,
        public ?string $message = null,
    ) {}
}
