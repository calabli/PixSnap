import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import PixSnapCore

/// 智能美化's drawing: measures a screenshot's colors, and draws it finished in a `BeautifyStyle` —
/// on a background with room around it, rounded, shadowed, maybe in a window frame.
public enum Beautifier {
    /// A macOS window title bar's height, in points.
    static let titleBarHeight: CGFloat = 28

    /// Brightness, flatness, color concentration and accent color, from a small copy of `image`.
    public static func measure(_ image: CGImage) -> (brightness: Double, flatness: Double, concentration: Double, accent: RGB) {
        let side = 96
        var data = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &data, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (1, 1, 1, RGB(0.5, 0.5, 0.5)) }
        context.interpolationQuality = .medium
        // Transparency (a window's corners) counts as white.
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var brightness = 0.0, flatPairs = 0, pairs = 0
        var buckets: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        var saturatedBuckets: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        for y in 0 ..< side {
            for x in 0 ..< side {
                let i = (y * side + x) * 4
                let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
                let color = RGB(Double(r) / 255, Double(g) / 255, Double(b) / 255)
                brightness += color.luminance
                if x + 1 < side {
                    let j = i + 4
                    pairs += 1
                    if max(abs(r - Int(data[j])), abs(g - Int(data[j + 1])), abs(b - Int(data[j + 2]))) <= 6 { flatPairs += 1 }
                }
                let key = (r >> 4) << 8 | (g >> 4) << 4 | b >> 4
                func add(_ table: inout [Int: (count: Int, red: Int, green: Int, blue: Int)]) {
                    let old = table[key] ?? (0, 0, 0, 0)
                    table[key] = (old.count + 1, old.red + r, old.green + g, old.blue + b)
                }
                add(&buckets)
                let hsb = color.hsb
                if hsb.saturation > 0.35, hsb.brightness > 0.25 { add(&saturatedBuckets) }
            }
        }
        let total = side * side
        // A saturated color counts from 0.3% of the image: a button, a highlighted keyword.
        let pick = saturatedBuckets.values.max { $0.count < $1.count }.flatMap { $0.count * 1000 >= total * 3 ? $0 : nil }
            ?? buckets.values.max { $0.count < $1.count }!
        let accent = RGB(Double(pick.red) / Double(pick.count) / 255, Double(pick.green) / Double(pick.count) / 255,
                         Double(pick.blue) / Double(pick.count) / 255)
        let top = buckets.values.map(\.count).sorted(by: >).prefix(8).reduce(0, +)
        return (brightness / Double(total), Double(flatPairs) / Double(max(pairs, 1)), Double(top) / Double(total), accent)
    }

    /// `image` (at `scale` pixels per point) finished in `style`.
    public static func render(_ image: CGImage, scale: CGFloat, style: BeautifyStyle) -> CGImage? {
        let titleBar: CGFloat
        if case .window = style.frame { titleBar = (titleBarHeight * scale).rounded() } else { titleBar = 0 }
        // A phone: a status bar above the screenshot, and a bezel all round.
        var phoneDark: Bool?
        if case let .phone(dark) = style.frame { phoneDark = dark }
        let widthPoints = CGFloat(image.width) / scale
        // An iPhone's status bar is 54 points on a 393-point-wide screen.
        let statusBar = phoneDark == nil ? 0 : (widthPoints * 54 / 393 * scale).rounded()
        let bezel = phoneDark == nil ? 0 : (max(8, min(widthPoints, CGFloat(image.height) / scale) * 0.035) * scale).rounded()
        let cardSize = CGSize(width: CGFloat(image.width) + bezel * 2, height: CGFloat(image.height) + titleBar + statusBar + bezel * 2)
        let pad = (CGFloat(style.paddingPoints(width: Double(cardSize.width / scale), height: Double(cardSize.height / scale))) * scale).rounded()
        let width = Int(cardSize.width + pad * 2), height = Int(cardSize.height + pad * 2)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high

        // With no room around it, there's no background either: the corners stay clear.
        switch pad > 0 ? style.background : nil {
        case let .gradient(from, to):
            let colors = [cgColor(from, space), cgColor(to, space)] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: nil) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
            }
        case .blurredImage:
            if let backdrop = blurredBackdrop(of: image, size: canvas.size, scale: scale) {
                context.draw(backdrop, in: canvas)
            }
        case nil:
            break
        }

        let card = CGRect(x: pad, y: pad, width: cardSize.width, height: cardSize.height)
        let screen = card.insetBy(dx: bezel, dy: bezel)
        let screenRadius = min(CGFloat(style.cornerRadius) * scale, min(screen.width, screen.height) / 2)
        // The body's corners follow the screen's, a bezel further out.
        let radius = screenRadius + bezel
        let shape = CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if let shadow = shadow(style.shadow) {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -shadow.drop * scale), blur: shadow.blur * scale,
                              color: CGColor(colorSpace: space, components: [0, 0, 0, shadow.alpha]))
            context.addPath(shape)
            context.setFillColor(CGColor(colorSpace: space, components: [0, 0, 0, 1])!)
            context.fillPath()
            context.restoreGState()
        }

        if let dark = phoneDark {
            drawPhone(image, card: card, screen: screen, radius: radius, screenRadius: screenRadius, statusBar: statusBar,
                      dark: dark, scale: scale, context: context)
            return context.makeImage()
        }

        context.saveGState()
        context.addPath(shape)
        context.clip()
        if case let .window(dark) = style.frame {
            drawTitleBar(in: CGRect(x: card.minX, y: card.maxY - titleBar, width: card.width, height: titleBar), dark: dark, scale: scale, context: context)
            // The screenshot's own background shows under any transparency.
            context.setFillColor(dark ? CGColor(colorSpace: space, components: [0.12, 0.12, 0.13, 1])! : CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
            context.fill(CGRect(x: card.minX, y: card.minY, width: card.width, height: card.height - titleBar))
        }
        context.draw(image, in: CGRect(x: card.minX, y: card.minY, width: CGFloat(image.width), height: CGFloat(image.height)))
        context.restoreGState()

        if style.frame != .none {
            context.addPath(CGPath(roundedRect: card.insetBy(dx: 0.5 * scale, dy: 0.5 * scale), cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setLineWidth(scale)
            let dark: Bool
            if case let .window(isDark) = style.frame { dark = isDark } else { dark = false }
            context.setStrokeColor(dark ? CGColor(colorSpace: space, components: [1, 1, 1, 0.14])! : CGColor(colorSpace: space, components: [0, 0, 0, 0.12])!)
            context.strokePath()
        }
        return context.makeImage()
    }

    /// An iPhone around `image`: the body (dark, or silver with a lighter rim), and on the screen a
    /// status bar in the screenshot's top color with 9:41, the Dynamic Island, signal and battery.
    private static func drawPhone(_ image: CGImage, card: CGRect, screen: CGRect, radius: CGFloat, screenRadius: CGFloat,
                                  statusBar: CGFloat, dark: Bool, scale: CGFloat, context: CGContext) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ white: CGFloat, _ alpha: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [white, white, white, alpha])! }

        // The body, with a hairline rim like polished metal.
        let body = CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(body)
        context.setFillColor(dark ? color(0.1) : color(0.84))
        context.fillPath()
        context.addPath(CGPath(roundedRect: card.insetBy(dx: scale, dy: scale), cornerWidth: radius - scale, cornerHeight: radius - scale, transform: nil))
        context.setStrokeColor(dark ? color(0.32) : color(0.97))
        context.setLineWidth(1.5 * scale)
        context.strokePath()
        // A thin black band inside the body, as on the real thing.
        let inner = screen.insetBy(dx: -2 * scale, dy: -2 * scale)
        context.addPath(CGPath(roundedRect: inner, cornerWidth: screenRadius + 2 * scale, cornerHeight: screenRadius + 2 * scale, transform: nil))
        context.setFillColor(color(0))
        context.fillPath()

        context.saveGState()
        context.addPath(CGPath(roundedRect: screen, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil))
        context.clip()
        let bar = CGRect(x: screen.minX, y: screen.maxY - statusBar, width: screen.width, height: statusBar)
        let top = topColor(of: image)
        context.setFillColor(CGColor(colorSpace: space, components: [top.red, top.green, top.blue, 1])!)
        context.fill(bar)
        context.draw(image, in: CGRect(x: screen.minX, y: screen.minY, width: CGFloat(image.width), height: CGFloat(image.height)))
        drawStatusBar(in: bar, light: top.luminance > 0.55, scale: scale, context: context)
        context.restoreGState()
    }

    /// The color across the screenshot's top edge, for the status bar above it.
    private static func topColor(of image: CGImage) -> RGB {
        var pixel = [UInt8](repeating: 255, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let row = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: min(4, image.height))) else { return RGB(1, 1, 1) }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.draw(row, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return RGB(Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    /// 9:41 on the left, the Dynamic Island in the middle, signal bars and the battery on the right.
    private static func drawStatusBar(in bar: CGRect, light: Bool, scale: CGFloat, context: CGContext) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ink = light ? CGColor(colorSpace: space, components: [0, 0, 0, 1])! : CGColor(colorSpace: space, components: [1, 1, 1, 1])!
        // Laid out as on a 393-point-wide iPhone, whose status bar is 54 points tall.
        let unit = bar.width / 393
        let middle = bar.maxY - 28 * unit

        // The island: a black pill.
        let island = CGRect(x: bar.midX - 63 * unit, y: bar.maxY - 11 * unit - 37 * unit, width: 126 * unit, height: 37 * unit)
        context.addPath(CGPath(roundedRect: island, cornerWidth: island.height / 2, cornerHeight: island.height / 2, transform: nil))
        context.setFillColor(CGColor(colorSpace: space, components: [0, 0, 0, 1])!)
        context.fillPath()

        // 9:41
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 17 * unit, nil)!
        let text = CFAttributedStringCreate(nil, "9:41" as CFString, [kCTFontAttributeName: font, kCTForegroundColorAttributeName: ink] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(text)
        let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        // Centered in the space left of the island.
        context.textPosition = CGPoint(x: bar.minX + (bar.width / 2 - 63 * unit) / 2 + 6 * unit - CGFloat(textWidth) / 2, y: middle - 6 * unit)
        CTLineDraw(line, context)

        // Signal: four rising bars; battery: an outline with a fill and a nub.
        context.setFillColor(ink)
        let right = bar.maxX - 30 * unit
        let battery = CGRect(x: right - 25 * unit, y: middle - 6 * unit, width: 25 * unit, height: 12 * unit)
        context.setStrokeColor(ink)
        context.setLineWidth(unit)
        context.addPath(CGPath(roundedRect: battery, cornerWidth: 3 * unit, cornerHeight: 3 * unit, transform: nil))
        context.strokePath()
        context.addPath(CGPath(roundedRect: battery.insetBy(dx: 2 * unit, dy: 2 * unit), cornerWidth: 1.5 * unit, cornerHeight: 1.5 * unit, transform: nil))
        context.fillPath()
        context.fill(CGRect(x: battery.maxX + unit, y: middle - 2 * unit, width: 1.5 * unit, height: 4 * unit))
        for index in 0 ..< 4 {
            let height = (4 + CGFloat(index) * 2.7) * unit
            context.addPath(CGPath(roundedRect: CGRect(x: battery.minX - 28 * unit + CGFloat(index) * 5.5 * unit, y: middle - 6 * unit,
                                                       width: 3.5 * unit, height: height),
                                   cornerWidth: unit, cornerHeight: unit, transform: nil))
        }
        context.fillPath()
    }

    /// Blur, drop and opacity of each shadow.
    static func shadow(_ shadow: BeautifyStyle.Shadow) -> (blur: CGFloat, drop: CGFloat, alpha: CGFloat)? {
        switch shadow {
        case .none: nil
        case .thin: (10, 2, 0.18)
        case .soft: (32, 10, 0.28)
        case .deep: (54, 22, 0.5)
        }
    }

    /// The red, yellow and green buttons on a plain bar.
    private static func drawTitleBar(in rect: CGRect, dark: Bool, scale: CGFloat, context: CGContext) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        context.setFillColor(dark ? CGColor(colorSpace: space, components: [0.17, 0.17, 0.18, 1])! : CGColor(colorSpace: space, components: [0.93, 0.93, 0.93, 1])!)
        context.fill(rect)
        let colors: [[CGFloat]] = [[1, 0.37, 0.34, 1], [1, 0.74, 0.18, 1], [0.16, 0.79, 0.25, 1]]
        let diameter = 12 * scale
        for (index, color) in colors.enumerated() {
            let x = rect.minX + (14 + CGFloat(index) * 20) * scale
            context.setFillColor(CGColor(colorSpace: space, components: color)!)
            context.fillEllipse(in: CGRect(x: x, y: rect.midY - diameter / 2, width: diameter, height: diameter))
        }
        // A hairline under the bar.
        context.setFillColor(dark ? CGColor(colorSpace: space, components: [0, 0, 0, 0.5])! : CGColor(colorSpace: space, components: [0, 0, 0, 0.1])!)
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(1, scale / 2)))
    }

    /// The screenshot filling `size` (cropped to fit), heavily blurred and slightly softened.
    private static func blurredBackdrop(of image: CGImage, size: CGSize, scale: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let fill = max(size.width / input.extent.width, size.height / input.extent.height) * 1.1
        let scaled = input.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
        let offset = CGAffineTransform(translationX: (size.width - scaled.extent.width) / 2 - scaled.extent.minX,
                                       y: (size.height - scaled.extent.height) / 2 - scaled.extent.minY)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = scaled.transformed(by: offset).clampedToExtent()
        blur.radius = Float(40 * scale)
        let soften = CIFilter.colorControls()
        soften.inputImage = blur.outputImage
        soften.saturation = 1.3
        soften.brightness = -0.04
        let extent = CGRect(origin: .zero, size: size)
        guard let output = soften.outputImage?.cropped(to: extent) else { return nil }
        return CIContext().createCGImage(output, from: extent)
    }

    private static func cgColor(_ color: RGB, _ space: CGColorSpace) -> CGColor {
        CGColor(colorSpace: space, components: [color.red, color.green, color.blue, 1])!
    }
}
