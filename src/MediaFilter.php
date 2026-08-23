<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

enum MediaFilter: int
{
    case None = 1;
    case Monochrome = 2;
    case Sepia = 3;
    case Vivid = 4;
}
