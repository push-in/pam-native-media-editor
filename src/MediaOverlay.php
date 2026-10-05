<?php

declare(strict_types=1);

namespace Pam\Native\MediaEditor;

/**
 * A layer drawn over the exported video for a time range of the output timeline.
 */
interface MediaOverlay
{
    public function kind(): OverlayKind;

    /** @return array<string, string|int|float|bool|null> */
    public function toArray(): array;
}
