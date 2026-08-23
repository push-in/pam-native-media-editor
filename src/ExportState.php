<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

enum ExportState: int
{
    case Queued = 1;
    case Exporting = 2;
    case Completed = 3;
    case Cancelled = 4;
    case Failed = 5;
}
