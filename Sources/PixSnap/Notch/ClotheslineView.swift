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
    /// A photo was dragged far enough to take it to another app: the view to drag from, the
    /// picture's frame and look there, and the mouse event that started it.
    var onDragOut: ((HistoryEntry, NSView, CGRect, NSImage, NSEvent) -> Void)?
    /// Builds a photo's right-click menu.
    var menuForEntry: ((HistoryEntry) -> NSMenu?)?

    /// The photo under the mouse, if any.
    private(set) var hoveredEntry: HistoryEntry?

    /// The captures on the lines in reading order: top line first, left to right.
    var entries: [HistoryEntry] { photos.filter { !$0.isEmpty }.map(\.entry) }

    /// The most recently taken capture on the lines (the end of the top line, not of the last one).
    var newestEntry: HistoryEntry? { entries.max { $0.createdAt < $1.createdAt } }

    static let maximumDays = 3
    /// Above the tallest photo on a line: the rope's distance from the top of its row, its dip,
    /// the gap between rope and photo, the swing room under the photo and the space before the
    /// next line.
    private static let rowOverhead: CGFloat = 24 + 22 + 8 + 12 + 16
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
    /// picture sharp enough for a given longest side in pixels; `moving`, a recording's looping
    /// thumbnail.
    func show(_ plan: Plan, style: RopeStyle, image: (HistoryEntry, CGFloat) -> CGImage?,
              moving: (HistoryEntry) -> (frames: [CGImage], delay: Double)? = { _ in nil }, emptyMessage: String) {
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
                let tangent = line.tangent(at: center / ropeLength)
                let photo = PhotoView(
                    entry: entry,
                    size: size,
                    thumbnail: image(entry, max(size.width, size.height) * scale),
                    moving: moving(entry),
                    isFavorite: entry.isFavorite,
                    tilt: CGFloat(random.next(in: -0.06...0.06)) * min(1, 100 / size.height),
                    period: random.next(in: 1.6...2.8),
                    slope: atan2(tangent.y, tangent.x),
                    ropeClearance: RopeView.clearance(for: style)
                )
                photo.setFrameOrigin(CGPoint(x: clip.x - photo.frame.width / 2, y: clip.y - photo.ropeHeight))
                photo.onPick = { [weak self] entry in self?.onPick?(entry) }
                photo.onClipClick = { [weak self] entry in self?.onClipClick?(entry) }
                photo.onDragOut = { [weak self] entry, view, frame, image, event in self?.onDragOut?(entry, view, frame, image, event) }
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

/// One capture hanging on the line, held the way a real photo peg holds one: the rope runs through
/// the upper part of the clip, the clip's jaws pinch the photo's top edge, and a small gap separates
/// rope and photo. Narrow photos hang from one clip in the middle and swing around it; wide ones
/// from two clips near their corners, following the rope's slope and barely moving.
///
/// A short drag tugs the photo and it springs back; a longer one takes a copy of it to another app
/// (`onDragOut`). Clicking a clip opens it (it parts a little under the mouse): with two clips, that
/// side drops and the photo swings from the other; with the last one, the photo is let go
/// (`onClipClick`) and falls. Opened clips stay on the rope.
@MainActor
private final class PhotoView: NSView {
    var onPick: ((HistoryEntry) -> Void)?
    var onHover: ((HistoryEntry, Bool) -> Void)?
    /// The last clip holding the photo was clicked (or any clip of a favorite).
    var onClipClick: ((HistoryEntry) -> Void)?
    var onDragOut: ((HistoryEntry, NSView, CGRect, NSImage, NSEvent) -> Void)?
    var menuProvider: ((HistoryEntry) -> NSMenu?)?

    /// Drag this far and the photo goes along to other apps, instead of just being tugged.
    private static let dragOutDistance: CGFloat = 30
    /// Photos wider than this, and not taller than wide, get a clip at each top corner; portrait
    /// ones hang from one in the middle.
    private static let twoClipWidth: CGFloat = 130
    /// Room above the rope for the clips' handles.
    private static let headroom = ClipLayer.largestAboveRope + 2
    /// Below the photo, for its shadow and swing.
    private static let footroom: CGFloat = 12

    let entry: HistoryEntry
    /// Only empty clips are left on the line.
    private(set) var isEmpty = false
    /// Hangs from wooden clips that won't let go.
    private(set) var isFavorite: Bool

    /// From the bottom of this view up to where the rope passes, for placing it on the line.
    let ropeHeight: CGFloat

    /// Everything that hangs: the photo, and the clips holding it. Its anchor is on the rope, so it
    /// swings, tilts and drops as one piece.
    private let hanger = CALayer()
    private let photo = CALayer()
    private var clips: [ClipLayer] = []
    private let thumbnail: CGImage?
    private let size: CGSize
    /// Rope to photo top edge.
    private let gap: CGFloat
    /// Where the hanger hangs from, in this view: the rope's middle, or the remaining clip once
    /// one of two has opened.
    private var anchorRest: CGPoint
    /// The rope's angle here; clips left on the rope sit along it.
    private let slope: CGFloat
    /// The resting angle: the rope's slope plus a little randomness (for one clip).
    private var restAngle: CGFloat
    private let period: Double

    private enum Drag {
        case none
        /// Pressed on the photo; `moved` once it has gone further than a click.
        case pressed(start: CGPoint, moved: Bool)
        /// Pressed on a clip.
        case clip(ClipLayer)
    }

    private var drag = Drag.none
    private var hoveredClip: ClipLayer?
    private var photoTip = ""

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// `slope` is the rope's angle where the photo hangs; `ropeClearance` how far the rope reaches
    /// below its center line, so the photo hangs clear of it.
    init(entry: HistoryEntry, size: CGSize, thumbnail: CGImage?, moving: (frames: [CGImage], delay: Double)? = nil,
         isFavorite: Bool, tilt: CGFloat, period: Double, slope: CGFloat, ropeClearance: CGFloat) {
        self.entry = entry
        self.isFavorite = isFavorite
        self.period = period
        self.thumbnail = thumbnail
        self.size = size
        gap = ropeClearance + 4
        let twoClips = size.width > Self.twoClipWidth && size.width >= size.height * 0.85
        // Two clips hold it level along the rope; one lets it hang at its own small angle.
        self.slope = slope
        restAngle = slope + (twoClips ? tilt * 0.15 : tilt)
        let frame = CGRect(x: 0, y: 0, width: size.width + ClotheslineView.photoPadding,
                           height: Self.headroom + gap + size.height + Self.footroom)
        ropeHeight = frame.height - Self.headroom
        anchorRest = CGPoint(x: frame.midX, y: ropeHeight)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        hanger.bounds = CGRect(x: 0, y: 0, width: size.width, height: gap + size.height)
        hanger.anchorPoint = CGPoint(x: 0.5, y: 1)
        hanger.position = anchorRest
        hanger.transform = CATransform3DMakeRotation(restAngle, 0, 0, 1)
        Self.dress(photo, size: size, thumbnail: thumbnail)
        photo.position = CGPoint(x: size.width / 2, y: size.height / 2)
        hanger.addSublayer(photo)
        if let duration = entry.recordingDuration {
            Self.play(moving, on: photo)
            photo.addSublayer(Self.recordingBadge(duration: duration, in: photo.bounds))
        }

        // Clips sit on the hanger's top edge, which is the rope.
        let inset = min(max(size.width * 0.12, 14), 40)
        let xs = twoClips ? [inset, size.width - inset] : [size.width / 2]
        for x in xs {
            let clip = ClipLayer()
            clip.isWooden = isFavorite
            clip.position = CGPoint(x: x, y: gap + size.height)
            clip.zPosition = 1
            hanger.addSublayer(clip)
            clips.append(clip)
        }

        layer?.addSublayer(hanger)
        sway(fast: false)

        var tip = Self.dateFormatter.string(from: entry.createdAt)
        if let app = entry.sourceAppName { tip += " · \(app)" }
        photoTip = "\(tip)\n点一下浮动到屏幕上，按空格预览\n点夹子或按 Delete 扔进洗衣篮，按 F 收藏"
        toolTip = photoTip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The white-bordered print: the hanging photo and the loose copy share it.
    private static func dress(_ layer: CALayer, size: CGSize, thumbnail: CGImage?) {
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.backgroundColor = NSColor(white: 0.97, alpha: 1).cgColor
        layer.cornerRadius = 2
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: -3)
        layer.shadowPath = CGPath(rect: layer.bounds, transform: nil)

        let picture = CALayer()
        picture.frame = layer.bounds.insetBy(dx: 3, dy: 3)
        picture.contents = thumbnail
        picture.contentsGravity = .resizeAspectFill
        picture.masksToBounds = true
        picture.backgroundColor = NSColor(white: 0.85, alpha: 1).cgColor
        layer.addSublayer(picture)
    }

    /// A recording's thumbnail loops on the photo, frame by frame.
    private static func play(_ moving: (frames: [CGImage], delay: Double)?, on photo: CALayer) {
        guard let moving, let picture = photo.sublayers?.first else { return }
        let loop = CAKeyframeAnimation(keyPath: "contents")
        loop.values = moving.frames
        loop.calculationMode = .discrete
        loop.duration = Double(moving.frames.count) * moving.delay
        loop.repeatCount = .infinity
        picture.add(loop, forKey: "loop")
    }

    /// "▶ 0:12" in the photo's bottom-left corner, so a recording reads as one.
    private static func recordingBadge(duration: Double, in bounds: CGRect) -> CALayer {
        let seconds = Int(duration.rounded())
        let text = CATextLayer()
        text.string = String(format: "▶ %d:%02d", seconds / 60, seconds % 60)
        text.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        text.fontSize = 10
        text.foregroundColor = NSColor.white.cgColor
        text.alignmentMode = .center
        text.contentsScale = 2
        let width: CGFloat = 46, height: CGFloat = 16
        let badge = CALayer()
        badge.frame = CGRect(x: 6, y: 6, width: width, height: height)
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        badge.cornerRadius = height / 2
        text.frame = CGRect(x: 0, y: 1.5, width: width, height: height - 2)
        badge.addSublayer(text)
        return badge
    }

    // MARK: Motion

    private func sway(fast: Bool) {
        guard !isEmpty else { return }
        // Held at two corners it hardly moves; big photos swing through a smaller angle so their
        // bottom edge travels about as far as a small one's.
        let held: CGFloat = clips.count > 1 ? 0.15 : 1
        let damping = min(1, 100 / max(size.height, 1))
        let swing: CGFloat = (fast ? 0.07 : 0.025) * damping * held
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = restAngle - swing
        animation.toValue = restAngle + swing
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

    func setFavorite(_ favorite: Bool, animated: Bool) {
        guard favorite != isFavorite else { return }
        isFavorite = favorite
        for clip in clips {
            clip.isWooden = favorite
            if animated { clip.add(Motion.spring("transform.scale", from: 1.5, to: 1, duration: 0.4, bounce: 0.5), forKey: "pop") }
        }
        guard animated else { return }
        // The photo gives a little nod.
        let nod = Motion.spring("transform.rotation.z", from: favorite ? 0.08 : -0.05, to: 0, duration: 0.6, bounce: 0.5)
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

    /// The photo's frame in this view, ignoring any tilt.
    var pictureFrame: CGRect {
        let center = hanger.convert(photo.position, to: layer)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    // MARK: Coming off the line

    /// Opens one of two clips: that side drops, and the photo swings down to hang from the other,
    /// its weight settling straight below it.
    private func open(_ clip: ClipLayer) {
        guard let remaining = clips.first(where: { $0 !== clip }) else { return }
        leaveOnRope(clip)
        clips.removeAll { $0 === clip }

        // Re-hang from the remaining clip without moving anything on screen.
        let current = hanger.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat ?? restAngle
        let pivotInHanger = remaining.position
        Motion.immediately {
            hanger.removeAllAnimations()
            hanger.transform = CATransform3DMakeRotation(current, 0, 0, 1)
        }
        let pivot = hanger.convert(pivotInHanger, to: layer)
        Motion.immediately {
            hanger.anchorPoint = CGPoint(x: pivotInHanger.x / hanger.bounds.width, y: 1)
            hanger.position = pivot
        }
        anchorRest = pivot
        // Hanging from a corner, the photo turns until its center is under the clip.
        let reach = size.width / 2 - pivotInHanger.x
        let swing = -atan2(reach, gap + size.height / 2)
        restAngle = swing
        Motion.immediately { hanger.setValue(swing, forKeyPath: "transform.rotation.z") }
        hanger.add(Motion.spring("transform.rotation.z", from: current, to: swing, duration: 0.9, bounce: 0.35), forKey: "swingDown")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.sway(fast: false) }
        window?.invalidateCursorRects(for: self)
    }

    /// A clip that let go stays on the rope where it was, flicking up as the weight comes off.
    private func leaveOnRope(_ clip: ClipLayer) {
        let onRope = hanger.convert(clip.position, to: layer)
        Motion.immediately {
            clip.removeFromSuperlayer()
            clip.removeAllAnimations()
            clip.transform = CATransform3DMakeRotation(slope, 0, 0, 1)
            clip.position = onRope
            layer?.addSublayer(clip)
        }
        clip.add(Motion.spring("transform.rotation.z", from: slope + 0.55, to: slope, duration: 0.5, bounce: 0.55), forKey: "snap")
        if hoveredClip === clip { hoveredClip = nil }
    }

    /// Lets go of the photo: the clips stay on the rope and the hanging photo disappears. Returns a
    /// loose copy, turned the way the photo was, and where it was, in window coordinates.
    func pullOff() -> (layer: CALayer, frame: CGRect) {
        let presented = hanger.presentation() ?? hanger
        let center = presented.convert(photo.position, to: layer)
        let angle = presented.value(forKeyPath: "transform.rotation.z") as? CGFloat ?? restAngle
        let frame = convert(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), to: nil)
        let loose = CALayer()
        Self.dress(loose, size: size, thumbnail: thumbnail)
        loose.transform = CATransform3DMakeRotation(angle, 0, 0, 1)

        isEmpty = true
        hoveredClip = nil
        toolTip = nil
        window?.invalidateCursorRects(for: self)
        clips.forEach(leaveOnRope)
        clips = []
        Motion.immediately {
            hanger.removeAllAnimations()
            hanger.isHidden = true
        }
        return (loose, frame)
    }

    // MARK: Mouse

    /// Where a click opens a clip: a little larger than the clip, for an easy target.
    private func target(of clip: ClipLayer) -> CGRect {
        let center = hanger.convert(clip.position, to: layer)
        return CGRect(x: center.x - 13, y: center.y - ClipLayer.largestBelowRope - 2, width: 26,
                      height: ClipLayer.largestBelowRope + ClipLayer.largestAboveRope + 4)
    }

    private func clip(at point: CGPoint) -> ClipLayer? {
        clips.first { target(of: $0).contains(point) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        for clip in clips where !isEmpty { addCursorRect(target(of: clip), cursor: .pointingHand) }
    }

    override func mouseMoved(with event: NSEvent) {
        setHoveredClip(isEmpty ? nil : clip(at: convert(event.locationInWindow, from: nil)))
    }

    /// Under the mouse, a clip parts a little, inviting a click.
    private func setHoveredClip(_ clip: ClipLayer?) {
        guard clip !== hoveredClip else { return }
        hoveredClip?.setAjar(false)
        hoveredClip = clip
        clip?.setAjar(true, barely: isFavorite)
        toolTip = clip == nil ? photoTip : (isFavorite ? "已收藏，木夹子打不开" : "点夹子松开，扔进洗衣篮")
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isEmpty else { return }
        sway(fast: true)
        onHover?(entry, true)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredClip(nil)
        guard !isEmpty else { return }
        sway(fast: false)
        onHover?(entry, false)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isEmpty else { return }
        if let clip = clip(at: convert(event.locationInWindow, from: nil)) {
            drag = .clip(clip)
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
        if hypot(dx, dy) >= Self.dragOutDistance, let thumbnail {
            drag = .none
            springBack()
            onDragOut?(entry, self, pictureFrame, NSImage(cgImage: thumbnail, size: size), event)
            return
        }
        // Tugging stretches the photo a little, more and more stiffly; wooden clips give less.
        let give: CGFloat = isFavorite ? 0.5 : 1
        let rest = anchorRest
        Motion.immediately {
            hanger.position = CGPoint(x: rest.x + Self.rubberBand(dx, limit: 14 * give),
                                      y: rest.y + Self.rubberBand(min(dy, 0), limit: 40 * give))
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = .none }
        switch drag {
        case .none:
            return
        case .clip(let clip):
            guard target(of: clip).contains(convert(event.locationInWindow, from: nil)) else { return }
            // A favorite's clips don't open; the last clip lets the photo go.
            if isFavorite || clips.count == 1 { onClipClick?(entry) } else { open(clip) }
        case .pressed(_, let moved):
            if moved { springBack() } else { onPick?(entry) }
        }
    }

    /// Not pulled hard enough: the clip snaps the photo back up.
    private func springBack() {
        let rest = anchorRest
        let back = Motion.spring("position", from: NSValue(point: hanger.position), to: NSValue(point: rest), duration: 0.45, bounce: 0.35)
        Motion.immediately { hanger.position = rest }
        hanger.add(back, forKey: "springBack")
    }

    /// The system's scroll-bounce curve: moves freely at first, then less and less toward `limit`.
    private static func rubberBand(_ offset: CGFloat, limit: CGFloat) -> CGFloat {
        let stretched = limit * (1 - 1 / (abs(offset) * 0.55 / limit + 1))
        return offset < 0 ? -stretched : stretched
    }
}

/// A photo peg: two long prongs held by a metal spring. The rope runs through the notch in its
/// upper part (the layer's anchor point, so it sits on the rope and turns around it) and the jaws
/// below pinch the photo. Plain ones are plastic; favorites get a sturdier wooden one.
@MainActor
private final class ClipLayer: CALayer {
    /// How far the largest clip reaches above and below the rope.
    static let largestAboveRope: CGFloat = 9
    static let largestBelowRope: CGFloat = 19
    /// The notch the rope runs through, as a fraction of the height from the top.
    private static let notch: CGFloat = 0.32

    var isWooden = false {
        didSet { redraw() }
    }

    override init() {
        super.init()
        anchorPoint = CGPoint(x: 0.5, y: 1 - Self.notch)
        redraw()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Parts the prongs a little (or, for wood, hardly at all).
    func setAjar(_ ajar: Bool, barely: Bool = false) {
        let current = presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat ?? 0
        let target: CGFloat = ajar ? (barely ? -0.05 : -0.2) : 0
        Motion.immediately { setValue(target, forKeyPath: "transform.rotation.z") }
        add(Motion.spring("transform.rotation.z", from: current, to: target, duration: 0.3, bounce: 0.4), forKey: "ajar")
    }

    private func redraw() {
        sublayers?.forEach { $0.removeFromSuperlayer() }
        let size = isWooden ? CGSize(width: 11, height: 28) : CGSize(width: 9, height: 26)
        bounds = CGRect(origin: .zero, size: size)
        let light = isWooden ? NSColor(srgbRed: 0.88, green: 0.72, blue: 0.50, alpha: 1) : NSColor(srgbRed: 0.98, green: 0.71, blue: 0.27, alpha: 1)
        let dark = isWooden ? NSColor(srgbRed: 0.68, green: 0.48, blue: 0.27, alpha: 1) : NSColor(srgbRed: 0.88, green: 0.54, blue: 0.10, alpha: 1)
        let edge = isWooden ? NSColor(srgbRed: 0.42, green: 0.28, blue: 0.14, alpha: 1) : NSColor(srgbRed: 0.70, green: 0.40, blue: 0.05, alpha: 1)

        // The two prongs, slightly tapered toward the jaws, rounded at the handle end.
        let w = size.width, h = size.height
        for (left, right) in [(CGFloat(0), w / 2), (w / 2, w)] {
            let prong = CAGradientLayer()
            prong.frame = CGRect(x: left, y: 0, width: right - left, height: h)
            prong.colors = left == 0 ? [light.cgColor, dark.cgColor] : [dark.cgColor, light.blended(withFraction: 0.3, of: dark)!.cgColor]
            prong.startPoint = CGPoint(x: 0, y: 0.5)
            prong.endPoint = CGPoint(x: 1, y: 0.5)
            let shape = CAShapeLayer()
            let path = CGMutablePath()
            let outer = left == 0 ? CGFloat(0) : right - left
            let inner = left == 0 ? right - left : 0
            path.move(to: CGPoint(x: inner, y: 0))
            path.addLine(to: CGPoint(x: outer + (left == 0 ? 1.2 : -1.2), y: 0))
            path.addLine(to: CGPoint(x: outer, y: h - 3))
            path.addQuadCurve(to: CGPoint(x: inner, y: h), control: CGPoint(x: outer, y: h))
            path.closeSubpath()
            shape.path = path
            prong.mask = shape
            addSublayer(prong)
        }
        // Outline and the seam between the prongs.
        let outline = CAShapeLayer()
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: 0.4, y: 0.4, width: w - 0.8, height: h - 0.8), cornerWidth: 2.5, cornerHeight: 2.5)
        path.move(to: CGPoint(x: w / 2, y: 0.5))
        path.addLine(to: CGPoint(x: w / 2, y: h - 1))
        outline.path = path
        outline.fillColor = nil
        outline.strokeColor = edge.withAlphaComponent(0.7).cgColor
        outline.lineWidth = 0.7
        addSublayer(outline)
        if isWooden {
            let grain = CAShapeLayer()
            let lines = CGMutablePath()
            lines.move(to: CGPoint(x: 2.5, y: 2))
            lines.addQuadCurve(to: CGPoint(x: 2.3, y: h - 3), control: CGPoint(x: 3.6, y: h / 2))
            lines.move(to: CGPoint(x: w - 2.6, y: 3))
            lines.addQuadCurve(to: CGPoint(x: w - 2.4, y: h - 4), control: CGPoint(x: w - 3.5, y: h / 2))
            grain.path = lines
            grain.strokeColor = edge.withAlphaComponent(0.45).cgColor
            grain.lineWidth = 0.5
            grain.fillColor = nil
            addSublayer(grain)
        }
        // The notch the rope sits in: a small dark groove across, at the anchor.
        let groove = CALayer()
        groove.frame = CGRect(x: -0.5, y: h * (1 - Self.notch) - 1, width: w + 1, height: 2)
        groove.backgroundColor = edge.withAlphaComponent(0.55).cgColor
        groove.cornerRadius = 1
        addSublayer(groove)
        // The metal spring wrapped around both prongs, between the notch and the jaws.
        let spring = CAGradientLayer()
        spring.frame = CGRect(x: -1.5, y: h * 0.42 - 2, width: w + 3, height: 4)
        spring.colors = [NSColor(white: 0.95, alpha: 1).cgColor, NSColor(white: 0.45, alpha: 1).cgColor]
        spring.cornerRadius = 2
        spring.borderColor = NSColor(white: 0.3, alpha: 0.8).cgColor
        spring.borderWidth = 0.5
        addSublayer(spring)
        // A soft shadow onto the photo below.
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.35
        shadowRadius = 1.5
        shadowOffset = CGSize(width: 0.5, height: -1)
    }
}
