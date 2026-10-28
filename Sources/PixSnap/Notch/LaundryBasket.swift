import AppKit
import PixSnapCore

/// The wicker laundry basket at the bottom of the screen. Photos pulled off the line fall into it,
/// and the newest few peek out over the rim. Clicking it opens `BasketPanel`.
@MainActor
final class BasketView: NSView {
    var onClick: (() -> Void)?

    static let size = CGSize(width: 136, height: 100)
    /// Where falling photos aim, in this view's coordinates: just inside the rim.
    var mouth: CGPoint { CGPoint(x: bounds.midX, y: Self.rimY + 4) }

    private static let bodyHeight: CGFloat = 68
    private static let rimY: CGFloat = 64
    private static let wicker = NSColor(srgbRed: 0.80, green: 0.62, blue: 0.38, alpha: 1)
    private static let darkWicker = NSColor(srgbRed: 0.55, green: 0.38, blue: 0.20, alpha: 1)

    private let peeking = CALayer()
    private let badge = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "洗衣篮 · 点一下挑回来")

    /// The basket's contents, most recently thrown first.
    var entries: [HistoryEntry] = [] {
        didSet { updateContents() }
    }

    override init(frame: CGRect) {
        super.init(frame: CGRect(origin: frame.origin, size: Self.size))
        wantsLayer = true
        layer?.masksToBounds = false

        // The photos sit behind the front of the basket, so only their tops show over the rim.
        layer?.addSublayer(peeking)
        drawBasket()

        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        badge.layer?.cornerRadius = 9
        addSubview(badge)

        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = .white
        hint.alignment = .center
        hint.wantsLayer = true
        hint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        hint.layer?.cornerRadius = 8
        hint.alphaValue = 0
        hint.sizeToFit()
        hint.frame = CGRect(x: (bounds.width - hint.frame.width - 16) / 2, y: bounds.height + 4, width: hint.frame.width + 16, height: 18)
        addSubview(hint)
        toolTip = "扔进来的截图 \(HistoryLibrary.basketDays) 天后自动清理"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHintShown(!entries.isEmpty) }
    override func mouseExited(with event: NSEvent) { setHintShown(false) }
    override func mouseUp(with event: NSEvent) { onClick?() }

    private func setHintShown(_ shown: Bool) {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; hint.animator().alphaValue = shown ? 1 : 0 }
    }

    /// A photo just landed: the basket squashes a little and springs back.
    func bounce() {
        layer?.add(Motion.spring("transform", from: NSValue(caTransform3D: Self.squash(1.08, 0.9, in: bounds)),
                                 to: NSValue(caTransform3D: CATransform3DIdentity), duration: 0.45, bounce: 0.45), forKey: "bounce")
    }

    /// Emptying: the basket tips over its left corner, the photos inside spill out and dissolve,
    /// then it rights itself with a wobble. `completion` runs once it's upright again.
    func tipOut(completion: @escaping () -> Void) {
        guard let layer else { return completion() }
        let spilled = peeking.sublayers ?? []
        // Tip over: the view's layer turns around its bottom-left corner.
        layer.add(Motion.spring("transform.rotation.z", from: 0, to: 0.5, duration: 0.35, bounce: 0.15), forKey: "tip")
        Motion.immediately { layer.setValue(0.5, forKeyPath: "transform.rotation.z") }

        for (index, photo) in spilled.enumerated() {
            let start = photo.position
            let path = CGMutablePath()
            path.move(to: start)
            let end = CGPoint(x: start.x - 90 - CGFloat(index) * 30, y: start.y - 30 + CGFloat(index) * 14)
            path.addQuadCurve(to: end, control: CGPoint(x: start.x - 30, y: start.y + 60 + CGFloat(index) * 10))
            let fly = CAKeyframeAnimation(keyPath: "position")
            fly.path = path
            fly.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.toValue = 0.8 + Double(index) * 0.3
            // A soft "poof": they swell slightly as they fade, rather than just vanishing.
            let poof = CAKeyframeAnimation(keyPath: "transform.scale")
            poof.values = [1, 1, 1.35]
            poof.keyTimes = [0, 0.55, 1]
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]
            fade.keyTimes = [0, 0.5, 1]
            let group = CAAnimationGroup()
            group.animations = [fly, spin, poof, fade]
            group.duration = 0.5
            group.beginTime = CACurrentMediaTime() + 0.08 + Double(index) * 0.05
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            photo.add(group, forKey: "spill")
        }
        badge.animator().alphaValue = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let layer = self.layer else { return }
            Motion.immediately { layer.setValue(0, forKeyPath: "transform.rotation.z") }
            Motion.run(on: layer, ["tip": Motion.spring("transform.rotation.z", from: 0.5, to: 0, duration: 0.5, bounce: 0.4)]) {
                self.badge.alphaValue = 1
                completion()
            }
        }
    }

    // MARK: Drawing

    private func drawBasket() {
        let width = bounds.width, inset: CGFloat = 12
        // Body: wider at the top, slightly rounded at the bottom.
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 2, y: Self.rimY))
        body.addLine(to: CGPoint(x: inset, y: 6))
        body.addQuadCurve(to: CGPoint(x: inset + 8, y: 0), control: CGPoint(x: inset, y: 0))
        body.addLine(to: CGPoint(x: width - inset - 8, y: 0))
        body.addQuadCurve(to: CGPoint(x: width - inset, y: 6), control: CGPoint(x: width - inset, y: 0))
        body.addLine(to: CGPoint(x: width - 2, y: Self.rimY))
        body.closeSubpath()

        let fill = CAShapeLayer()
        fill.path = body
        fill.fillColor = Self.wicker.cgColor
        fill.strokeColor = Self.darkWicker.cgColor
        fill.lineWidth = 1.5
        fill.shadowColor = NSColor.black.cgColor
        fill.shadowOpacity = 0.4
        fill.shadowRadius = 6
        fill.shadowOffset = CGSize(width: 0, height: -3)
        layer?.addSublayer(fill)

        // The weave: rows of strands with uprights between them, clipped to the body.
        let weave = CAShapeLayer()
        let strands = CGMutablePath()
        var y: CGFloat = 8
        while y < Self.rimY - 4 {
            strands.move(to: CGPoint(x: 0, y: y))
            strands.addLine(to: CGPoint(x: width, y: y))
            y += 9
        }
        for x in stride(from: CGFloat(18), to: width - 10, by: 14) {
            // Uprights lean outward toward the top, following the sides.
            let lean = (x - width / 2) / (width / 2) * 8
            strands.move(to: CGPoint(x: x, y: 0))
            strands.addLine(to: CGPoint(x: x + lean, y: Self.rimY))
        }
        weave.path = strands
        weave.strokeColor = Self.darkWicker.withAlphaComponent(0.55).cgColor
        weave.lineWidth = 1.2
        let mask = CAShapeLayer()
        mask.path = body
        weave.mask = mask
        layer?.addSublayer(weave)

        // The rim, with a handle hole on each side.
        let rim = CAShapeLayer()
        rim.path = CGPath(roundedRect: CGRect(x: 0, y: Self.rimY - 4, width: width, height: 11), cornerWidth: 5, cornerHeight: 5, transform: nil)
        rim.fillColor = Self.darkWicker.cgColor
        layer?.addSublayer(rim)
        for x in [CGFloat(16), width - 36] {
            let hole = CAShapeLayer()
            hole.path = CGPath(roundedRect: CGRect(x: x, y: Self.rimY - 18, width: 20, height: 8), cornerWidth: 4, cornerHeight: 4, transform: nil)
            hole.fillColor = NSColor(srgbRed: 0.30, green: 0.20, blue: 0.10, alpha: 1).cgColor
            layer?.addSublayer(hole)
        }
    }

    private func updateContents() {
        peeking.sublayers?.forEach { $0.removeFromSuperlayer() }
        for (index, entry) in entries.prefix(3).reversed().enumerated() {
            let size = ClotheslineLayout.photoSize(pixelWidth: entry.pixelWidth, pixelHeight: entry.pixelHeight)
            let scale = 46 / max(size.width, size.height)
            let photo = CALayer()
            photo.bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
            photo.position = CGPoint(x: bounds.midX + CGFloat(index - 1) * 26, y: Self.rimY + 6)
            photo.backgroundColor = NSColor(white: 0.97, alpha: 1).cgColor
            photo.borderColor = NSColor(white: 0.97, alpha: 1).cgColor
            photo.borderWidth = 2
            photo.contents = HistoryLibrary.shared.thumbnail(for: entry)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            photo.contentsGravity = .resizeAspectFill
            photo.masksToBounds = true
            photo.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(index - 1) * 0.25))
            peeking.addSublayer(photo)
        }

        badge.isHidden = entries.isEmpty
        badge.stringValue = "\(entries.count)"
        badge.sizeToFit()
        let badgeWidth = max(18, badge.frame.width + 8)
        badge.frame = CGRect(x: bounds.width - badgeWidth + 4, y: Self.rimY + 2, width: badgeWidth, height: 18)
    }

    /// Squashed about the middle of the bottom edge, where the basket sits.
    private static func squash(_ x: CGFloat, _ y: CGFloat, in bounds: CGRect) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(bounds.midX, 0, 0)
        transform = CATransform3DScale(transform, x, y, 1)
        return CATransform3DTranslate(transform, -bounds.midX, 0, 0)
    }
}

/// What's in the basket, opened above it: click a capture to hang it back on the line, hang them
/// all back, or empty the basket for good (asks once more first).
@MainActor
final class BasketPanel: NSView {
    var onRestore: (([HistoryEntry]) -> Void)?
    /// One capture deleted for good.
    var onDelete: ((HistoryEntry) -> Void)?
    var onEmpty: (() -> Void)?

    private static let cellSize = CGSize(width: 88, height: 74)
    private static let columns = 6
    private static let padding: CGFloat = 16

    private let entries: [HistoryEntry]
    private let emptyButton = NSButton(title: "倒掉篮子", target: nil, action: nil)
    private var confirmingEmpty = false

    init(entries: [HistoryEntry]) {
        self.entries = entries
        // At most four rows; the newest throws first.
        let shown = Array(entries.prefix(Self.columns * 4))
        let rows = max(1, Int(ceil(Double(shown.count) / Double(Self.columns))))
        let width = Self.padding * 2 + CGFloat(min(Self.columns, max(shown.count, 3))) * Self.cellSize.width
        let height = Self.padding * 2 + 26 + 18 + CGFloat(rows) * Self.cellSize.height + 36
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.88).cgColor
        layer?.cornerRadius = 12
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        layer?.borderWidth = 1

        let title = NSTextField(labelWithString: "洗衣篮 · \(entries.count) 张")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        title.sizeToFit()
        title.setFrameOrigin(CGPoint(x: Self.padding, y: height - Self.padding - title.frame.height))
        addSubview(title)

        let note = NSTextField(labelWithString: "点一下挂回绳上 · 点 × 删除 · \(HistoryLibrary.basketDays) 天后自动清理")
        note.font = .systemFont(ofSize: 11)
        note.textColor = NSColor(white: 1, alpha: 0.6)
        note.sizeToFit()
        // On its own line under the title, so it fits however narrow the basket is.
        note.setFrameOrigin(CGPoint(x: Self.padding, y: title.frame.minY - 4 - note.frame.height))
        addSubview(note)

        for (index, entry) in shown.enumerated() {
            let column = index % Self.columns, row = index / Self.columns
            let cell = BasketCell(entry: entry)
            cell.setFrameOrigin(CGPoint(x: Self.padding + CGFloat(column) * Self.cellSize.width,
                                        y: note.frame.minY - 8 - CGFloat(row + 1) * Self.cellSize.height))
            cell.onClick = { [weak self] entry in self?.onRestore?([entry]) }
            cell.onDelete = { [weak self] entry in self?.onDelete?(entry) }
            addSubview(cell)
        }

        let restoreAll = NSButton(title: "全部挂回去", target: self, action: #selector(restoreAll))
        restoreAll.bezelStyle = .rounded
        restoreAll.sizeToFit()
        restoreAll.setFrameOrigin(CGPoint(x: Self.padding, y: Self.padding - 4))
        addSubview(restoreAll)

        emptyButton.target = self
        emptyButton.action = #selector(emptyTapped)
        emptyButton.bezelStyle = .rounded
        emptyButton.hasDestructiveAction = true
        layOutEmptyButton()
        addSubview(emptyButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Grows up out of the basket below it, like a popover.
    func appear() {
        guard let layer else { return }
        layer.add(Motion.spring("transform", from: NSValue(caTransform3D: grown(0.9)), to: NSValue(caTransform3D: CATransform3DIdentity),
                                duration: 0.35, bounce: 0.2), forKey: "appear")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.duration = 0.18
        layer.add(fade, forKey: "fade")
    }

    /// Shrinks back toward the basket and removes itself.
    func disappear() {
        guard let layer else { return removeFromSuperview() }
        let end = grown(0.94)
        Motion.immediately {
            layer.transform = end
            layer.opacity = 0
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.duration = 0.15
        Motion.run(on: layer, ["appear": Motion.spring("transform", from: NSValue(caTransform3D: CATransform3DIdentity),
                                                         to: NSValue(caTransform3D: end), duration: 0.25), "fade": fade]) { [weak self] in
            self?.removeFromSuperview()
        }
    }

    /// Scaled about the middle of the bottom edge, which points at the basket.
    private func grown(_ scale: CGFloat) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(bounds.midX, 0, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -bounds.midX, 0, 0)
    }

    @objc private func restoreAll() {
        onRestore?(entries)
    }

    /// The first click asks; a second click within a few seconds empties the basket.
    @objc private func emptyTapped() {
        if confirmingEmpty {
            onEmpty?()
            return
        }
        confirmingEmpty = true
        emptyButton.title = "确定删除 \(entries.count) 张？无法恢复"
        emptyButton.contentTintColor = .systemRed
        layOutEmptyButton()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.confirmingEmpty else { return }
            self.confirmingEmpty = false
            self.emptyButton.title = "倒掉篮子"
            self.emptyButton.contentTintColor = nil
            self.layOutEmptyButton()
        }
    }

    private func layOutEmptyButton() {
        emptyButton.sizeToFit()
        emptyButton.setFrameOrigin(CGPoint(x: bounds.width - Self.padding - emptyButton.frame.width, y: Self.padding - 4))
    }
}

/// One capture in the basket, with how long it has left. Hovering shows an × that deletes it for
/// good (a second click confirms); right-click has the same, and hanging it back.
@MainActor
private final class BasketCell: NSView {
    var onClick: ((HistoryEntry) -> Void)?
    var onDelete: ((HistoryEntry) -> Void)?
    private let entry: HistoryEntry
    private let left = NSTextField(labelWithString: "")
    private let deleteButton = NSButton()
    private var confirmingDelete = false

    init(entry: HistoryEntry) {
        self.entry = entry
        super.init(frame: CGRect(x: 0, y: 0, width: 88, height: 74))
        wantsLayer = true

        let picture = CALayer()
        let size = ClotheslineLayout.photoSize(pixelWidth: entry.pixelWidth, pixelHeight: entry.pixelHeight)
        let scale = min(76 / size.width, 50 / size.height)
        picture.frame = CGRect(x: (bounds.width - size.width * scale) / 2, y: 18 + (50 - size.height * scale) / 2,
                               width: size.width * scale, height: size.height * scale)
        picture.contents = HistoryLibrary.shared.thumbnail(for: entry)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        picture.contentsGravity = .resizeAspectFill
        picture.masksToBounds = true
        picture.borderColor = NSColor(white: 0.97, alpha: 1).cgColor
        picture.borderWidth = 2
        picture.cornerRadius = 2
        layer?.addSublayer(picture)

        left.stringValue = Self.remaining(for: entry)
        left.font = .systemFont(ofSize: 10)
        left.textColor = NSColor(white: 1, alpha: 0.6)
        left.alignment = .center
        left.frame = CGRect(x: 0, y: 2, width: bounds.width, height: 14)
        addSubview(left)
        toolTip = "挂回绳上"

        deleteButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "永久删除")
        deleteButton.isBordered = false
        deleteButton.imageScaling = .scaleProportionallyUpOrDown
        deleteButton.contentTintColor = NSColor(white: 0.85, alpha: 1)
        deleteButton.frame = CGRect(x: bounds.width - 20, y: bounds.height - 20, width: 18, height: 18)
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.toolTip = "永久删除（点两下确认）"
        deleteButton.isHidden = true
        addSubview(deleteButton)
    }

    /// The first click asks; a second click within a few seconds deletes.
    @objc private func deleteClicked() {
        if confirmingDelete { return onDelete?(entry) ?? () }
        confirmingDelete = true
        deleteButton.contentTintColor = .systemRed
        left.stringValue = "再点一下删除"
        left.textColor = .systemRed
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, confirmingDelete else { return }
            confirmingDelete = false
            deleteButton.contentTintColor = NSColor(white: 0.85, alpha: 1)
            left.stringValue = Self.remaining(for: entry)
            left.textColor = NSColor(white: 1, alpha: 0.6)
            deleteButton.isHidden = !isHovered
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let restore = NSMenuItem(title: "挂回绳上", action: #selector(restoreFromMenu), keyEquivalent: "")
        restore.target = self
        menu.addItem(restore)
        let delete = NSMenuItem(title: "永久删除", action: #selector(deleteFromMenu), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
        return menu
    }

    @objc private func restoreFromMenu() { onClick?(entry) }
    @objc private func deleteFromMenu() { onDelete?(entry) }

    private var isHovered = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === deleteButton ? deleteButton : self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// "还剩 6 天", or "今天清理" on the last day.
    private static func remaining(for entry: HistoryEntry) -> String {
        guard let thrown = entry.trashedAt else { return "" }
        let left = Double(HistoryLibrary.basketDays) - Date().timeIntervalSince(thrown) / 86_400
        return left < 1 ? "今天清理" : "还剩 \(Int(left.rounded(.up))) 天"
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
        layer?.cornerRadius = 6
        deleteButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = nil
        if !confirmingDelete { deleteButton.isHidden = true }
    }

    override func mouseUp(with event: NSEvent) { onClick?(entry) }
}
