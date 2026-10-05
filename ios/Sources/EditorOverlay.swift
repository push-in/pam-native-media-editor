import CoreImage
import Foundation
import ImageIO
import UIKit

/// Timed text/image (GIF-animated) layers, film grain and vignette composited
/// over every output frame with Core Image (Android TimelineOverlay parity).
/// Positions are normalized with a top-left origin; times are output ms.
final class EditorOverlay: @unchecked Sendable {
    static let kindText = 1
    static let kindImage = 2
    private static let maxImageBytes = 32 * 1_024 * 1_024
    private static let maxImageDimension = 2_048

    private struct Layer {
        let kind: Int
        let x: Double
        let y: Double
        let scale: Double
        let rotationDegrees: Double
        let startMs: Int64
        let endMs: Int64
        /// Text rendered once at its final size; images at source size.
        let frames: [CIImage]
        /// Cumulative frame end times (ms) for animated GIFs.
        let frameEnds: [Int64]
        let width: Double
        let maxWidth: Double
        let minWidthPixels: Double
    }

    private let layers: [Layer]
    private let grain: Double
    private let vignette: Double

    var hasContent: Bool { !layers.isEmpty || grain > 0.001 || vignette > 0.001 }

    private init(layers: [Layer], grain: Double, vignette: Double) {
        self.layers = layers
        self.grain = grain
        self.vignette = vignette
    }

    /// Parses overlays and loads images (blocking: call off the main thread).
    static func create(_ overlays: [[String: Any]], grain: Double, vignette: Double, resolve: (String) throws -> URL) -> EditorOverlay {
        EditorOverlay(
            layers: overlays.compactMap { parse($0, resolve: resolve) },
            grain: min(max(grain, 0), 1),
            vignette: min(max(vignette, 0), 1)
        )
    }

    private static func parse(_ item: [String: Any], resolve: (String) throws -> URL) -> Layer? {
        func number(_ key: String, _ fallback: Double) -> Double { (item[key] as? NSNumber)?.doubleValue ?? fallback }
        let kind = (item["kind"] as? NSNumber)?.intValue ?? kindText
        let start = (item["startMillis"] as? NSNumber)?.int64Value ?? 0
        let end = (item["endMillis"] as? NSNumber)?.int64Value ?? .max
        let x = min(max(number("x", 0.5), 0), 1)
        let y = min(max(number("y", 0.5), 0), 1)
        let scale = min(max(number("scale", 1), 0.25), 4)
        let rotation = number("rotationDegrees", 0)
        if kind == kindImage {
            guard let source = item["source"] as? String, let data = readBytes(source, resolve: resolve),
                  let decoded = decode(data) else { return nil }
            return Layer(
                kind: kindImage, x: x, y: y, scale: scale, rotationDegrees: rotation, startMs: start, endMs: end,
                frames: decoded.frames, frameEnds: decoded.ends,
                width: min(max(number("width", 0.34), 0.01), 1),
                maxWidth: min(max(number("maxWidth", 0.72), 0.01), 1),
                minWidthPixels: min(max(number("minWidthPixels", 96), 0), 8_192)
            )
        }
        guard let text = (item["text"] as? String).map({ String($0.prefix(500)) }), !text.isEmpty,
              let rendered = renderText(
                text,
                color: OverlayMath.parseColor(item["color"] as? String) ?? (1, 1, 1, 1),
                fontSize: min(max(number("fontSize", 48), 4), 512) * scale,
                background: OverlayMath.parseColor(item["backgroundColor"] as? String),
                bold: (item["bold"] as? Bool) ?? true,
                scale: scale
              ) else { return nil }
        return Layer(
            kind: kindText, x: x, y: y, scale: scale, rotationDegrees: rotation, startMs: start, endMs: end,
            frames: [rendered], frameEnds: [], width: 0, maxWidth: 0, minWidthPixels: 0
        )
    }

    func composite(over base: CIImage, size: CGSize, timeMs: Int64) -> CIImage {
        guard hasContent else { return base }
        var image = base
        for layer in layers where OverlayMath.visible(timeMs, start: layer.startMs, end: layer.endMs) {
            guard var picture = frame(layer, timeMs: timeMs) else { continue }
            if layer.kind == Self.kindImage {
                let target = OverlayMath.mediaWidth(
                    canvasWidth: Double(size.width), scale: layer.scale, width: layer.width,
                    maxWidth: layer.maxWidth, minWidthPixels: layer.minWidthPixels
                )
                let factor = target / Double(max(picture.extent.width, 1))
                picture = picture.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            }
            // Centre on the origin, rotate clockwise (CoreImage is y-up), then place.
            picture = picture.transformed(by: CGAffineTransform(
                translationX: -picture.extent.midX,
                y: -picture.extent.midY
            ))
            picture = picture.transformed(by: CGAffineTransform(rotationAngle: -layer.rotationDegrees * .pi / 180))
            picture = picture.transformed(by: CGAffineTransform(
                translationX: layer.x * size.width,
                y: (1 - layer.y) * size.height
            ))
            image = picture.composited(over: image)
        }
        if grain > 0.001 {
            let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?
                .transformed(by: CGAffineTransform(translationX: CGFloat(timeMs / 42 % 512), y: CGFloat(timeMs / 42 % 377)))
                .cropped(to: CGRect(origin: .zero, size: size))
            if let noise {
                let alpha = grain * 46 / 255
                let speckles = noise.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    // Only the brightest ~3% of noise pixels become visible white specks.
                    "inputAVector": CIVector(x: alpha * 30, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: -alpha * 29),
                ]).applyingFilter("CIColorClamp")
                image = speckles.composited(over: image)
            }
        }
        if vignette > 0.001 {
            let radius = Double(max(size.width, size.height)) * 0.72
            let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: size.width / 2, y: size.height / 2),
                "inputRadius0": radius * 0.52,
                "inputRadius1": radius,
                "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: vignette * 210 / 255),
            ])?.outputImage?.cropped(to: CGRect(origin: .zero, size: size))
            if let gradient { image = gradient.composited(over: image) }
        }
        return image
    }

    private func frame(_ layer: Layer, timeMs: Int64) -> CIImage? {
        guard layer.frames.count > 1, let total = layer.frameEnds.last, total > 0 else { return layer.frames.first }
        let position = (timeMs - max(layer.startMs, 0)) % total
        let index = layer.frameEnds.firstIndex { position < $0 } ?? 0
        return layer.frames[index]
    }

    private static func readBytes(_ source: String, resolve: (String) throws -> URL) -> Data? {
        if source.hasPrefix("https://") {
            guard let url = URL(string: source) else { return nil }
            let done = DispatchSemaphore(value: 0)
            let box = DataBox()
            URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 18)) { data, response, _ in
                if let data, data.count <= maxImageBytes, (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) {
                    box.set(data)
                }
                done.signal()
            }.resume()
            _ = done.wait(timeout: .now() + 30)
            return box.get()
        }
        guard let url = try? resolve(source), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              (1...maxImageBytes).contains(size) else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func decode(_ data: Data) -> (frames: [CIImage], ends: [Int64])? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImageDimension,
        ]
        let count = OverlayMath.isGif(data) ? min(CGImageSourceGetCount(source), 300) : 1
        var frames: [CIImage] = []
        var ends: [Int64] = []
        var cursor: Int64 = 0
        for index in 0..<count {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { continue }
            frames.append(CIImage(cgImage: image))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.1
            cursor += Int64(max(delay, 0.02) * 1_000)
            ends.append(cursor)
        }
        return frames.isEmpty ? nil : (frames, ends)
    }

    private static func renderText(
        _ text: String,
        color: (Double, Double, Double, Double),
        fontSize: Double,
        background: (Double, Double, Double, Double)?,
        bold: Bool,
        scale: Double
    ) -> CIImage? {
        let font = bold ? UIFont.boldSystemFont(ofSize: fontSize) : UIFont.systemFont(ofSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(red: color.1, green: color.2, blue: color.3, alpha: color.0),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let padding = background == nil ? 0 : 20 * scale
        let size = CGSize(width: ceil(textSize.width + padding * 2), height: ceil(textSize.height + padding))
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            if let background {
                UIColor(red: background.1, green: background.2, blue: background.3, alpha: background.0).setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 14).fill()
            }
            string.draw(at: CGPoint(x: padding, y: padding / 2))
        }
        return rendered.cgImage.map { CIImage(cgImage: $0) }
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func set(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func get() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
