import AppKit
import PixSnapCore

/// History as clotheslines: one rope per day, newest day on top, each capture clipped to the rope
/// like a photo, newest at the right. Photos sway gently, swing faster under the mouse, and drop in
/// with a bounce when the panel opens. Each photo keeps its capture's shape. Clicking one hands it
/// to `onPick`.
@MainActor
final class ClotheslineView: NSView {
    var onPick: ((HistoryEntry) -> Void)?

    /// The photo under the mouse, if any.
    private(set) var hoveredEntry: HistoryEntry?

    /// The captures on the lines in reading order: top line first, left to right.
    var entries: [HistoryEntry] { photos.map(\.entry) }

    static let maximumDays = 3
    /// Room for the tallest photo below the dip of the rope.
    private static let rowHeight: CGFloat = 150
    private static let topPadding: CGFloat = 6
    private static let bottomPadding: CGFloat = 16
    private static let emptyHeight: CGFloat = 60
    /// The ropes run from screen edge to screen edge, pegged just inside it.
    private static let ropeInset: CGFloat = 10
    private static let ropeSag: CGFloat = 22

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
    func show(_ days: [HistoryGrouping.Day], style: RopeStyle, thumbnails: (HistoryEntry) -> NSImage?, emptyMessage: String) {
        ropes.style = style
        photos.forEach { $0.removeFromSuperview() }
        photos = []
        hoveredEntry = nil
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
        let ropeLength = ropeEnd - ropeStart
        var random = SeededRandom(seed: 7)

        for (row, day) in days.enumerated() {
            let ropeY = bounds.maxY - Self.topPadding - CGFloat(row) * Self.rowHeight - 24
            let line = RopeView.Line(from: CGPoint(x: ropeStart, y: ropeY), to: CGPoint(x: ropeEnd, y: ropeY), sag: Self.ropeSag)
            ropes.lines.append(line)

            // The day sits just above the rope, near its left end.
            let label = DayLabel(text: day.title)
            label.setFrameOrigin(CGPoint(x: 24, y: ropeY + RopeView.clearance(for: style) + 4))
            addSubview(label)

            // The newest captures that fit, spread evenly along the rope.
            let sizes = day.entries.map { ClotheslineLayout.photoSize(pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight) }
            // Photos are 16pt wider than their picture, for the swing.
            let count = max(1, ClotheslineLayout.fittingCount(widths: sizes.map { $0.width + 16 }, length: ropeLength))
            let shown = Array(zip(day.entries, sizes).suffix(count))
            let centers = ClotheslineLayout.centers(widths: shown.map { $0.1.width + 16 }, length: ropeLength)
            for ((entry, size), center) in zip(shown, centers) {
                let clip = line.point(at: center / ropeLength)
                let photo = PhotoView(
                    entry: entry,
                    size: size,
                    thumbnail: thumbnails(entry),
                    tilt: CGFloat(random.next(in: -0.06...0.06)),
                    period: random.next(in: 1.6...2.8)
                )
                photo.setFrameOrigin(CGPoint(x: clip.x - photo.frame.width / 2, y: clip.y - photo.frame.height + PhotoView.clipOverhang))
                photo.onPick = { [weak self] entry in self?.onPick?(entry) }
                photo.onHover = { [weak self] entry, inside in
                    if inside {
                        self?.hoveredEntry = entry
                    } else if self?.hoveredEntry == entry {
                        self?.hoveredEntry = nil
                    }
                }
                addSubview(photo)
                photos.append(photo)
            }
        }
    }

    /// Where a photo's picture is on screen, for the preview to grow out of.
    func screenRect(of entry: HistoryEntry) -> CGRect? {
        guard let photo = photos.first(where: { $0.entry == entry }), let window else { return nil }
        return window.convertToScreen(photo.convert(photo.pictureFrame, to: nil))
    }

    /// Photos fall onto their ropes one after another.
    func playDropAnimation() {
        for (index, photo) in photos.enumerated() {
            photo.drop(after: Double(index) * 0.03)
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
    var onHover: ((HistoryEntry, Bool) -> Void)?
    /// How far the clip sticks up above the photo, onto the rope.
    static let clipOverhang: CGFloat = 8

    let entry: HistoryEntry
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

    init(entry: HistoryEntry, size: CGSize, thumbnail: NSImage?, tilt: CGFloat, period: Double) {
        self.entry = entry
        self.tilt = tilt
        self.period = period
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
        toolTip = "\(tip)\n点一下浮动到屏幕上，按空格预览"
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

    /// The picture's resting frame in this view, ignoring the swing.
    var pictureFrame: CGRect {
        CGRect(x: hanger.position.x - hanger.bounds.width / 2, y: hanger.position.y - hanger.bounds.height,
               width: hanger.bounds.width, height: hanger.bounds.height)
    }

    override func mouseEntered(with event: NSEvent) {
        sway(fast: true)
        onHover?(entry, true)
    }

    override func mouseExited(with event: NSEvent) {
        sway(fast: false)
        onHover?(entry, false)
    }

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
