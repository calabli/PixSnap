import AppKit
import PixSnapCore

/// The clothesline ropes, drawn as layers under the photos in the style picked in settings.
/// Each rope is a quadratic curve that dips by `sag` in the middle, pegged at both ends.
@MainActor
final class RopeView: NSView {
    struct Line {
        let from: CGPoint
        let to: CGPoint
        let sag: CGFloat

        /// The point on the rope at `t` (0 at `from`, 1 at `to`). x is linear in t because the
        /// control point sits halfway along.
        func point(at t: CGFloat) -> CGPoint {
            CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t - sag * 4 * t * (1 - t))
        }

        /// Unit direction of the rope at `t`.
        func tangent(at t: CGFloat) -> CGPoint {
            let dx = to.x - from.x
            let dy = (to.y - from.y) - sag * 4 * (1 - 2 * t)
            let length = max(hypot(dx, dy), 0.001)
            return CGPoint(x: dx / length, y: dy / length)
        }

        var path: CGPath {
            let path = CGMutablePath()
            path.move(to: from)
            path.addQuadCurve(to: to, control: CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 - sag * 2))
            return path
        }
    }

    var lines: [Line] = [] {
        didSet { rebuild() }
    }

    var style = RopeStyle.default {
        didSet { if style != oldValue { rebuild() } }
    }

    /// How far the rope reaches above its center line, so labels can sit clear of it.
    static func clearance(for style: RopeStyle) -> CGFloat {
        let width = CGFloat(style.thickness.width)
        return style.material == .lights ? bulbRadius(for: width) : width / 2
    }

    private static func bulbRadius(for width: CGFloat) -> CGFloat { width * 0.6 + 2.5 }
    private static let bulbSpacing: CGFloat = 30

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func rebuild() {
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        for line in lines {
            switch style.material {
            case .cotton: addCotton(line)
            case .jute: addJute(line)
            case .wire: addWire(line)
            case .lights: addLights(line)
            }
            addPegs(line)
        }
    }

    // MARK: Materials

    private var width: CGFloat { CGFloat(style.thickness.width) }
    private var color: NSColor { style.color.nsColor }

    /// A smooth, even line.
    private func addCotton(_ line: Line) {
        layer?.addSublayer(stroke(line.path, color: color, width: width, halo: true))
    }

    /// Twisted strands: short slanted grooves across the rope, with a light sheen along the top.
    private func addJute(_ line: Line) {
        layer?.addSublayer(stroke(line.path, color: color, width: width, halo: true))
        let step = max(width * 1.1, 2.5)
        let count = Int(abs(line.to.x - line.from.x) / step)
        let grooves = CGMutablePath()
        for index in 0...count {
            let t = CGFloat(index) / CGFloat(max(count, 1))
            let center = line.point(at: t)
            let tangent = line.tangent(at: t)
            let normal = CGPoint(x: -tangent.y, y: tangent.x)
            let half = width / 2
            let slant = width * 0.45
            grooves.move(to: CGPoint(x: center.x + normal.x * half - tangent.x * slant, y: center.y + normal.y * half - tangent.y * slant))
            grooves.addLine(to: CGPoint(x: center.x - normal.x * half + tangent.x * slant, y: center.y - normal.y * half + tangent.y * slant))
        }
        layer?.addSublayer(stroke(grooves, color: style.color.mixed(with: .black, by: 0.4), width: max(width * 0.22, 0.6)))
        var shift = CGAffineTransform(translationX: 0, y: width * 0.2)
        if let sheenPath = line.path.copy(using: &shift) {
            let sheen = stroke(sheenPath, color: style.color.mixed(with: .white, by: 0.3), width: max(width * 0.18, 0.5))
            sheen.opacity = 0.6
            layer?.addSublayer(sheen)
        }
    }

    /// A shiny wire: a darker body with a bright highlight along its top edge.
    private func addWire(_ line: Line) {
        layer?.addSublayer(stroke(line.path, color: style.color.mixed(with: .black, by: 0.3), width: width, halo: true))
        var shift = CGAffineTransform(translationX: 0, y: width * 0.22)
        if let highlightPath = line.path.copy(using: &shift) {
            layer?.addSublayer(stroke(highlightPath, color: style.color.mixed(with: .white, by: 0.7), width: max(width * 0.3, 0.6)))
        }
    }

    /// Fairy lights: a thin dark cord with glowing bulbs in the rope color that twinkle out of step.
    private func addLights(_ line: Line) {
        layer?.addSublayer(stroke(line.path, color: style.color.mixed(with: .black, by: 0.6), width: 1, halo: true))
        let radius = Self.bulbRadius(for: width)
        let count = max(2, Int(abs(line.to.x - line.from.x) / Self.bulbSpacing))
        var random = SeededRandom(seed: 11)
        for index in 1..<count {
            let center = line.point(at: CGFloat(index) / CGFloat(count))
            let bulb = CAShapeLayer()
            // Hang just below the cord, like a bulb on its socket.
            bulb.path = CGPath(ellipseIn: CGRect(x: center.x - radius * 0.75, y: center.y - radius * 2, width: radius * 1.5, height: radius * 2), transform: nil)
            bulb.fillColor = style.color.mixed(with: .white, by: 0.25).cgColor
            bulb.shadowColor = color.cgColor
            bulb.shadowOpacity = 1
            bulb.shadowRadius = radius * 1.2
            bulb.shadowOffset = .zero
            let twinkle = CABasicAnimation(keyPath: "opacity")
            twinkle.fromValue = 1
            twinkle.toValue = 0.35
            twinkle.duration = random.next(in: 0.8...1.6)
            twinkle.autoreverses = true
            twinkle.repeatCount = .infinity
            twinkle.timeOffset = random.next(in: 0...1.6)
            twinkle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bulb.add(twinkle, forKey: "twinkle")
            layer?.addSublayer(bulb)
        }
    }

    private func addPegs(_ line: Line) {
        let radius = max(3.5, width / 2 + 2)
        for end in [line.from, line.to] {
            let peg = CAShapeLayer()
            peg.path = CGPath(ellipseIn: CGRect(x: end.x - radius, y: end.y - radius, width: radius * 2, height: radius * 2), transform: nil)
            peg.fillColor = style.color.mixed(with: .white, by: 0.3).cgColor
            peg.strokeColor = NSColor.black.withAlphaComponent(0.45).cgColor
            peg.lineWidth = 1
            layer?.addSublayer(peg)
        }
    }

    /// `halo` adds a soft outline in the opposite brightness, so the rope reads over light and
    /// dark screens alike.
    private func stroke(_ path: CGPath, color: NSColor, width: CGFloat, halo: Bool = false) -> CAShapeLayer {
        let rope = CAShapeLayer()
        rope.path = path
        rope.fillColor = nil
        rope.strokeColor = color.cgColor
        rope.lineWidth = width
        if halo {
            rope.shadowColor = (style.color.isDark ? NSColor.white : NSColor.black).cgColor
            rope.shadowOpacity = style.color.isDark ? 0.5 : 0.6
            rope.shadowRadius = 1.5
            rope.shadowOffset = .zero
        }
        return rope
    }
}

extension PixelColor {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    init(_ color: NSColor) {
        let srgb = color.usingColorSpace(.sRGB) ?? .white
        func byte(_ value: CGFloat) -> UInt8 { UInt8((min(1, max(0, value)) * 255).rounded()) }
        self.init(red: byte(srgb.redComponent), green: byte(srgb.greenComponent), blue: byte(srgb.blueComponent))
    }

    /// Relative brightness below which a light halo reads better than a dark one.
    var isDark: Bool {
        (0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)) / 255 < 0.35
    }

    func mixed(with other: NSColor, by amount: CGFloat) -> NSColor {
        nsColor.blended(withFraction: amount, of: other) ?? nsColor
    }
}

/// Repeatable pseudo-random numbers, so photos keep the same tilt and bulbs the same rhythm
/// every time the lines come down.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = Double(state >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
