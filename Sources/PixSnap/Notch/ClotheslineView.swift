import AppKit
import PixSnapCore

/// History as clotheslines: one rope per day, newest day on top, each capture clipped to the rope
/// like a photo, newest at the right. Photos sway gently, swing faster under the mouse, and drop in
/// with a bounce when the panel opens. Each photo keeps its capture's shape, and the fewer there are
/// on a line, the bigger they hang, up to the capture's own size. Clicking one hands it to `onPick`. Favorites hang from wooden clips that hold tight: they can't be pulled off.
@MainActor
final class ClotheslineView: NSView {
    var onPick: ((HistoryEntry) -> Void)?
    /// A photo's clip was clicked: it should be let go, into the basket.
    var onClipClick: ((HistoryEntry) -> Void)?
    /// Builds a photo's right-click menu.
    var menuForEntry: ((HistoryEntry) -> NSMenu?)?

    /// The photo under the mouse, if any.
    private(set) var hoveredEntry: HistoryEntry?

    /// The captures on the lines in reading order: top line first, left to right.
    var entries: [HistoryEntry] { photos.filter { !$0.isEmpty }.map(\.entry) }

    static let maximumDays = 3
    /// Above the tallest photo on a line: the rope's distance from the top of its row, its dip,
    /// the swing room under the photo and the space before the next line.
    private static let rowOverhead: CGFloat = 24 + 22 + 10 + 16
    /// The tallest a photo hangs, even alone on a big screen.
    private static let largestPhoto: CGFloat = 420
    /// Photos are this much wider than their picture, for the swing.
    fileprivate static let photoPadding: CGFloat = 16
    private static let topPadding: CGFloat = 6
    private static let bottomPadding: CGFloat = 16
    /// The ropes run from screen edge to screen edge, pegged just inside it.
    private static let ropeInset: CGFloat = 10
    private static let ropeSag: CGFloat = 22

    private let ropes = RopeView()
    private var photos: [PhotoView] = []
    private let message = NSTextField(labelWithString: "")

    /// What will hang where: the photos on each line with their sizes, and the height it all takes.
    struct Plan {
        struct Line {
            let title: String
            let photos: [(entry: HistoryEntry, size: CGSize)]
            let height: CGFloat
        }

        let lines: [Line]
        let height: CGFloat

        /// Just room for the "nothing yet" message.
        static let empty = Plan(lines: [], height: 60)
    }

    /// Fits `days` across a rope `width` wide, sharing `availableHeight` between the lines.
    static func plan(_ days: [HistoryGrouping.Day], width: CGFloat, availableHeight: CGFloat) -> Plan {
        guard !days.isEmpty else { return .empty }
        let ropeLength = width - ropeInset * 2
        let perLine = (availableHeight - topPadding - bottomPadding) / CGFloat(days.count) - rowOverhead
        let maxHeight = min(largestPhoto, max(ClotheslineLayout.minimumRowHeight, perLine.rounded(.down)))
        let lines = days.map { day in
            let sources = day.entries.map { CGSize(width: CGFloat($0.pixelWidth) / CGFloat(max($0.scale, 1)),
                                                   height: CGFloat($0.pixelHeight) / CGFloat(max($0.scale, 1))) }
            let sizes = ClotheslineLayout.photoSizes(pointSizes: sources, ropeLength: ropeLength, maxHeight: maxHeight, padding: photoPadding)
            let photos = zip(day.entries.suffix(sizes.count), sizes).map { (entry: $0, size: $1) }
            return Plan.Line(title: day.title, photos: photos, height: (sizes.map(\.height).max() ?? 0) + rowOverhead)
        }
        return Plan(lines: lines, height: topPadding + lines.reduce(0) { $0 + $1.height } + bottomPadding)
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

    /// Hangs what `plan` says; `emptyMessage` shows when there's nothing to hang. `image` supplies a
    /// picture sharp enough for a given longest side in pixels.
    func show(_ plan: Plan, style: RopeStyle, image: (HistoryEntry, CGFloat) -> CGImage?, emptyMessage: String) {
        ropes.style = style
        photos.forEach { $0.removeFromSuperview() }
        photos = []
        hoveredEntry = nil
        ropes.lines = []
        subviews.filter { $0 is DayLabel }.forEach { $0.removeFromSuperview() }

        message.isHidden = !plan.lines.isEmpty
        message.stringValue = emptyMessage
        message.sizeToFit()
        let messageSize = CGSize(width: message.frame.width + 28, height: message.frame.height + 14)
        message.frame = CGRect(x: ((bounds.width - messageSize.width) / 2).rounded(), y: ((bounds.height - messageSize.height) / 2).rounded(),
                               width: messageSize.width, height: messageSize.height)
        guard !plan.lines.isEmpty else { return }

        let ropeStart = Self.ropeInset
        let ropeEnd = bounds.width - Self.ropeInset
        let ropeLength = ropeEnd - ropeStart
        var random = SeededRandom(seed: 7)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        var rowTop = bounds.maxY - Self.topPadding
        for day in plan.lines {
            let ropeY = rowTop - 24
            rowTop -= day.height
            let line = RopeView.Line(from: CGPoint(x: ropeStart, y: ropeY), to: CGPoint(x: ropeEnd, y: ropeY), sag: Self.ropeSag)
            ropes.lines.append(line)

            // The day sits just above the rope, near its left end.
            let label = DayLabel(text: day.title)
            label.setFrameOrigin(CGPoint(x: 24, y: ropeY + RopeView.clearance(for: style) + 4))
            addSubview(label)

            // Spread evenly along the rope.
            let centers = ClotheslineLayout.centers(widths: day.photos.map { $0.size.width + Self.photoPadding }, length: ropeLength)
            for ((entry, size), center) in zip(day.photos, centers) {
                let clip = line.point(at: center / ropeLength)
                let photo = PhotoView(
                    entry: entry,
                    size: size,
                    thumbnail: image(entry, max(size.width, size.height) * scale),
                    isFavorite: entry.isFavorite,
                    tilt: CGFloat(random.next(in: -0.06...0.06)) * min(1, 100 / size.height),
                    period: random.next(in: 1.6...2.8)
                )
                photo.setFrameOrigin(CGPoint(x: clip.x - photo.frame.width / 2, y: clip.y - photo.frame.height + PhotoView.clipOverhang))
                photo.onPick = { [weak self] entry in self?.onPick?(entry) }
                photo.onClipClick = { [weak self] entry in self?.onClipClick?(entry) }
                photo.menuProvider = { [weak self] entry in self?.menuForEntry?(entry) }
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

    /// Opens the photo's clip and lets go of it. Returns the loose photo and its frame in window
    /// coordinates, to fall into the basket.
    func pullOff(_ entry: HistoryEntry) -> (layer: CALayer, frame: CGRect)? {
        guard let photo = photos.first(where: { $0.entry == entry && !$0.isEmpty }) else { return nil }
        if hoveredEntry == entry { hoveredEntry = nil }
        return photo.pullOff()
    }

    // MARK: Favorites

    func isFavorite(_ entry: HistoryEntry) -> Bool {
        photos.first { $0.entry == entry }?.isFavorite ?? false
    }

    /// Swaps the photo's clip, with a little pop.
    func setFavorite(_ isFavorite: Bool, for entry: HistoryEntry) {
        photos.first { $0.entry == entry && !$0.isEmpty }?.setFavorite(isFavorite, animated: true)
    }

    /// A favorite was asked to go in the basket: it shakes its head, and a note under it says why.
    func refuseToLetGo(of entry: HistoryEntry) {
        guard let photo = photos.first(where: { $0.entry == entry && !$0.isEmpty }) else { return }
        photo.shake()
        let frame = photo.convert(photo.pictureFrame, to: self)
        showNote("已收藏，木夹子夹得很牢 · 按 F 取消收藏", below: frame)
    }

    private var note: NSTextField?

    private func showNote(_ text: String, below frame: CGRect) {
        note?.removeFromSuperview()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        label.layer?.cornerRadius = 9
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 20, height: 18)
        label.frame = CGRect(x: min(max(frame.midX - size.width / 2, 8), bounds.width - size.width - 8), y: max(frame.minY - size.height - 10, 2),
                             width: size.width, height: size.height)
        addSubview(label)
        note = label
        label.layer?.add(Motion.spring("transform.translation.y", from: 6, to: 0, duration: 0.35), forKey: "rise")
        label.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; label.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak label] in
            guard let label, self?.note === label else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; label.animator().alphaValue = 0 }, completionHandler: {
                MainActor.assumeIsolated { label.removeFromSuperview() }
            })
        }
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
/// rotates around the rope. Dragging the photo just tugs it, and it springs back. Clicking the clip
/// (it opens a little under the mouse) asks for the photo to be let go (`onClipClick`): the clip
/// stays on the rope and the photo falls.
@MainActor
private final class PhotoView: NSView {
    var onPick: ((HistoryEntry) -> Void)?
    var onHover: ((HistoryEntry, Bool) -> Void)?
    var onClipClick: ((HistoryEntry) -> Void)?
    var menuProvider: ((HistoryEntry) -> NSMenu?)?

    /// How far the clip sticks up above the photo, onto the rope.
    static let clipOverhang: CGFloat = 8

    let entry: HistoryEntry
    /// Only the empty clip is left on the line.
    private(set) var isEmpty = false
    /// Hangs from a wooden clip that won't let go.
    private(set) var isFavorite: Bool

    private let hanger = CALayer()
    private let clip = ClipLayer()
    private let thumbnail: CGImage?
    private let restPosition: CGPoint
    private let tilt: CGFloat
    private let period: Double

    private enum Drag {
        case none
        /// Pressed on the photo; `moved` once it has gone further than a click.
        case pressed(start: CGPoint, moved: Bool)
        /// Pressed on the clip.
        case clip
    }

    private var drag = Drag.none
    private var isOverClip = false
    private var photoTip = ""

    /// Where a click opens the clip: a little larger than the clip, for an easy target.
    private var clipTarget: CGRect {
        CGRect(x: restPosition.x - 14, y: restPosition.y - 14, width: 28, height: Self.clipOverhang + 24)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init(entry: HistoryEntry, size: CGSize, thumbnail: CGImage?, isFavorite: Bool, tilt: CGFloat, period: Double) {
        self.entry = entry
        self.isFavorite = isFavorite
        self.tilt = tilt
        self.period = period
        self.thumbnail = thumbnail
        let frame = CGRect(x: 0, y: 0, width: size.width + ClotheslineView.photoPadding, height: size.height + Self.clipOverhang + 10)
        restPosition = CGPoint(x: frame.midX, y: frame.maxY - Self.clipOverhang)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        // Anchored at its top center, where the clip holds it.
        Self.dress(hanger, size: size, thumbnail: self.thumbnail)
        hanger.anchorPoint = CGPoint(x: 0.5, y: 1)
        hanger.position = restPosition
        hanger.transform = CATransform3DMakeRotation(tilt, 0, 0, 1)

        // Hangs from its top, which sits on the rope.
        clip.anchorPoint = CGPoint(x: 0.5, y: 1)
        clip.position = CGPoint(x: size.width / 2, y: size.height + Self.clipOverhang)
        clip.isWooden = isFavorite
        hanger.addSublayer(clip)

        layer?.addSublayer(hanger)
        sway(fast: false)

        var tip = Self.dateFormatter.string(from: entry.createdAt)
        if let app = entry.sourceAppName { tip += " · \(app)" }
        photoTip = "\(tip)\n点一下浮动到屏幕上，按空格预览\n点夹子或按 Delete 扔进洗衣篮，按 F 收藏"
        toolTip = photoTip
    }

    func setFavorite(_ favorite: Bool, animated: Bool) {
        guard favorite != isFavorite else { return }
        isFavorite = favorite
        clip.isWooden = favorite
        guard animated else { return }
        // The new clip pops on, and the photo gives a little nod.
        clip.add(Motion.spring("transform.scale", from: 1.5, to: 1, duration: 0.4, bounce: 0.5), forKey: "pop")
        let nod = Motion.spring("transform.rotation.z", from: favorite ? 0.12 : -0.08, to: 0, duration: 0.6, bounce: 0.5)
        nod.isAdditive = true
        hanger.add(nod, forKey: "nod")
    }

    /// A quick side-to-side "no", like a password field that didn't take.
    func shake() {
        let shake = CAKeyframeAnimation(keyPath: "position.x")
        shake.values = [0, -8, 7, -5, 3, -1, 0]
        shake.keyTimes = [0, 0.15, 0.32, 0.5, 0.68, 0.85, 1]
        shake.duration = 0.45
        shake.isAdditive = true
        hanger.add(shake, forKey: "shake")
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
        // Big photos swing through a smaller angle, so their bottom edge moves about as far.
        let damping = min(1, 100 / max(hanger.bounds.height, 1))
        let swing: CGFloat = (fast ? 0.07 : 0.025) * damping
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
        isOverClip = false
        toolTip = nil
        window?.invalidateCursorRects(for: self)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The clip stays where it was on the rope, hanging from its top.
        let clipTop = CGPoint(x: restPosition.x, y: restPosition.y + Self.clipOverhang)
        clip.removeFromSuperlayer()
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
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        if !isEmpty { addCursorRect(clipTarget, cursor: .pointingHand) }
    }

    override func mouseMoved(with event: NSEvent) {
        setOverClip(!isEmpty && clipTarget.contains(convert(event.locationInWindow, from: nil)))
    }

    /// Under the mouse, the clip opens a little, inviting a click.
    private func setOverClip(_ over: Bool) {
        guard over != isOverClip else { return }
        isOverClip = over
        let current = clip.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat ?? 0
        let target: CGFloat = over ? (isFavorite ? -0.06 : -0.22) : 0
        Motion.immediately { clip.setValue(target, forKeyPath: "transform.rotation.z") }
        clip.add(Motion.spring("transform.rotation.z", from: current, to: target, duration: 0.3, bounce: 0.4), forKey: "ajar")
        toolTip = over ? (isFavorite ? "已收藏，木夹子打不开" : "点夹子松开，扔进洗衣篮") : photoTip
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isEmpty else { return }
        sway(fast: true)
        onHover?(entry, true)
    }

    override func mouseExited(with event: NSEvent) {
        setOverClip(false)
        guard !isEmpty else { return }
        sway(fast: false)
        onHover?(entry, false)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isEmpty else { return }
        if clipTarget.contains(convert(event.locationInWindow, from: nil)) {
            drag = .clip
            // Pinched.
            clip.add(Motion.spring("transform.scale", from: 0.85, to: 1, duration: 0.3, bounce: 0.3), forKey: "pinch")
        } else {
            drag = .pressed(start: event.locationInWindow, moved: false)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        isEmpty ? nil : menuProvider?(entry)
    }

    override func mouseDragged(with event: NSEvent) {
        guard case .pressed(let start, let moved) = drag else { return }
        let point = event.locationInWindow
        let dx = point.x - start.x, dy = point.y - start.y
        guard moved || hypot(dx, dy) >= 4 else { return }
        drag = .pressed(start: start, moved: true)
        // Tugging stretches the photo a little, more and more stiffly; the wooden clip gives less.
        let give: CGFloat = isFavorite ? 0.5 : 1
        Motion.immediately {
            hanger.position = CGPoint(x: restPosition.x + Self.rubberBand(dx, limit: 14 * give),
                                      y: restPosition.y + Self.rubberBand(min(dy, 0), limit: 40 * give))
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = .none }
        switch drag {
        case .none:
            return
        case .clip:
            if clipTarget.contains(convert(event.locationInWindow, from: nil)) { onClipClick?(entry) }
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

/// The clip holding a photo to the rope: a plain plastic one, or a sturdier wooden one with a
/// metal spring for favorites. Drawn hanging down from its top edge.
@MainActor
private final class ClipLayer: CALayer {
    var isWooden = false {
        didSet { redraw() }
    }

    override init() {
        super.init()
        redraw()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func redraw() {
        sublayers?.forEach { $0.removeFromSuperlayer() }
        if isWooden {
            bounds = CGRect(x: 0, y: 0, width: 13, height: 19)
            let wood = CAGradientLayer()
            wood.frame = bounds
            wood.colors = [NSColor(srgbRed: 0.88, green: 0.72, blue: 0.50, alpha: 1).cgColor,
                           NSColor(srgbRed: 0.70, green: 0.50, blue: 0.29, alpha: 1).cgColor]
            wood.startPoint = CGPoint(x: 0, y: 0.5)
            wood.endPoint = CGPoint(x: 1, y: 0.5)
            wood.cornerRadius = 2.5
            wood.borderColor = NSColor(srgbRed: 0.45, green: 0.30, blue: 0.16, alpha: 1).cgColor
            wood.borderWidth = 0.75
            addSublayer(wood)
            // The grain, and the seam between the two halves.
            let grain = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 6.5, y: 1))
            path.addLine(to: CGPoint(x: 6.5, y: 18))
            path.move(to: CGPoint(x: 3.5, y: 2))
            path.addQuadCurve(to: CGPoint(x: 3, y: 17), control: CGPoint(x: 4.5, y: 9))
            path.move(to: CGPoint(x: 9.8, y: 3))
            path.addQuadCurve(to: CGPoint(x: 10, y: 16), control: CGPoint(x: 9, y: 10))
            grain.path = path
            grain.strokeColor = NSColor(srgbRed: 0.45, green: 0.30, blue: 0.16, alpha: 0.55).cgColor
            grain.lineWidth = 0.6
            grain.fillColor = nil
            addSublayer(grain)
            // The metal spring wrapped around the middle.
            let spring = CAGradientLayer()
            spring.frame = CGRect(x: -1.5, y: 8.5, width: 16, height: 4)
            spring.colors = [NSColor(white: 0.95, alpha: 1).cgColor, NSColor(white: 0.42, alpha: 1).cgColor]
            spring.cornerRadius = 2
            spring.borderColor = NSColor(white: 0.3, alpha: 0.8).cgColor
            spring.borderWidth = 0.5
            addSublayer(spring)
        } else {
            bounds = CGRect(x: 0, y: 0, width: 10, height: 15)
            let plastic = CAGradientLayer()
            plastic.frame = bounds
            plastic.colors = [NSColor(srgbRed: 0.98, green: 0.70, blue: 0.25, alpha: 1).cgColor,
                              NSColor(srgbRed: 0.90, green: 0.56, blue: 0.10, alpha: 1).cgColor]
            plastic.startPoint = CGPoint(x: 0, y: 0.5)
            plastic.endPoint = CGPoint(x: 1, y: 0.5)
            plastic.cornerRadius = 2
            addSublayer(plastic)
        }
    }
}
