import AVFoundation
import CoreImage
import Foundation
import PamNative

public final class MediaEditorModule: NativeModule, @unchecked Sendable {
    private let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].standardizedFileURL
    private let queue = DispatchQueue(label: "dev.pam.media-editor", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var jobs: [Int64: ExportJob] = [:]

    public init() {}

    public func invoke(method: String, payload: Data, completion: @escaping ModuleCompletion) {
        do {
            let values = try WireMap.decode(payload)
            queue.async { [self] in
                do {
                    switch method {
                    case "export": try startExport(values, completion)
                    case "status": try status(values.integer("jobId"), completion)
                    case "cancel": try cancel(values.integer("jobId"), completion)
                    default: throw EditorError.invalidRequest
                    }
                } catch {
                    completion(.failure, Data(error.localizedDescription.utf8))
                }
            }
        } catch {
            completion(.failure, Data(error.localizedDescription.utf8))
        }
    }

    private func startExport(_ values: [String: WireValue], _ completion: @escaping ModuleCompletion) throws {
        let jobID = try values.integer("jobId")
        guard jobs[jobID] == nil else { throw EditorError.duplicateJob }
        let destinationPath = try values.text("destination")
        let destination = try file(destinationPath, mustExist: false)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        guard let timelineData = try values.text("timeline").data(using: .utf8),
              let timeline = try JSONSerialization.jsonObject(with: timelineData) as? [String: Any],
              let clips = timeline["clips"] as? [[String: Any]],
              clips.count >= 1, clips.count <= 128 else { throw EditorError.invalidTimeline }

        let built = try buildComposition(clips: clips, timeline: timeline, values: values)
        let preset = try values.integer("videoCodec") == 2 ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let exporter = AVAssetExportSession(asset: built.composition, presetName: preset) else { throw EditorError.exportUnavailable }
        exporter.outputURL = destination
        exporter.outputFileType = destination.pathExtension.lowercased() == "mov" ? .mov : .mp4
        exporter.shouldOptimizeForNetworkUse = true
        exporter.videoComposition = built.videoComposition
        exporter.audioMix = built.audioMix
        let job = ExportJob(exporter: exporter, path: destinationPath, completion: completion)
        jobs[jobID] = job
        exporter.exportAsynchronously { [weak self, weak job] in
            guard let self, let job else { return }
            queue.async {
                switch exporter.status {
                case .completed:
                    job.state = 3; job.progress = 100
                    completion(.success, self.encodedResult(jobID, job))
                case .cancelled:
                    job.state = 4
                    completion(.success, self.encodedResult(jobID, job))
                default:
                    job.state = 5; job.message = exporter.error?.localizedDescription ?? "Media export failed"
                    completion(.failure, Data(job.message.utf8))
                }
            }
        }
    }

    private func buildComposition(clips: [[String: Any]], timeline: [String: Any], values: [String: WireValue]) throws -> BuiltComposition {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw EditorError.composition }
        var cursor = CMTime.zero
        var edits: [VisualEdit] = []
        let audioParameters = AVMutableAudioMixInputParameters(track: audioTrack)

        for clip in clips {
            guard let sourcePath = clip["source"] as? String else { throw EditorError.invalidTimeline }
            let asset = AVURLAsset(url: try file(sourcePath, mustExist: true))
            let sourceStart = CMTime(value: Int64(clip["startMillis"] as? Int ?? 0), timescale: 1_000)
            let sourceEnd: CMTime
            if let end = clip["endMillis"] as? Int { sourceEnd = CMTime(value: Int64(end), timescale: 1_000) }
            else { sourceEnd = asset.duration }
            let speed = max(0.25, min(4, clip["speed"] as? Double ?? 1))
            let sourceRange = CMTimeRange(start: sourceStart, end: sourceEnd)
            let outputDuration = CMTimeMultiplyByFloat64(sourceRange.duration, multiplier: 1 / speed)
            let outputRange = CMTimeRange(start: cursor, duration: outputDuration)
            if let sourceVideo = asset.tracks(withMediaType: .video).first {
                try videoTrack.insertTimeRange(sourceRange, of: sourceVideo, at: cursor)
                videoTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: sourceRange.duration), toDuration: outputDuration)
                edits.append(VisualEdit(range: outputRange, crop: crop(clip["crop"]), rotation: clip["rotationDegrees"] as? Int ?? 0, filter: clip["filter"] as? Int ?? 1))
            }
            if let sourceAudio = asset.tracks(withMediaType: .audio).first {
                try audioTrack.insertTimeRange(sourceRange, of: sourceAudio, at: cursor)
                audioTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: sourceRange.duration), toDuration: outputDuration)
                audioParameters.setVolume(Float(max(0, min(1, clip["volume"] as? Double ?? 1))), at: cursor)
            }
            cursor = CMTimeAdd(cursor, outputDuration)
        }

        var mixParameters: [AVAudioMixInputParameters] = [audioParameters]
        if let soundtrack = timeline["soundtrack"] as? String, !soundtrack.isEmpty,
           let soundtrackTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let asset = AVURLAsset(url: try file(soundtrack, mustExist: true))
            guard let source = asset.tracks(withMediaType: .audio).first else { throw EditorError.invalidSoundtrack }
            var soundtrackCursor = CMTime.zero
            repeat {
                let remaining = CMTimeSubtract(cursor, soundtrackCursor)
                let duration = CMTimeCompare(asset.duration, remaining) < 0 ? asset.duration : remaining
                try soundtrackTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: soundtrackCursor)
                soundtrackCursor = CMTimeAdd(soundtrackCursor, duration)
            } while (timeline["loopSoundtrack"] as? Bool ?? false) && CMTimeCompare(soundtrackCursor, cursor) < 0
            let parameters = AVMutableAudioMixInputParameters(track: soundtrackTrack)
            parameters.setVolume(Float(max(0, min(1, timeline["soundtrackVolume"] as? Double ?? 1))), at: .zero)
            mixParameters.append(parameters)
        }

        let outputSize = CGSize(width: try values.integer("width"), height: try values.integer("height"))
        let filteredComposition = AVVideoComposition(asset: composition) { [ciContext, edits] request in
            let edit = edits.first { CMTimeRangeContainsTime($0.range, time: request.compositionTime) }
            var image = request.sourceImage.clampedToExtent()
            if let edit {
                image = self.apply(edit: edit, to: image)
            }
            let extent = image.extent
            let scale = min(outputSize.width / extent.width, outputSize.height / extent.height)
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let scaled = image.extent
            image = image.transformed(by: CGAffineTransform(translationX: (outputSize.width - scaled.width) / 2 - scaled.minX, y: (outputSize.height - scaled.height) / 2 - scaled.minY))
            request.finish(with: image.cropped(to: CGRect(origin: .zero, size: outputSize)), context: ciContext)
        }
        guard let videoComposition = filteredComposition.mutableCopy() as? AVMutableVideoComposition else { throw EditorError.composition }
        videoComposition.renderSize = outputSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(try values.integer("frameRate")))
        let audioMix = AVMutableAudioMix(); audioMix.inputParameters = mixParameters
        return BuiltComposition(composition: composition, videoComposition: videoComposition, audioMix: audioMix)
    }

    private func apply(edit: VisualEdit, to source: CIImage) -> CIImage {
        var image = source
        if let crop = edit.crop {
            let extent = image.extent
            image = image.cropped(to: CGRect(x: extent.minX + extent.width * crop.x, y: extent.minY + extent.height * (1 - crop.y - crop.height), width: extent.width * crop.width, height: extent.height * crop.height))
        }
        if edit.rotation != 0 {
            let center = CGPoint(x: image.extent.midX, y: image.extent.midY)
            let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: CGFloat(edit.rotation) * .pi / 180).translatedBy(x: -center.x, y: -center.y)
            image = image.transformed(by: transform)
        }
        let name: String? = switch edit.filter {
        case 2: "CIPhotoEffectMono"
        case 3: "CISepiaTone"
        case 4: "CIVibrance"
        default: nil
        }
        if let name, let filter = CIFilter(name: name) {
            filter.setValue(image, forKey: kCIInputImageKey)
            if edit.filter == 3 { filter.setValue(0.9, forKey: kCIInputIntensityKey) }
            if edit.filter == 4 { filter.setValue(0.65, forKey: "inputAmount") }
            image = filter.outputImage ?? image
        }
        return image.cropped(to: image.extent)
    }

    private func status(_ jobID: Int64, _ completion: ModuleCompletion) throws {
        guard let job = jobs[jobID] else { throw EditorError.unknownJob }
        if job.state == 2 { job.progress = Int64(max(0, min(100, Int(job.exporter.progress * 100)))) }
        completion(.success, encodedResult(jobID, job))
    }

    private func cancel(_ jobID: Int64, _ completion: ModuleCompletion) throws {
        guard let job = jobs[jobID] else { throw EditorError.unknownJob }
        job.exporter.cancelExport(); job.state = 4
        completion(.success, encodedResult(jobID, job))
    }

    private func encodedResult(_ jobID: Int64, _ job: ExportJob) -> Data {
        (try? WireMap.encode(["jobId": .integer(jobID), "state": .integer(job.state), "progress": .integer(job.progress), "path": .text(job.path), "message": .text(job.message)])) ?? Data()
    }

    private func file(_ path: String, mustExist: Bool) throws -> URL {
        guard !path.isEmpty, path.utf8.count <= 1_024, !path.contains("\0"), !path.hasPrefix("/"), !path.contains("://") else { throw EditorError.invalidPath }
        let target = root.appendingPathComponent(path).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { throw EditorError.invalidPath }
        if mustExist && !FileManager.default.fileExists(atPath: target.path) { throw EditorError.notFound }
        return target
    }

    private func crop(_ value: Any?) -> CropRect? {
        guard let value = value as? [String: Double], let x = value["x"], let y = value["y"], let width = value["width"], let height = value["height"] else { return nil }
        return CropRect(x: x, y: y, width: width, height: height)
    }
}

private final class ExportJob: @unchecked Sendable {
    let exporter: AVAssetExportSession
    let path: String
    let completion: ModuleCompletion
    var state: Int64 = 2
    var progress: Int64 = 0
    var message = ""
    init(exporter: AVAssetExportSession, path: String, completion: @escaping ModuleCompletion) { self.exporter = exporter; self.path = path; self.completion = completion }
}

private struct BuiltComposition { let composition: AVMutableComposition; let videoComposition: AVMutableVideoComposition; let audioMix: AVMutableAudioMix }
private struct VisualEdit { let range: CMTimeRange; let crop: CropRect?; let rotation: Int; let filter: Int }
private struct CropRect { let x: Double; let y: Double; let width: Double; let height: Double }
private enum EditorError: LocalizedError {
    case invalidRequest, invalidTimeline, invalidPath, notFound, duplicateJob, unknownJob, composition, exportUnavailable, invalidSoundtrack
    var errorDescription: String? { String(describing: self) }
}

private extension Dictionary where Key == String, Value == WireValue {
    func text(_ key: String) throws -> String { guard case let .text(value)? = self[key] else { throw EditorError.invalidRequest }; return value }
    func integer(_ key: String) throws -> Int64 { guard case let .integer(value)? = self[key] else { throw EditorError.invalidRequest }; return value }
}
