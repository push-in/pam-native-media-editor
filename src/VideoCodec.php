<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

enum VideoCodec: int
{
    case H264 = 1;
    case Hevc = 2;
}
