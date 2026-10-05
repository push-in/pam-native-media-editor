import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UIKit

struct ProbedMedia: Equatable {
    let width: Int64
    let height: Int64
    let durationMs: Int64
    let hasAudio: Bool
    let rotation: Int64
}

enum MediaProbe {
    static func video(_ url: URL) throws -> ProbedMedia {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard asset.isReadable else { throw EditorFailure(EditorFailure.unreadableSource, "Media source is not readable") }
        let track = asset.tracks(withMediaType: .video).first
        let size = track.map { $0.naturalSize.applying($0.preferredTransform) } ?? .zero
        let seconds = asset.duration.seconds
        return ProbedMedia(
            width: Int64(abs(size.width)),
            height: Int64(abs(size.height)),
            durationMs: seconds.isFinite ? Int64(seconds * 1_000) : 0,
            hasAudio: !asset.tracks(withMediaType: .audio).isEmpty,
            rotation: rotation(track?.preferredTransform ?? .identity)
        )
    }

    static func image(_ url: URL) throws -> ProbedMedia {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value else {
            throw EditorFailure(EditorFailure.unreadableSource, "Image source is not readable")
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swap = (5...8).contains(orientation)
        return ProbedMedia(width: swap ? height : width, height: swap ? width : height, durationMs: 0, hasAudio: false, rotation: 0)
    }

    static func rotation(_ transform: CGAffineTransform) -> Int64 {
        let degrees = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
        return Int64((degrees + 360) % 360)
    }

    /// EXIF orientation that displays a track frame like its preferredTransform.
    static func orientation(_ transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch rotation(transform) {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }
}

struct ResolvedClip {
    let json: [String: Any]
    let url: URL
    let image: Bool
    let media: ProbedMedia
    let planned: PlannedClip

    var removeAudio: Bool { (json["removeAudio"] as? Bool) ?? false }

    static func resolve(_ timeline: [String: Any], strict: Bool, file: (String) throws -> URL) throws -> [ResolvedClip] {
        guard let clips = timeline["clips"] as? [[String: Any]], (1...128).contains(clips.count) else {
            throw EditorFailure(EditorFailure.emptyRange, "Timeline requires between 1 and 128 clips")
        }
        return try clips.enumerated().map { index, clip in
            guard let source = clip["source"] as? String else {
                throw EditorFailure(EditorFailure.unreadableSource, "Clip \(index) has no source")
            }
            let url = try file(source)
            if let duration = (clip["imageDurationMillis"] as? NSNumber)?.int64Value {
                return ResolvedClip(
                    json: clip, url: url, image: true, media: try MediaProbe.image(url),
                    planned: PlannedClip(timelineDurationMs: max(duration, 1), image: true)
                )
            }
            let media = try MediaProbe.video(url)
            let start = max((clip["startMillis"] as? NSNumber)?.int64Value ?? 0, 0)
            let end = min((clip["endMillis"] as? NSNumber)?.int64Value ?? media.durationMs, media.durationMs)
            let speed = min(max((clip["speed"] as? NSNumber)?.doubleValue ?? 1, 0.25), 4)
            let duration = Int64(Double(max(end - start, 0)) / speed)
            if strict && duration <= 0 {
                throw EditorFailure(EditorFailure.invalidDuration, "Clip \(index) has no valid duration")
            }
            return ResolvedClip(
                json: clip, url: url, image: false, media: media,
                planned: PlannedClip(timelineDurationMs: duration, sourceStartMs: start, speed: speed, image: false)
            )
        }
    }
}

/// Builds the composition (video + image clips, per-clip audio, soundtrack)
/// and exports it through AVAssetReader/AVAssetWriter so the requested bitrate,
/// codec and size are honored.
final class EditorExporter {
    struct Settings {
        let width: Int
        let height: Int
        let frameRate: Int
        let videoBitRate: Int
        let hevc: Bool
    }

    private struct SegmentPlan {
        let range: CMTimeRange
        let clip: ResolvedClip
        let image: CIImage?
        let orientation: CGImagePropertyOrientation
    }

    private let context = CIContext(options: [.cacheIntermediates: false])

    /// Blocking; returns the written file probe. [cancelled] is polled per frame.
    func export(
        timeline: [String: Any],
        clips: [ResolvedClip],
        segments: [ClipSegment],
        soundtrack: URL?,
        destination: URL,
        settings: Settings,
        overlay: EditorOverlay,
        cancelled: @escaping () -> Bool,
        progress: @escaping (Int) -> Void
    ) throws {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw EditorFailure(EditorFailure.exportFailed, "Cannot create the composition")
        }
        let audioParameters = AVMutableAudioMixInputParameters(track: audioTrack)
        var cursor = CMTime.zero
        var plans: [SegmentPlan] = []
        var hasClipAudio = false
        var outputSize = CGSize.zero
        for segment in segments {
            let clip = clips[segment.index]
            let duration = CMTime(value: segment.durationMs, timescale: 1_000)
            if segment.image {
                let placeholder = try PlaceholderVideo.url()
                let asset = AVURLAsset(url: placeholder)
                guard let frames = asset.tracks(withMediaType: .video).first else {
                    throw EditorFailure(EditorFailure.exportFailed, "Placeholder video is unreadable")
                }
                let unit = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
                try videoTrack.insertTimeRange(unit, of: frames, at: cursor)
                videoTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: unit.duration), toDuration: duration)
                let image = Self.loadImage(clip.url)
                plans.append(SegmentPlan(range: CMTimeRange(start: cursor, duration: duration), clip: clip, image: image, orientation: .up))
                outputSize = CGSize(width: max(outputSize.width, CGFloat(clip.media.width)), height: max(outputSize.height, CGFloat(clip.media.height)))
                cursor = CMTimeAdd(cursor, duration)
                continue
            }
            let asset = AVURLAsset(url: clip.url)
            let sourceRange = CMTimeRange(
                start: CMTime(value: segment.sourceStartMs, timescale: 1_000),
                end: CMTime(value: segment.sourceEndMs, timescale: 1_000)
            )
            let outputDuration = CMTimeMultiplyByFloat64(sourceRange.duration, multiplier: 1 / clip.planned.speed)
            guard let sourceVideo = asset.tracks(withMediaType: .video).first else {
                throw EditorFailure(EditorFailure.unreadableSource, "Clip has no video track")
            }
            try videoTrack.insertTimeRange(sourceRange, of: sourceVideo, at: cursor)
            videoTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: sourceRange.duration), toDuration: outputDuration)
            if !clip.removeAudio, let sourceAudio = asset.tracks(withMediaType: .audio).first {
                try audioTrack.insertTimeRange(sourceRange, of: sourceAudio, at: cursor)
                audioTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: sourceRange.duration), toDuration: outputDuration)
                let volume = Float(min(max((clip.json["volume"] as? NSNumber)?.doubleValue ?? 1, 0), 1))
                audioParameters.setVolume(volume, at: cursor)
                hasClipAudio = true
            }
            plans.append(SegmentPlan(
                range: CMTimeRange(start: cursor, duration: outputDuration),
                clip: clip,
                image: nil,
                orientation: MediaProbe.orientation(sourceVideo.preferredTransform)
            ))
            outputSize = CGSize(width: max(outputSize.width, CGFloat(clip.media.width)), height: max(outputSize.height, CGFloat(clip.media.height)))
            cursor = CMTimeAdd(cursor, outputDuration)
        }
        videoTrack.preferredTransform = .identity
        var mix: [AVAudioMixInputParameters] = []
        if hasClipAudio {
            mix.append(audioParameters)
        } else {
            composition.removeTrack(audioTrack)
        }
        if let soundtrack,
           let source = AVURLAsset(url: soundtrack).tracks(withMediaType: .audio).first,
           let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let sourceDuration = AVURLAsset(url: soundtrack).duration
            var position = CMTime.zero
            let loop = (timeline["loopSoundtrack"] as? Bool) ?? false
            repeat {
                let remaining = CMTimeSubtract(cursor, position)
                let length = CMTimeCompare(sourceDuration, remaining) < 0 ? sourceDuration : remaining
                guard length.seconds > 0 else { break }
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: position)
                position = CMTimeAdd(position, length)
            } while loop && CMTimeCompare(position, cursor) < 0
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(Float(min(max((timeline["soundtrackVolume"] as? NSNumber)?.doubleValue ?? 1, 0), 1)), at: .zero)
            mix.append(parameters)
        }

        if settings.width > 0 && settings.height > 0 {
            outputSize = CGSize(width: settings.width, height: settings.height)
        }
        outputSize = CGSize(width: max(16, Self.even(outputSize.width)), height: max(16, Self.even(outputSize.height)))
        let grade = Self.grade(timeline["adjustments"] as? [String: Any] ?? [:])
        let size = outputSize
        let videoComposition = AVMutableVideoComposition(asset: composition) { [plans] request in
            let time = request.compositionTime
            let plan = plans.first { CMTimeRangeContainsTime($0.range, time: time) } ?? plans.last
            var image = plan?.image ?? request.sourceImage.oriented(plan?.orientation ?? .up)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            if let plan { image = Self.applyClipEdits(plan.clip.json, to: image) }
            image = Self.applyGrade(grade, to: image)
            image = Self.fit(image, into: size)
            image = overlay.composite(over: image, size: size, timeMs: Int64(time.seconds * 1_000))
            request.finish(with: image.cropped(to: CGRect(origin: .zero, size: size)), context: nil)
        }
        videoComposition.renderSize = outputSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(min(max(settings.frameRate, 1), 120)))
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mix

        try write(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            destination: destination,
            size: outputSize,
            settings: settings,
            duration: cursor.seconds,
            cancelled: cancelled,
            progress: progress
        )
    }

    private func write(
        composition: AVMutableComposition,
        videoComposition: AVVideoComposition,
        audioMix: AVAudioMix,
        destination: URL,
        size: CGSize,
        settings: Settings,
        duration: Double,
        cancelled: @escaping () -> Bool,
        progress: @escaping (Int) -> Void
    ) throws {
        let reader = try AVAssetReader(asset: composition)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.videoComposition = videoComposition
        reader.add(videoOutput)
        let audioTracks = composition.tracks(withMediaType: .audio)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.audioMix = audioMix
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }
        let fileType: AVFileType = destination.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true
        var compression: [String: Any] = [AVVideoMaxKeyFrameIntervalDurationKey: 2]
        if settings.videoBitRate > 0 { compression[AVVideoAverageBitRateKey] = settings.videoBitRate }
        if !settings.hevc { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }
        guard reader.startReading() else {
            throw EditorFailure(EditorFailure.exportFailed, reader.error?.localizedDescription ?? "Cannot read the timeline")
        }
        guard writer.startWriting() else {
            throw EditorFailure(EditorFailure.exportFailed, writer.error?.localizedDescription ?? "Cannot start the export")
        }
        writer.startSession(atSourceTime: .zero)
        let group = DispatchGroup()
        let stop = ExportStop()
        func pump(_ output: AVAssetReaderOutput, _ input: AVAssetWriterInput, _ label: String, _ reports: Bool) {
            group.enter()
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "pam.media-editor.\(label)")) {
                while input.isReadyForMoreMediaData {
                    if stop.check(cancelled) {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    if reports, duration > 0 {
                        let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if seconds.isFinite { progress(Int(min(max(seconds / duration, 0), 0.99) * 100)) }
                    }
                    if !input.append(sample) {
                        stop.abort()
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }
        pump(videoOutput, videoInput, "video", true)
        if let audioOutput, let audioInput { pump(audioOutput, audioInput, "audio", false) }
        group.wait()
        if stop.aborted || reader.status == .failed {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            if cancelled() { throw EditorFailure(EditorFailure.cancelled, "Export cancelled") }
            throw EditorFailure(
                EditorFailure.exportFailed,
                writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "Media export failed"
            )
        }
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw EditorFailure(EditorFailure.exportFailed, writer.error?.localizedDescription ?? "Media export failed")
        }
    }

    // MARK: Frame edits

    static func applyClipEdits(_ clip: [String: Any], to source: CIImage) -> CIImage {
        var image = source
        if let crop = clip["crop"] as? [String: Any],
           let x = (crop["x"] as? NSNumber)?.doubleValue, let y = (crop["y"] as? NSNumber)?.doubleValue,
           let width = (crop["width"] as? NSNumber)?.doubleValue, let height = (crop["height"] as? NSNumber)?.doubleValue {
            let extent = image.extent
            // Normalized crop uses a top-left origin; CoreImage is y-up.
            image = image.cropped(to: CGRect(
                x: extent.minX + extent.width * x,
                y: extent.minY + extent.height * (1 - y - height),
                width: extent.width * width,
                height: extent.height * height
            ))
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        let rotation = (clip["rotationDegrees"] as? NSNumber)?.doubleValue ?? 0
        if rotation != 0 {
            // Clockwise like Media3; CoreImage angles are counter-clockwise.
            image = image.transformed(by: CGAffineTransform(rotationAngle: -rotation * .pi / 180))
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        switch (clip["filter"] as? NSNumber)?.intValue ?? 1 {
        case 2:
            image = image.applyingFilter("CIPhotoEffectMono")
        case 3:
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.393, y: 0.769, z: 0.189, w: 0),
                "inputGVector": CIVector(x: 0.349, y: 0.686, z: 0.168, w: 0),
                "inputBVector": CIVector(x: 0.272, y: 0.534, z: 0.131, w: 0),
            ])
        case 4:
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.08, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1.04, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1.1, w: 0),
            ])
        default:
            break
        }
        return image
    }

    static func grade(_ adjustments: [String: Any]) -> ColorGrade {
        func value(_ key: String) -> Double { (adjustments[key] as? NSNumber)?.doubleValue ?? 0 }
        return ColorGrade.from(
            brightness: value("brightness"),
            contrast: value("contrast"),
            saturation: value("saturation"),
            temperature: value("temperature"),
            fade: value("fade")
        )
    }

    static func applyGrade(_ grade: ColorGrade, to source: CIImage) -> CIImage {
        guard !grade.isIdentity else { return source }
        var image = source
        if grade.hasBrightness || grade.hasContrast || grade.hasSaturation {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: grade.brightness,
                kCIInputContrastKey: grade.contrastFactor,
                kCIInputSaturationKey: 1 + grade.saturationPercent / 100,
            ])
        }
        if grade.hasTemperature {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: grade.redScale, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: grade.blueScale, w: 0),
            ])
        }
        return image
    }

    /// Scale-to-fit and centre on black (Media3 LAYOUT_SCALE_TO_FIT).
    static func fit(_ image: CIImage, into size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)) }
        let scale = min(size.width / extent.width, size.height / extent.height)
        var fitted = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        fitted = fitted.transformed(by: CGAffineTransform(
            translationX: (size.width - fitted.extent.width) / 2 - fitted.extent.minX,
            y: (size.height - fitted.extent.height) / 2 - fitted.extent.minY
        ))
        return fitted.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)))
    }

    static func loadImage(_ url: URL) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4_096,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { CIImage(cgImage: $0) }
    }

    static func even(_ value: CGFloat) -> CGFloat {
        let integer = Int(value)
        return CGFloat(integer - integer % 2)
    }
}

final class ExportStop: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var aborted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func abort() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func check(_ cancelled: () -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !value && cancelled() { value = true }
        return value
    }
}

/// One-second black H.264 clip stretched under image clips, so a single video
/// track carries both kinds and the frame handler swaps in the picture.
enum PlaceholderVideo {
    private static let lock = NSLock()

    static func url() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pam-media-editor-placeholder-v1.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let staged = url.deletingLastPathComponent().appendingPathComponent(".placeholder-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: staged, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw EditorFailure(EditorFailure.exportFailed, "Cannot create placeholder video") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0...30 {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                throw EditorFailure(EditorFailure.exportFailed, "Cannot create placeholder frame")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, 0, CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw EditorFailure(EditorFailure.exportFailed, "Cannot create placeholder video") }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: staged, to: url)
        return url
    }
}
