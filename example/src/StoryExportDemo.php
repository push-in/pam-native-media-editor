<?php

declare(strict_types=1);

namespace App;

use InvalidArgumentException;
use Pam\Native\Component;
use Pam\Native\Element;
use Pam\Native\FileReference;
use Pam\Native\MediaEditor\ExportState;
use Pam\Native\MediaEditor\MediaAdjustments;
use Pam\Native\MediaEditor\MediaClip;
use Pam\Native\MediaEditor\MediaEditor;
use Pam\Native\MediaEditor\MediaEditorFailure;
use Pam\Native\MediaEditor\MediaExportOptions;
use Pam\Native\MediaEditor\MediaExportResult;
use Pam\Native\MediaEditor\MediaFilter;
use Pam\Native\MediaEditor\MediaTimeline;
use Pam\Native\MediaEditor\MediaTimelineInfo;
use Pam\Native\MediaEditor\OverlayPlacement;
use Pam\Native\MediaEditor\TextOverlay;
use Pam\Native\MediaEditor\VideoCodec;
use Pam\Native\MediaPickerType;
use Pam\Native\Style;
use Pam\Native\System\Files;
use Pam\Native\UI\Button;
use Pam\Native\UI\Column;
use Pam\Native\UI\SafeAreaView;
use Pam\Native\UI\Screen;
use Pam\Native\UI\Text;

/**
 * Pick up to five photos/videos, then export a 9:16 story: the clips in
 * order (photos last 3 s), a warm grade with vignette, a timed caption and
 * the first 15 seconds only.
 */
final class StoryExportDemo extends Component
{
    /** @var list<FileReference> */
    private array $picked = [];
    private string $status = 'Pick photos or videos';
    private int $progress = 0;
    private ?int $jobId = null;
    private ?MediaEditor $editor = null;

    public function render(): Element
    {
        return Screen::make(
            SafeAreaView::make(
                Column::make(
                    Text::make('Story export')->style(new Style(fontSize: 24, fontWeight: 700)),
                    Button::make('Pick media')->onPress($this->pick(...)),
                    Text::make(count($this->picked).' item(s) selected'),
                    $this->picked !== [] && $this->jobId === null
                        ? Button::make('Export story')->onPress($this->export(...))
                        : null,
                    $this->jobId !== null
                        ? Button::make(sprintf('Cancel (%d%%)', $this->progress))->onPress($this->cancel(...))
                        : null,
                    Text::make($this->status),
                )->style(new Style(flexGrow: 1, padding: 24, gap: 12)),
            ),
        );
    }

    public function pick(): void
    {
        Files::pickMany(MediaPickerType::Media, function (array $files): void {
            $this->picked = array_slice($files, 0, 5);
            if ($this->picked === []) {
                return;
            }
            try {
                $this->editor()->probe($this->timeline(), function (?MediaTimelineInfo $info, ?string $error, ?MediaEditorFailure $failure): void {
                    $this->status = $info === null
                        ? 'Probe failed: '.($failure?->name ?? '').' '.$error
                        : sprintf('%.1f s total, %dx%d, audio %s', $info->durationMillis / 1000, $info->width, $info->height, $info->hasAudio ? 'yes' : 'no');
                });
            } catch (InvalidArgumentException $error) {
                $this->status = $error->getMessage();
            }
        }, limit: 5);
    }

    public function export(): void
    {
        try {
            $timeline = $this->timeline(rangeEndMillis: 15_000);
        } catch (InvalidArgumentException $error) {
            $this->status = $error->getMessage();

            return;
        }
        $this->progress = 0;
        $this->status = 'Exporting…';
        $this->jobId = $this->editor()->export(
            $timeline,
            new MediaExportOptions(
                destination: 'exports/story-'.time().'.mp4',
                videoCodec: VideoCodec::H264,
                width: 1080,
                height: 1920,
                videoBitRate: 6_000_000,
                timeoutMillis: 120_000,
            ),
            function (MediaExportResult $result): void {
                $this->jobId = null;
                $this->status = match ($result->state) {
                    ExportState::Completed => sprintf('Saved %s (%d KB, %.1f s)', $result->path, intdiv($result->bytes, 1024), $result->durationMillis / 1000),
                    ExportState::Cancelled => 'Cancelled',
                    default => 'Failed: '.($result->failure?->name ?? 'Unknown').' '.$result->message,
                };
            },
            progress: function (int $percent): void {
                $this->progress = $percent;
            },
        );
    }

    public function cancel(): void
    {
        if ($this->jobId !== null) {
            $this->editor()->cancel($this->jobId, static fn (bool $_cancelled, ?string $_error) => null);
        }
    }

    private function timeline(?int $rangeEndMillis = null): MediaTimeline
    {
        $clips = [];
        foreach ($this->picked as $file) {
            $clips[] = str_starts_with($file->mimeType, 'video/')
                ? new MediaClip($file->path, filter: MediaFilter::None)
                : MediaClip::image($file->path, 3_000);
        }

        return new MediaTimeline(
            $clips,
            adjustments: new MediaAdjustments(saturation: 0.1, temperature: 0.25, vignette: 0.4),
            overlays: [
                new TextOverlay(
                    'Made with PAM Native',
                    new OverlayPlacement(x: 0.5, y: 0.85, startMillis: 500, endMillis: 4_500),
                    color: '#FFFFFF',
                    fontSize: 56,
                    backgroundColor: '#80000000',
                ),
            ],
            rangeEndMillis: $rangeEndMillis,
        );
    }

    private function editor(): MediaEditor
    {
        return $this->editor ??= new MediaEditor();
    }
}
