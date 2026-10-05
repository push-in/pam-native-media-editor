import Foundation

// Pure timeline, color and overlay math (port of TimelinePlanning.kt), unit
// tested without AVFoundation.

struct EditorFailure: LocalizedError {
    static let unknown: Int64 = 1
    static let unreadableSource: Int64 = 2
    static let invalidDuration: Int64 = 3
    static let emptyRange: Int64 = 4
    static let exportFailed: Int64 = 5
    static let timedOut: Int64 = 6
    static let cancelled: Int64 = 7
    static let outputMissing: Int64 = 8

    let code: Int64
    let message: String

    init(_ code: Int64, _ message: String) {
        self.code = code
        self.message = message
    }

    var errorDescription: String? { message }

    static func code(of error: Error) -> Int64 { (error as? EditorFailure)?.code ?? unknown }
}

/// A clip as it sits on the timeline: output duration and source start.
struct PlannedClip: Equatable {
    var timelineDurationMs: Int64
    var sourceStartMs: Int64 = 0
    var speed: Double = 1
    var image = false
}

/// The part of clip [index] inside the exported range, in source milliseconds.
struct ClipSegment: Equatable {
    let index: Int
    let sourceStartMs: Int64
    let sourceEndMs: Int64
    let image: Bool

    var durationMs: Int64 { sourceEndMs - sourceStartMs }
}

enum TimelinePlanning {
    /// Slivers shorter than this at the range edges are dropped.
    static let minSegmentMs: Int64 = 60

    static func totalMs(_ clips: [PlannedClip]) -> Int64 {
        clips.reduce(0) { $0 + max($1.timelineDurationMs, 0) }
    }

    /// Null end (or <= 0) means the timeline end.
    static func range(totalMs: Int64, startMs: Int64, endMs: Int64?) -> (Int64, Int64) {
        let start = max(startMs, 0)
        let end = min((endMs.flatMap { $0 > 0 ? $0 : nil }) ?? totalMs, totalMs)
        return (start, end)
    }

    static func segments(_ clips: [PlannedClip], startMs: Int64, endMs: Int64?) -> [ClipSegment] {
        let (rangeStart, rangeEnd) = range(totalMs: totalMs(clips), startMs: startMs, endMs: endMs)
        guard rangeEnd > rangeStart else { return [] }
        var cursor: Int64 = 0
        var result: [ClipSegment] = []
        for (index, clip) in clips.enumerated() {
            let clipStart = cursor
            let clipEnd = clipStart + max(clip.timelineDurationMs, 0)
            cursor = clipEnd
            let overlapStart = max(rangeStart, clipStart)
            let overlapEnd = min(rangeEnd, clipEnd)
            guard overlapEnd - overlapStart >= minSegmentMs else { continue }
            let localStart = overlapStart - clipStart
            let localEnd = overlapEnd - clipStart
            if clip.image {
                result.append(ClipSegment(index: index, sourceStartMs: 0, sourceEndMs: localEnd - localStart, image: true))
            } else {
                result.append(ClipSegment(
                    index: index,
                    sourceStartMs: clip.sourceStartMs + Int64(Double(localStart) * clip.speed),
                    sourceEndMs: clip.sourceStartMs + Int64(Double(localEnd) * clip.speed),
                    image: false
                ))
            }
        }
        return result
    }
}

/// Effective parameters of a [brightness, contrast, saturation, temperature, fade] grade.
struct ColorGrade: Equatable {
    static let epsilon = 0.001

    let brightness: Double
    let contrast: Double
    let saturationPercent: Double
    let redScale: Double
    let blueScale: Double

    var hasBrightness: Bool { abs(brightness) > Self.epsilon }
    var hasContrast: Bool { abs(contrast) > Self.epsilon }
    var hasSaturation: Bool { saturationPercent != 0 }
    var hasTemperature: Bool { redScale != 1 || blueScale != 1 }
    var isIdentity: Bool { !hasBrightness && !hasContrast && !hasSaturation && !hasTemperature }

    /// Media3 `Contrast(c)` scales around mid-grey by (1 + c) / (1 - c).
    var contrastFactor: Double { (1 + contrast) / (1 - contrast) }

    static func from(brightness: Double, contrast: Double, saturation: Double, temperature: Double, fade: Double) -> ColorGrade {
        let fadeAmount = min(max(fade, 0), 1)
        let warmth = abs(temperature) > epsilon ? min(max(temperature, -1), 1) * 0.14 : 0
        return ColorGrade(
            brightness: min(max(brightness - fadeAmount * 0.16, -1), 1),
            contrast: min(max(contrast - fadeAmount * 0.18, -0.95), 0.95),
            saturationPercent: abs(saturation) > epsilon ? min(max(saturation * 100, -100), 100) : 0,
            redScale: max(1 + warmth, 0),
            blueScale: max(1 - warmth, 0)
        )
    }
}

enum OverlayMath {
    static func visible(_ timeMs: Int64, start: Int64, end: Int64) -> Bool { timeMs >= start && timeMs <= end }

    /// Parses #RRGGBB / #AARRGGBB into (a, r, g, b) components 0...1, or nil.
    static func parseColor(_ value: String?) -> (Double, Double, Double, Double)? {
        guard let value, value.hasPrefix("#") else { return nil }
        let hex = String(value.dropFirst())
        guard hex.count == 6 || hex.count == 8, let parsed = UInt64(hex, radix: 16) else { return nil }
        let argb = hex.count == 6 ? (0xFF00_0000 | parsed) : parsed
        return (
            Double((argb >> 24) & 0xFF) / 255,
            Double((argb >> 16) & 0xFF) / 255,
            Double((argb >> 8) & 0xFF) / 255,
            Double(argb & 0xFF) / 255
        )
    }

    static func mediaWidth(canvasWidth: Double, scale: Double, width: Double, maxWidth: Double, minWidthPixels: Double) -> Double {
        min(canvasWidth * maxWidth, max(minWidthPixels, canvasWidth * width * scale))
    }

    static func grainPoints(canvasWidth: Int, canvasHeight: Int, strength: Double) -> Int {
        min(max(Int(Double(canvasWidth * canvasHeight) / 3_600 * strength), 24), 520)
    }

    static func isGif(_ bytes: Data) -> Bool {
        bytes.count >= 6 && bytes.prefix(4) == Data("GIF8".utf8)
    }
}
