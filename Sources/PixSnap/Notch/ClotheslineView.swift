import AppKit
import PixSnapCore

/// History as clotheslines: one rope per day, newest day on top, each capture clipped to the rope
/// like a photo, newest at the right. Photos sway gently, swing faster under the mouse, and drop in
/// with a bounce when the panel opens. Clicking one hands it to `onPick`.
@MainActor
final class ClotheslineView: NSView {
    var onPick: ((HistoryEntry) -> Void)?

    static let maximumDays = 3
    private static let rowHeight: CGFloat = 124
    private static let topPadding: CGFloat = 6
    private static let bottomPadding: CGFloat = 16
    private static let emptyHeight: CGFloat = 60
    /// The ropes run from screen edge to screen edge, pegged just inside it.
    private static let ropeInset: CGFloat = 10
    private static let ropeSag: CGFloat = 22
    private static let photoSpacing: CGFloat = 110

    private let ropes = RopeView()
    private var photos: [PhotoView] = []
    private let message = NSTextField(labelWithString: "")

    /// Height needed to show `dayCount` lines.
    static func height(forDays dayCount: Int) -> CGFloat {
        dayCount == 0 ? emptyHeight : topPadding + CGFloat(dayCount) * rowHeight + bottomPadding
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        ropes.frame = bounds
        ropes.autoresizingMask = [.width, .height]
        addSubview(ropes)
        message.font = .systemFont(ofSize: 13)
        message.textColor = .white
        message.alignment = .center
        message.wantsLayer = true
        message.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        message.layer?.cornerRadius = 8
        addSubview(message)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Lays out `days`; `emptyMessage` shows when there's nothing to hang.
    func show(_ days: [HistoryGrouping.Day], thumbnails: (HistoryEntry) -> NSImage?, emptyMessage: String) {
        photos.forEach { $0.removeFromSuperview() }
        photos = []
        ropes.lines = []
        subviews.filter { $0 is DayLabel }.forEach { $0.removeFromSuperview() }

        message.isHidden = !days.isEmpty
        message.stringValue = emptyMessage
        message.sizeToFit()
        let messageSize = CGSize(width: message.frame.width + 28, height: message.frame.height + 14)
        message.frame = CGRect(x: ((bounds.width - messageSize.width) / 2).rounded(), y: ((bounds.height - messageSize.height) / 2).rounded(),
                               width: messageSize.width, height: messageSize.height)
        guard !days.isEmpty else { return }

        let ropeStart = Self.ropeInset
        let ropeEnd = bounds.width - Self.ropeInset
        let capacity = max(1, Int((ropeEnd - ropeStart - 120) / Self.photoSpacing))
        var random = SeededRandom(seed: 7)

        for (row, day) in days.enumerated() {
            let ropeY = bounds.maxY - Self.topPadding - CGFloat(row) * Self.rowHeight - 24
            ropes.lines.append(RopeView.Line(from: CGPoint(x: ropeStart, y: ropeY), to: CGPoint(x: ropeEnd, y: ropeY), sag: Self.ropeSag))

            // The day sits just above the rope, near its left end.
            let label = DayLabel(text: day.title)
            label.setFrameOrigin(CGPoint(x: 24, y: ropeY + 4))
            addSubview(label)

            // The newest captures that fit, spread evenly along the rope.
            let shown = day.entries.suffix(capacity)
            for (index, entry) in shown.enumerated() {
                let t = CGFloat(index + 1) / CGFloat(shown.count + 1)
                let x = ropeStart + t * (ropeEnd - ropeStart)
                let y = ropeY - Self.ropeSag * 4 * t * (1 - t)
                let photo = PhotoView(
                    entry: entry,
                    thumbnail: thumbnails(entry),
                    tilt: CGFloat(random.next(in: -0.06...0.06)),
                    period: random.next(in: 1.6...2.8)
                )
                photo.setFrameOrigin(CGPoint(x: x - photo.frame.width / 2, y: y - photo.frame.height + PhotoView.clipOverhang))
                photo.onPick = { [weak self] entry in self?.onPick?(entry) }
                addSubview(photo)
                photos.append(photo)
            }
        }
    }

    /// Photos fall onto their ropes one after another.
    func playDropAnimation() {
        for (index, photo) in photos.enumerated() {
            photo.drop(after: Double(index) * 0.03)
        }
    }
}

/// The ropes, drawn as layers under the photos.
@MainActor
private final class RopeView: NSView {
    struct Line {
        let from: CGPoint
        let to: CGPoint
        let sag: CGFloat
    }

    var lines: [Line] = [] {
        didSet { rebuild() }
    }

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
            let path = CGMutablePath()
            path.move(to: line.from)
            // A quadratic curve whose midpoint dips by `sag`.
            path.addQuadCurve(to: line.to, control: CGPoint(x: (line.from.x + line.to.x) / 2, y: line.from.y - line.sag * 2))
            // A light line with a dark halo, readable over light and dark screens alike.
            let rope = CAShapeLayer()
            rope.path = path
            rope.fillColor = nil
            rope.strokeColor = NSColor(white: 0.96, alpha: 0.95).cgColor
            rope.lineWidth = 1.5
            rope.shadowColor = NSColor.black.cgColor
            rope.shadowOpacity = 0.6
            rope.shadowRadius = 1.5
            rope.shadowOffset = .zero
            layer?.addSublayer(rope)
            for end in [line.from, line.to] {
                let peg = CAShapeLayer()
                peg.path = CGPath(ellipseIn: CGRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7), transform: nil)
                peg.fillColor = NSColor(white: 0.96, alpha: 1).cgColor
                peg.strokeColor = NSColor.black.withAlphaComponent(0.45).cgColor
                peg.lineWidth = 1
                layer?.addSublayer(peg)
            }
        }
    }
}

/// "今天" just above the left end of a rope, on a dark pill so it reads over anything.
@MainActor
private final class DayLabel: NSView {
    init(text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()
        super.init(frame: CGRect(x: 0, y: 0, width: label.frame.width + 16, height: label.frame.height + 6))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = frame.height / 2
        label.setFrameOrigin(CGPoint(x: 8, y: 3))
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One capture hanging from its clip. The swinging part is a layer anchored at the clip, so it
/// rotates around the rope.
@MainActor
private final class PhotoView: NSView {
    var onPick: ((HistoryEntry) -> Void)?

    static let photoSize = CGSize(width: 92, height: 64)
    /// How far the clip sticks up above the photo, onto the rope.
    static let clipOverhang: CGFloat = 8

    private let entry: HistoryEntry
    private let hanger = CALayer()
    private let tilt: CGFloat
    private let period: Double
    private var mouseDownPoint: CGPoint?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init(entry: HistoryEntry, thumbnail: NSImage?, tilt: CGFloat, period: Double) {
        self.entry = entry
        self.tilt = tilt
        self.period = period
        let size = Self.photoSize
        super.init(frame: CGRect(x: 0, y: 0, width: size.width + 16, height: size.height + Self.clipOverhang + 10))
        wantsLayer = true
        layer?.masksToBounds = false

        // Anchored at its top center, where the clip holds it.
        hanger.bounds = CGRect(origin: .zero, size: size)
        hanger.anchorPoint = CGPoint(x: 0.5, y: 1)
        hanger.position = CGPoint(x: bounds.midX, y: bounds.maxY - Self.clipOverhang)
        hanger.backgroundColor = NSColor(white: 0.97, alpha: 1).cgColor
        hanger.cornerRadius = 2
        hanger.shadowColor = NSColor.black.cgColor
        hanger.shadowOpacity = 0.45
        hanger.shadowRadius = 4
        hanger.shadowOffset = CGSize(width: 0, height: -2)
        hanger.transform = CATransform3DMakeRotation(tilt, 0, 0, 1)

        let picture = CALayer()
        picture.frame = hanger.bounds.insetBy(dx: 3, dy: 3)
        picture.contents = thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        picture.contentsGravity = .resizeAspectFill
        picture.masksToBounds = true
        picture.backgroundColor = NSColor(white: 0.85, alpha: 1).cgColor
        hanger.addSublayer(picture)

        let clip = CALayer()
        clip.frame = CGRect(x: size.width / 2 - 5, y: size.height - 7, width: 10, height: 15)
        clip.backgroundColor = NSColor(srgbRed: 0.94, green: 0.62, blue: 0.15, alpha: 1).cgColor
        clip.cornerRadius = 2
        hanger.addSublayer(clip)

        layer?.addSublayer(hanger)
        sway(fast: false)

        var tip = Self.dateFormatter.string(from: entry.createdAt)
        if let app = entry.sourceAppName { tip += " · \(app)" }
        toolTip = "\(tip)\n点一下浮动到屏幕上"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func sway(fast: Bool) {
        let swing: CGFloat = fast ? 0.07 : 0.025
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = tilt - swing
        animation.toValue = tilt + swing
        animation.duration = fast ? 0.28 : period
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        hanger.add(animation, forKey: "sway")
    }

    func drop(after delay: Double) {
        let drop = CASpringAnimation(keyPath: "position.y")
        drop.fromValue = hanger.position.y + 44
        drop.toValue = hanger.position.y
        drop.damping = 9
        drop.stiffness = 240
        drop.duration = drop.settlingDuration
        drop.beginTime = CACurrentMediaTime() + delay
        drop.fillMode = .backwards
        hanger.add(drop, forKey: "drop")
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { sway(fast: true) }
    override func mouseExited(with event: NSEvent) { sway(fast: false) }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard let start = mouseDownPoint,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) < 4 else { return }
        onPick?(entry)
    }
}

/// Repeatable pseudo-random numbers, so photos keep the same tilt every time the panel opens.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = Double(state >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
