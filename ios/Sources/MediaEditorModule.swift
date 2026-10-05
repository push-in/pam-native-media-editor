import AVFoundation
import Foundation
import PamNative

/// PAM module `media-editor` on iOS: timeline export (video and image clips,
/// range, per-clip audio, soundtrack, grade, timed overlays) with pushed
/// progress, typed failures and the output probe (Android 0.1.1 parity).
public final class MediaEditorModule: NativeModule, ClosableNativeModule, @unchecked Sendable {
    private let root: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pam-files", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }()
    private let work: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "pam-media-editor"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let lock = NSLock()
    private var jobs: [Int64: ExportJob] = [:]

    public init() {}

    public func invoke(method: String, payload: Data, completion: @escaping ModuleCompletion) {
        do {
            let values = try WireMap.decode(payload)
            switch method {
            case "export":
                let id = try values.integer("jobId")
                let job = ExportJob(id: id, path: try values.text("destination"), completion: completion)
                lock.lock()
                let duplicate = jobs[id] != nil
                if !duplicate { jobs[id] = job }
                lock.unlock()
                guard !duplicate else { throw EditorFailure(EditorFailure.unknown, "Export job already exists") }
                work.addOperation { [weak self] in self?.runExport(job, values) }
            case "observe":
                try job(values.integer("jobId")).observe(completion)
            case "status":
                completion(.success, try job(values.integer("jobId")).encodedSnapshot())
            case "cancel":
                let job = try job(values.integer("jobId"))
                job.finishFailure(EditorFailure(EditorFailure.cancelled, "Export cancelled"), state: ExportJob.cancelledState)
                completion(.success, job.encodedSnapshot())
            case "probe":
                let timeline = try values.text("timeline")
                work.addOperation { [weak self] in
                    guard let self else { return }
                    do {
                        completion(.success, try WireMap.encode(try self.probe(Self.parse(timeline))))
                    } catch {
                        completion(.success, (try? WireMap.encode([
                            "failure": .integer(EditorFailure.code(of: error)),
                            "message": .text(error.localizedDescription),
                        ])) ?? Data())
                    }
                }
            default:
                throw EditorFailure(EditorFailure.unknown, "Unknown media editor method: \(method)")
            }
        } catch {
            completion(.failure, Data(error.localizedDescription.utf8))
        }
    }

    public func close() {
        lock.lock()
        let all = Array(jobs.values)
        lock.unlock()
        all.forEach { $0.finishFailure(EditorFailure(EditorFailure.cancelled, "Media editor closed"), state: ExportJob.cancelledState) }
        work.cancelAllOperations()
    }

    private func job(_ id: Int64) throws -> ExportJob {
        lock.lock()
        defer { lock.unlock() }
        guard let job = jobs[id] else { throw EditorFailure(EditorFailure.unknown, "Unknown export job") }
        return job
    }

    static func parse(_ json: String) throws -> [String: Any] {
        guard let timeline = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw EditorFailure(EditorFailure.unknown, "Invalid timeline")
        }
        return timeline
    }

    private func probe(_ timeline: [String: Any]) throws -> [String: WireValue] {
        let clips = try ResolvedClip.resolve(timeline, strict: false) { try file($0, mustExist: true) }
        let durations = clips.map(\.planned.timelineDurationMs)
        let data = try JSONSerialization.data(withJSONObject: durations)
        return [
            "durationMillis": .integer(TimelinePlanning.totalMs(clips.map(\.planned))),
            "clipDurations": .text(String(decoding: data, as: UTF8.self)),
            "width": .integer(clips.map(\.media.width).max() ?? 0),
            "height": .integer(clips.map(\.media.height).max() ?? 0),
            "hasAudio": .flag(clips.contains { !$0.image && $0.media.hasAudio && !$0.removeAudio }),
            "rotationDegrees": .integer(clips.count == 1 ? clips[0].media.rotation : 0),
        ]
    }

    private func runExport(_ job: ExportJob, _ values: [String: WireValue]) {
        do {
            let timeline = try Self.parse(try values.text("timeline"))
            let clips = try ResolvedClip.resolve(timeline, strict: true) { try file($0, mustExist: true) }
            if TimelinePlanning.totalMs(clips.map(\.planned)) <= 0 {
                throw EditorFailure(EditorFailure.invalidDuration, "Timeline has no valid duration")
            }
            let segments = TimelinePlanning.segments(
                clips.map(\.planned),
                startMs: (timeline["rangeStartMillis"] as? NSNumber)?.int64Value ?? 0,
                endMs: (timeline["rangeEndMillis"] as? NSNumber)?.int64Value
            )
            guard !segments.isEmpty else {
                throw EditorFailure(EditorFailure.emptyRange, "The timeline range contains no exportable clips")
            }
            let soundtrack = try (timeline["soundtrack"] as? String).flatMap { $0.isEmpty ? nil : try file($0, mustExist: true) }
            let destination = try file(job.path, mustExist: false)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                do {
                    try FileManager.default.removeItem(at: destination)
                } catch {
                    throw EditorFailure(EditorFailure.outputMissing, "Cannot replace export destination")
                }
            }
            let adjustments = timeline["adjustments"] as? [String: Any] ?? [:]
            let overlay = EditorOverlay.create(
                timeline["overlays"] as? [[String: Any]] ?? [],
                grain: (adjustments["grain"] as? NSNumber)?.doubleValue ?? 0,
                vignette: (adjustments["vignette"] as? NSNumber)?.doubleValue ?? 0
            ) { try file($0, mustExist: true) }
            job.output = destination
            job.start()
            let timeout = (try? values.integer("timeoutMillis")) ?? 0
            if timeout > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(timeout))) {
                    job.finishFailure(EditorFailure(EditorFailure.timedOut, "Export timed out"))
                }
            }
            try EditorExporter().export(
                timeline: timeline,
                clips: clips,
                segments: segments,
                soundtrack: soundtrack,
                destination: destination,
                settings: EditorExporter.Settings(
                    width: Int((try? values.integer("width")) ?? 0),
                    height: Int((try? values.integer("height")) ?? 0),
                    frameRate: Int((try? values.integer("frameRate")) ?? 30),
                    videoBitRate: Int((try? values.integer("videoBitRate")) ?? 0),
                    hevc: ((try? values.integer("videoCodec")) ?? 1) == 2
                ),
                overlay: overlay,
                cancelled: { job.isTerminal },
                progress: { job.progress($0) }
            )
            guard !job.isTerminal else { return }
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0 else { throw EditorFailure(EditorFailure.outputMissing, "The exported file was not written") }
            let output = try MediaProbe.video(destination)
            job.finishSuccess([
                "bytes": .integer(Int64(size)),
                "durationMillis": .integer(output.durationMs),
                "width": .integer(output.width),
                "height": .integer(output.height),
                "hasAudio": .flag(output.hasAudio),
                "rotationDegrees": .integer(output.rotation),
            ])
        } catch {
            job.finishFailure(error)
        }
    }

    private func file(_ path: String, mustExist: Bool) throws -> URL {
        guard !path.isEmpty, path.utf8.count <= 1_024, !path.contains("\0"), !path.hasPrefix("/"), !path.contains("://"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw EditorFailure(EditorFailure.unreadableSource, "Media paths must be relative sandbox paths")
        }
        let target = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard target.path.hasPrefix(root.path + "/") else {
            throw EditorFailure(EditorFailure.unreadableSource, "Media path escapes app files")
        }
        if mustExist && !FileManager.default.fileExists(atPath: target.path) {
            throw EditorFailure(EditorFailure.unreadableSource, "Media source does not exist")
        }
        return target
    }
}

/// One export: pushes progress to a single `observe` long-poll and completes
/// `export` exactly once with the terminal snapshot.
final class ExportJob: @unchecked Sendable {
    static let queuedState: Int64 = 1
    static let exportingState: Int64 = 2
    static let completedState: Int64 = 3
    static let cancelledState: Int64 = 4
    static let failedState: Int64 = 5

    let id: Int64
    let path: String
    var output: URL?
    private let lock = NSLock()
    private var exportCompletion: ModuleCompletion?
    private var state = queuedState
    private var progressValue = 0
    private var message = ""
    private var failure: Int64 = 0
    private var terminal: [String: WireValue]?
    private var waiter: ModuleCompletion?
    private var observed = true

    init(id: Int64, path: String, completion: @escaping ModuleCompletion) {
        self.id = id
        self.path = path
        exportCompletion = completion
    }

    var isTerminal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminal != nil
    }

    func start() {
        lock.lock()
        if terminal == nil { state = Self.exportingState }
        lock.unlock()
    }

    func progress(_ percent: Int) {
        lock.lock()
        let value = min(max(percent, 0), 99)
        guard terminal == nil, value != progressValue else {
            lock.unlock()
            return
        }
        progressValue = value
        observed = false
        let current = waiter
        if current != nil {
            waiter = nil
            observed = true
        }
        let payload = snapshotLocked()
        lock.unlock()
        current?(.success, encode(payload))
    }

    func observe(_ completion: @escaping ModuleCompletion) {
        lock.lock()
        if let terminal {
            lock.unlock()
            completion(.success, encode(terminal))
            return
        }
        if !observed {
            observed = true
            let payload = snapshotLocked()
            lock.unlock()
            completion(.success, encode(payload))
            return
        }
        guard waiter == nil else {
            lock.unlock()
            completion(.failure, Data("Export observation already pending".utf8))
            return
        }
        waiter = completion
        lock.unlock()
    }

    func finishSuccess(_ extra: [String: WireValue]) {
        finish(Self.completedState, progress: 100, message: "", code: 0, extra: extra)
    }

    func finishFailure(_ error: Error, state terminalState: Int64 = failedState) {
        let code = terminalState == Self.cancelledState ? EditorFailure.cancelled : EditorFailure.code(of: error)
        finish(terminalState, progress: nil, message: error.localizedDescription, code: code, extra: [:])
    }

    private func finish(_ newState: Int64, progress: Int?, message newMessage: String, code: Int64, extra: [String: WireValue]) {
        lock.lock()
        guard terminal == nil else {
            lock.unlock()
            return
        }
        state = newState
        if let progress { progressValue = progress }
        message = newMessage
        failure = code
        var payload = snapshotLocked()
        payload.merge(extra) { $1 }
        terminal = payload
        let completions = [exportCompletion, waiter].compactMap { $0 }
        exportCompletion = nil
        waiter = nil
        lock.unlock()
        if newState != Self.completedState, let output {
            // The writer removes partial output on cancel; this covers failures.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { try? FileManager.default.removeItem(at: output) }
        }
        completions.forEach { $0(.success, encode(payload)) }
    }

    func encodedSnapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return encode(terminal ?? snapshotLocked())
    }

    private func snapshotLocked() -> [String: WireValue] {
        var values: [String: WireValue] = [
            "jobId": .integer(id),
            "state": .integer(state),
            "progress": .integer(Int64(progressValue)),
            "path": .text(path),
            "message": .text(message),
        ]
        if failure != 0 { values["failure"] = .integer(failure) }
        return values
    }

    private func encode(_ values: [String: WireValue]) -> Data {
        (try? WireMap.encode(values)) ?? Data()
    }
}

private extension Dictionary where Key == String, Value == WireValue {
    func text(_ key: String) throws -> String {
        guard case let .text(value)? = self[key] else { throw EditorFailure(EditorFailure.unknown, "\(key) is required") }
        return value
    }

    func integer(_ key: String) throws -> Int64 {
        guard case let .integer(value)? = self[key] else { throw EditorFailure(EditorFailure.unknown, "\(key) is required") }
        return value
    }
}
