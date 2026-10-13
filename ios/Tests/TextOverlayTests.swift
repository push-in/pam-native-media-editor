import CoreImage
import XCTest
@testable import PamPlugin0PushinbrPamNativeMediaEditor

/// Source ready; execution requires the generated Xcode host on a Mac.
final class TextOverlayTests: XCTestCase {
    private enum OverlayKind: Int { case text = 1, image = 2 }
    private func bounds(width: Int, maxLines: Int = 8, rotation: Int = 0) throws -> CGRect {
        let overlay = EditorOverlay.create([[
            "kind": OverlayKind.text.rawValue, "text": "PAM_QA_VIDEO_EXPORT long words across narrow video",
            "fontSize": 38, "color": "#FFFFFF", "x": 0.5, "y": 0.5,
            "maxWidth": 0.78, "referenceWidth": 720, "maxLines": maxLines,
            "rotationDegrees": rotation,
        ]], grain: 0, vignette: 0) { URL(fileURLWithPath: $0) }
        let size = CGSize(width: width, height: width * 2)
        let base = CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: size))
        let result = overlay.composite(over: base, size: size, timeMs: 0)
        var pixels = [UInt8](repeating: 0, count: width * width * 2 * 4)
        let context = CIContext(options: [.cacheIntermediates: false])
        pixels.withUnsafeMutableBytes { bytes in
            context.render(result, toBitmap: bytes.baseAddress!, rowBytes: width * 4,
                bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        var left = width; var right = -1; var top = width * 2; var bottom = -1
        for y in 0..<(width * 2) { for x in 0..<width {
            if pixels[(y * width + x) * 4 + 3] > 20 {
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
            }
        }}
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }
    func testNarrowWrappedTextIsBoundedCenteredAndTruncated() throws {
        let full = try bounds(width: 270)
        let one = try bounds(width: 270, maxLines: 1)
        let large = try bounds(width: 540)
        let rotated = try bounds(width: 270, rotation: 30)
        XCTAssertGreaterThan(full.minX, 20)
        XCTAssertLessThan(full.maxX, 250)
        XCTAssertEqual(full.midX, 135, accuracy: 8)
        XCTAssertGreaterThan(full.height, one.height)
        XCTAssertGreaterThan(large.height, full.height * 1.5)
        XCTAssertGreaterThan(rotated.width, 0)
        XCTAssertLessThan(rotated.maxX, 270)
    }
}
