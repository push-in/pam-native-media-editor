import AVFoundation
import CoreGraphics
import ImageIO
import PamNative
import UniformTypeIdentifiers
import XCTest
// Generated plugin target: PamPlugin<index>PushinbrPamNativeMediaEditor (index = plugin order).
@testable import PamPlugin0PushinbrPamNativeMediaEditor

/// XCTest mirror of TimelinePlanningTest + the Android export tests.
/// Uncompiled — needs Mac validation.
final class MediaEditorTests: XCTestCase {
    private let module = MediaEditorModule()
    private let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("pam-files/editor-tests")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testPlanningMatchesAndroid() {
        let photo = PlannedClip(timelineDurationMs: 5_000, image: true)
        let video = PlannedClip(timelineDurationMs: 8_000)
        XCTAssertEqual(TimelinePlanning.segments([photo, video], startMs: 2_000, endMs: 9_000), [
            ClipSegment(index: 0, sourceStartMs: 0, sourceEndMs: 3_000, image: true),
            ClipSegment(index: 1, sourceStartMs: 0, sourceEndMs: 4_000, image: false),
        ])
        XCTAssertEqual(TimelinePlanning.segments([photo, video], startMs: 4_970, endMs: 7_000), [
            ClipSegment(index: 1, sourceStartMs: 0, sourceEndMs: 2_000, image: false),
        ])
        let graded = ColorGrade.from(brightness: 0.2, contrast: 0, saturation: -1, temperature: 0.5, fade: 0)
        XCTAssertEqual(graded.saturationPercent, -100)
        XCTAssertEqual(graded.redScale, 1.07, accuracy: 1e-9)
        XCTAssertEqual(OverlayMath.mediaWidth(canvasWidth: 1_080, scale: 1, width: 0.34, maxWidth: 0.72, minWidthPixels: 96), 367.2, accuracy: 1e-3)
        XCTAssertTrue(OverlayMath.isGif(Data("GIF89a".utf8)))
    }

    private func call(_ method: String, _ values: [String: WireValue], timeout: TimeInterval = 60) -> [String: WireValue] {
        let done = expectation(description: method)
        var result: [String: WireValue] = [:]
        module.invoke(method: method, payload: (try? WireMap.encode(values)) ?? Data()) { _, payload in
            result = (try? WireMap.decode(payload)) ?? [:]
            done.fulfill()
        }
        wait(for: [done], timeout: timeout)
        return result
    }

    private func makeVideo(_ name: String, seconds: Int) throws {
        let writer = try AVAssetWriter(outputURL: root.appendingPathComponent(name), fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        let done = expectation(description: "video")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 20)
    }

    private func makePng(_ name: String) {
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
    }

    func testMixedTimelineExportsWithOverlaysAndProbe() throws {
        try makeVideo("clip.mp4", seconds: 2)
        makePng("photo.png")
        let timeline = #"""
        {"clips":[{"source":"editor-tests/photo.png","imageDurationMillis":1000},
                  {"source":"editor-tests/clip.mp4","startMillis":0,"endMillis":2000,"speed":2,"filter":3,"removeAudio":true}],
         "adjustments":{"brightness":0.1,"saturation":-0.5,"grain":0.4,"vignette":0.5},
         "overlays":[{"kind":1,"text":"Olá","x":0.5,"y":0.2,"color":"#FFFFFF","backgroundColor":"#80000000","startMillis":0,"endMillis":1500}]}
        """#
        let probe = call("probe", ["timeline": .text(timeline)])
        XCTAssertEqual(probe["durationMillis"], .integer(2_000))
        XCTAssertEqual(probe["hasAudio"], .flag(false))
        let observe = expectation(description: "observe")
        observe.assertForOverFulfill = false
        let done = call("export", [
            "jobId": .integer(1), "destination": .text("editor-tests/out.mp4"), "timeline": .text(timeline),
            "width": .integer(640), "height": .integer(360), "frameRate": .integer(30), "videoBitRate": .integer(1_000_000),
            "videoCodec": .integer(1), "timeoutMillis": .integer(0),
        ])
        observe.fulfill()
        XCTAssertEqual(done["state"], .integer(3), "\(done)")
        XCTAssertEqual(done["width"], .integer(640))
        XCTAssertEqual(done["height"], .integer(360))
        if case let .integer(duration)? = done["durationMillis"] { XCTAssertEqual(Double(duration), 2_000, accuracy: 100) }
        let status = call("status", ["jobId": .integer(1)])
        XCTAssertEqual(status["progress"], .integer(100))
    }

    func testEmptyRangeAndMissingSourcesFailWithTypedCodes() {
        let missing = call("probe", ["timeline": .text(#"{"clips":[{"source":"editor-tests/none.mp4"}]}"#)])
        XCTAssertEqual(missing["failure"], .integer(EditorFailure.unreadableSource))
        let export = call("export", [
            "jobId": .integer(2), "destination": .text("editor-tests/x.mp4"),
            "timeline": .text(#"{"clips":[{"source":"../escape.mp4"}]}"#), "frameRate": .integer(30),
        ])
        XCTAssertEqual(export["state"], .integer(5))
        XCTAssertEqual(export["failure"], .integer(EditorFailure.unreadableSource))
    }
}
