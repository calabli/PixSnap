import CoreGraphics
import CoreText
import Foundation
import PixSnapCore

/// 截图翻译's drawing: each paragraph's original text painted over in its own background color,
/// with the translation written in its place, in the original's text color, as large as fits.
public enum TranslationOverlay {
    /// A translation and where its original was: unit coordinates, bottom-left origin.
    public struct Block: Sendable {
        public var box: CGRect
        public var lineHeight: Double
        public var text: String
        /// Written in bold, for a heading.
        public var bold: Bool

        public init(box: CGRect, lineHeight: Double, text: String, bold: Bool = false) {
            self.box = box
            self.lineHeight = lineHeight
            self.text = text
            self.bold = bold
        }
    }

    public static func render(_ image: CGImage, blocks: [Block]) -> CGImage? {
        let width = image.width, height = image.height
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: canvas)
        // Colors are read from the original, before anything is painted over it.
        let original = Pixels(data: UnsafeBufferPointer(start: pixels, count: width * height * 4), width: width, height: height)
        let colors = blocks.map { block -> (background: RGB, text: RGB) in
            let rect = pixelRect(block, width: width, height: height)
            let background = original.mostCommon(inRingAround: rect)
            return (background, original.textColor(in: rect, background: background))
        }

        for (block, color) in zip(blocks, colors) {
            let lineHeight = CGFloat(block.lineHeight) * CGFloat(height)
            let rect = pixelRect(block, width: width, height: height)
            context.setFillColor(cgColor(color.background, space))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: lineHeight * 0.15, cornerHeight: lineHeight * 0.15, transform: nil))
            context.fillPath()
            draw(block.text, in: rect.insetBy(dx: lineHeight * 0.1, dy: 0), lineHeight: lineHeight, bold: block.bold,
                 color: cgColor(color.text, space), context: context)
        }
        return context.makeImage()
    }

    /// The paragraph's box in pixels, with a little room for the letters' edges.
    static func pixelRect(_ block: Block, width: Int, height: Int) -> CGRect {
        let lineHeight = CGFloat(block.lineHeight) * CGFloat(height)
        let rect = CGRect(x: block.box.minX * CGFloat(width), y: block.box.minY * CGFloat(height),
                          width: block.box.width * CGFloat(width), height: block.box.height * CGFloat(height))
        return rect.insetBy(dx: -lineHeight * 0.12, dy: -lineHeight * 0.12).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// `text` wrapped into `rect`, starting at the original lines' size and shrinking until it fits.
    static func draw(_ text: String, in rect: CGRect, lineHeight: CGFloat, bold: Bool, color: CGColor, context: CGContext) {
        guard rect.width > 2, rect.height > 2 else { return }
        var size = lineHeight * 0.8
        let smallest = max(lineHeight * 0.3, 6)
        var framesetter: CTFramesetter
        var fitted: CGSize
        repeat {
            framesetter = CTFramesetterCreateWithAttributedString(attributed(text, size: size, bold: bold, color: color))
            fitted = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil,
                                                                  CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
            if fitted.height <= rect.height { break }
            size *= 0.92
        } while size > smallest
        // Centered top to bottom, like the lines it replaces.
        let top = rect.maxY - max(0, (rect.height - fitted.height) / 2)
        let frameRect = CGRect(x: rect.minX, y: top - max(fitted.height, rect.height), width: rect.width, height: max(fitted.height, rect.height))
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: frameRect, transform: nil), nil)
        context.saveGState()
        context.clip(to: rect.insetBy(dx: -lineHeight * 0.1, dy: 0))
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    static func attributed(_ text: String, size: CGFloat, bold: Bool, color: CGColor) -> CFAttributedString {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let paragraph = [CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size,
                                                 value: withUnsafePointer(to: CTLineBreakMode.byWordWrapping) { UnsafeRawPointer($0) })]
        let style = CTParagraphStyleCreate(paragraph, paragraph.count)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color, kCTParagraphStyleAttributeName: style]
        return CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
    }

    static func cgColor(_ color: RGB, _ space: CGColorSpace) -> CGColor {
        CGColor(colorSpace: space, components: [color.red, color.green, color.blue, 1])!
    }

    /// RGBA pixels with the first row at the bottom, as the context draws them.
    struct Pixels {
        let data: UnsafeBufferPointer<UInt8>
        let width: Int
        let height: Int

        /// The pixel at `x`, `y` (bottom-left origin).
        func color(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = ((height - 1 - y) * width + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
        }

        /// The commonest color along the edge of `rect`, where the background shows between the letters' line and the next.
        func mostCommon(inRingAround rect: CGRect) -> RGB {
            var buckets: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
            let minX = max(Int(rect.minX), 0), maxX = min(Int(rect.maxX) - 1, width - 1)
            let minY = max(Int(rect.minY), 0), maxY = min(Int(rect.maxY) - 1, height - 1)
            guard minX <= maxX, minY <= maxY else { return RGB(1, 1, 1) }
            func add(_ x: Int, _ y: Int) {
                let (r, g, b) = color(x, y)
                let key = (r >> 3) << 10 | (g >> 3) << 5 | b >> 3
                let old = buckets[key] ?? (0, 0, 0, 0)
                buckets[key] = (old.count + 1, old.r + r, old.g + g, old.b + b)
            }
            for x in minX ... maxX { add(x, minY); add(x, maxY) }
            for y in minY ... maxY { add(minX, y); add(maxX, y) }
            let top = buckets.values.max { $0.count < $1.count }!
            return RGB(Double(top.r) / Double(top.count) / 255, Double(top.g) / Double(top.count) / 255, Double(top.b) / Double(top.count) / 255)
        }

        /// The letters' color: the commonest color inside `rect` that stands well apart from the background,
        /// else black or white, whichever shows on it.
        func textColor(in rect: CGRect, background: RGB) -> RGB {
            let bg = (Int(background.red * 255), Int(background.green * 255), Int(background.blue * 255))
            var buckets: [Int: (count: Int, r: Int, g: Int, b: Int, distance: Int)] = [:]
            let minX = max(Int(rect.minX), 0), maxX = min(Int(rect.maxX) - 1, width - 1)
            let minY = max(Int(rect.minY), 0), maxY = min(Int(rect.maxY) - 1, height - 1)
            let fallback = background.luminance > 0.55 ? RGB(0.1, 0.1, 0.1) : RGB(0.96, 0.96, 0.96)
            guard minX <= maxX, minY <= maxY else { return fallback }
            let step = max(1, Int((Double((maxX - minX + 1) * (maxY - minY + 1)) / 40000).squareRoot()))
            for y in stride(from: minY, through: maxY, by: step) {
                for x in stride(from: minX, through: maxX, by: step) {
                    let (r, g, b) = color(x, y)
                    let distance = max(abs(r - bg.0), abs(g - bg.1), abs(b - bg.2))
                    guard distance > 90 else { continue }
                    let key = (r >> 4) << 8 | (g >> 4) << 4 | b >> 4
                    let old = buckets[key] ?? (0, 0, 0, 0, 0)
                    buckets[key] = (old.count + 1, old.r + r, old.g + g, old.b + b, distance)
                }
            }
            guard let top = buckets.values.max(by: { $0.count < $1.count }) else { return fallback }
            return RGB(Double(top.r) / Double(top.count) / 255, Double(top.g) / Double(top.count) / 255, Double(top.b) / Double(top.count) / 255)
        }
    }
}
