<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

/** Why a probe or export failed, so applications can show their own copy. */
enum MediaEditorFailure: int
{
    case Unknown = 1;
    case UnreadableSource = 2;
    case InvalidDuration = 3;
    case EmptyRange = 4;
    case ExportFailed = 5;
    case TimedOut = 6;
    case Cancelled = 7;
    case OutputMissing = 8;
}
