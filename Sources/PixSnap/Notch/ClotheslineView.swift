import AppKit
import PixSnapCore

/// History as clotheslines: one rope per day, newest day on top, each capture clipped to the rope
/// like a photo, newest at the right. Photos sway gently, swing faster under the mouse, and drop in
/// with a bounce when the panel opens. Each photo keeps its capture's shape. Clicking one hands it
/// to `onPick`.
@MainActor
final class ClotheslineView: NSView {
    var onPick: ((HistoryEntry) -> Void)?
    /// A photo was pulled off its clip: the loose photo and its frame, in window coordinates.
    var onPullOff: ((HistoryEntry, CALayer, CGRect) -> Void)?
    /// The mouse, in window coordinates, while carrying a pulled-off photo and on letting go.
    var onCarry: ((CGPoint) -> Void)?
    var onLetGo: ((CGPoint) -> Void)?

    /// The photo under the mouse, if any.
    private(set) var hoveredEntry: HistoryEntry?

    /// The captures on the lines in reading order: top line first, left to right.
    var entries: [HistoryEntry] { photos.filter { !$0.isEmpty }.map(\.entry) }

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
                photo.onPullOff = { [weak self] entry, loose, frame in
                    if self?.hoveredEntry == entry { self?.hoveredEntry = nil }
                    self?.onPullOff?(entry, loose, frame)
                }
                photo.onCarry = { [weak self] point in self?.onCarry?(point) }
                photo.onLetGo = { [weak self] point in self?.onLetGo?(point) }
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
        guard let photo = photos.first(where: { $0.entry == entry && !$0.isEmpty }), let window else { return nil }
        return window.convertToScreen(photo.convert(photo.pictureFrame, to: nil))
    }

    /// Takes a photo off its clip without dragging (the Delete key). Returns the loose photo and its
    /// frame in window coordinates.
    func pullOff(_ entry: HistoryEntry) -> (layer: CALayer, frame: CGRect)? {
        guard let photo = photos.first(where: { $0.entry == entry && !$0.isEmpty }) else { return nil }
        if hoveredEntry == entry { hoveredEntry = nil }
        return photo.pullOff()
    }

    /// Photos fall onto their ropes one after another; with `only`, just that one.
    func playDropAnimation(only entry: HistoryEntry? = nil) {
        for (index, photo) in photos.enumerated() where entry == nil || photo.entry == entry {
            photo.drop(after: entry == nil ? Double(index) * 0.03 : 0)
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
/// rotates around the rope. Pulled down far enough, the clip lets go: the clip stays on the rope
/// and the photo is handed over (`onPullOff`) to be carried and thrown into the basket.
@MainActor
private final class PhotoView: NSView {
    var onPick: ((HistoryEntry) -> Void)?
    var onHover: ((HistoryEntry, Bool) -> Void)?
    /// The photo came off its clip: the loose photo and its frame in window coordinates.
    var onPullOff: ((HistoryEntry, CALayer, CGRect) -> Void)?
    /// While carrying the photo off, and on letting go: the mouse in window coordinates.
    var onCarry: ((CGPoint) -> Void)?
    var onLetGo: ((CGPoint) -> Void)?

    /// How far the clip sticks up above the photo, onto the rope.
    static let clipOverhang: CGFloat = 8
    /// Pull the mouse down this far and the clip lets go.
    private static let pullOffDistance: CGFloat = 70

    let entry: HistoryEntry
    /// Only the empty clip is left on the line.
    private(set) var isEmpty = false

    private let hanger = CALayer()
    private let clip = CALayer()
    private let thumbnail: CGImage?
    private let restPosition: CGPoint
    private let tilt: CGFloat
    private let period: Double

    private enum Drag {
        case none
        /// Pressed; `moved` once it has gone further than a click.
        case pressed(start: CGPoint, moved: Bool)
        case carried
    }

    private var drag = Drag.none

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
        self.thumbnail = thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let frame = CGRect(x: 0, y: 0, width: size.width + 16, height: size.height + Self.clipOverhang + 10)
        restPosition = CGPoint(x: frame.midX, y: frame.maxY - Self.clipOverhang)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        // Anchored at its top center, where the clip holds it.
        Self.dress(hanger, size: size, thumbnail: self.thumbnail)
        hanger.anchorPoint = CGPoint(x: 0.5, y: 1)
        hanger.position = restPosition
        hanger.transform = CATransform3DMakeRotation(tilt, 0, 0, 1)

        clip.frame = CGRect(x: size.width / 2 - 5, y: size.height - 7, width: 10, height: 15)
        clip.backgroundColor = NSColor(srgbRed: 0.94, green: 0.62, blue: 0.15, alpha: 1).cgColor
        clip.cornerRadius = 2
        hanger.addSublayer(clip)

        layer?.addSublayer(hanger)
        sway(fast: false)

        var tip = Self.dateFormatter.string(from: entry.createdAt)
        if let app = entry.sourceAppName { tip += " · \(app)" }
        toolTip = "\(tip)\n点一下浮动到屏幕上，按空格预览\n往下扯或按 Delete 扔进洗衣篮"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The white-bordered print: the hanging photo and the loose copy share it.
    private static func dress(_ layer: CALayer, size: CGSize, thumbnail: CGImage?) {
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.backgroundColor = NSColor(white: 0.97, alpha: 1).cgColor
        layer.cornerRadius = 2
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.45
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: -2)

        let picture = CALayer()
        picture.frame = layer.bounds.insetBy(dx: 3, dy: 3)
        picture.contents = thumbnail
        picture.contentsGravity = .resizeAspectFill
        picture.masksToBounds = true
        picture.backgroundColor = NSColor(white: 0.85, alpha: 1).cgColor
        layer.addSublayer(picture)
    }

    private func sway(fast: Bool) {
        guard !isEmpty else { return }
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

    /// The picture's frame in this view, ignoring the swing.
    var pictureFrame: CGRect {
        CGRect(x: hanger.position.x - hanger.bounds.width / 2, y: hanger.position.y - hanger.bounds.height,
               width: hanger.bounds.width, height: hanger.bounds.height)
    }

    // MARK: Coming off the line

    /// Lets go of the photo: the clip stays on the rope with a snap and the hanging photo
    /// disappears. Returns a loose copy and where it was, in window coordinates.
    func pullOff() -> (layer: CALayer, frame: CGRect) {
        let frame = convert(pictureFrame, to: nil)
        let loose = CALayer()
        Self.dress(loose, size: hanger.bounds.size, thumbnail: thumbnail)
        loose.transform = CATransform3DMakeRotation(tilt, 0, 0, 1)

        isEmpty = true
        toolTip = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The clip stays where it was on the rope, hanging from its top.
        let clipTop = CGPoint(x: restPosition.x, y: restPosition.y + Self.clipOverhang)
        clip.removeFromSuperlayer()
        clip.anchorPoint = CGPoint(x: 0.5, y: 1)
        clip.position = clipTop
        layer?.addSublayer(clip)
        hanger.removeAllAnimations()
        hanger.isHidden = true
        CATransaction.commit()

        // Freed of the photo's weight, the clip flicks up and wobbles to rest.
        clip.add(Motion.spring("transform.rotation.z", from: 0.55, to: 0, duration: 0.5, bounce: 0.55), forKey: "snap")
        return (loose, frame)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isEmpty else { return }
        sway(fast: true)
        onHover?(entry, true)
    }

    override func mouseExited(with event: NSEvent) {
        guard !isEmpty else { return }
        sway(fast: false)
        onHover?(entry, false)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isEmpty else { return }
        drag = .pressed(start: event.locationInWindow, moved: false)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = event.locationInWindow
        switch drag {
        case .none:
            return
        case .carried:
            onCarry?(point)
        case .pressed(let start, let moved):
            let dx = point.x - start.x, down = max(0, start.y - point.y)
            guard moved || hypot(dx, start.y - point.y) >= 4 else { return }
            if down >= Self.pullOffDistance {
                drag = .carried
                onHover?(entry, false)
                let (loose, frame) = pullOff()
                onPullOff?(entry, loose, frame)
                onCarry?(point)
            } else {
                drag = .pressed(start: start, moved: true)
                // The clip resists more the further it's pulled, like a rubber band.
                Motion.immediately {
                    hanger.position = CGPoint(x: restPosition.x + Self.rubberBand(dx, limit: 14), y: restPosition.y - Self.rubberBand(down, limit: 40))
                }
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = .none }
        switch drag {
        case .none:
            return
        case .carried:
            onLetGo?(event.locationInWindow)
        case .pressed(_, let moved):
            if moved { springBack() } else { onPick?(entry) }
        }
    }

    /// Not pulled hard enough: the clip snaps the photo back up.
    private func springBack() {
        let back = Motion.spring("position", from: NSValue(point: hanger.position), to: NSValue(point: restPosition), duration: 0.45, bounce: 0.35)
        Motion.immediately { hanger.position = restPosition }
        hanger.add(back, forKey: "springBack")
    }

    /// The system's scroll-bounce curve: moves freely at first, then less and less toward `limit`.
    private static func rubberBand(_ offset: CGFloat, limit: CGFloat) -> CGFloat {
        let stretched = limit * (1 - 1 / (abs(offset) * 0.55 / limit + 1))
        return offset < 0 ? -stretched : stretched
    }
}
