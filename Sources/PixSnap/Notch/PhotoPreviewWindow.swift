import AppKit
import PixSnapCore

/// The space-bar preview: the capture zooms out of its photo on the clothesline to a large card
/// over a blurred, dimmed screen, with when and where it was taken underneath. ← → slide to the
/// neighbors; closing shrinks the card back into its photo. Everything moves on system springs and
/// starts from wherever the previous motion was, so quick presses never jump. It never becomes key,
/// so the clothesline keeps the keyboard (space, arrows, Return, Esc). Clicking the picture floats
/// it; clicking around it closes the preview.
@MainActor
final class PhotoPreviewWindow: NSPanel {
    var onPick: ((HistoryEntry) -> Void)?
    var onClose: (() -> Void)?

    /// The capture being shown; nil while hidden or closing.
    private(set) var entry: HistoryEntry?

    private let backdrop = NSVisualEffectView()
    private let dim = NSView()
    /// Hosts the cards, above the backdrop.
    private let stage = NSView()
    /// The picture being shown, at its final frame; motion is all in its transform.
    private var card: CALayer?
    private let caption = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "← → 切换 · 空格或 Esc 关闭 · 点击图片浮动到屏幕上 · Delete 扔进洗衣篮")
    private var source: CGRect?

    private static let captionHeight: CGFloat = 48
    private static let cornerRadius: CGFloat = 10
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    init(screenFrame: CGRect, level: NSWindow.Level) {
        super.init(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let content = ClickView()
        content.onClick = { [weak self] point in self?.clicked(at: point) }
        contentView = content

        backdrop.material = .fullScreenUI
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.appearance = NSAppearance(named: .darkAqua)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        for view in [backdrop, dim, stage] {
            view.frame = content.bounds
            view.autoresizingMask = [.width, .height]
            content.addSubview(view)
        }
        stage.wantsLayer = true

        for label in [caption, hint] {
            label.alignment = .center
            label.textColor = .white
            label.wantsLayer = true
            content.addSubview(label)
        }
        caption.font = .systemFont(ofSize: 13, weight: .semibold)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor(white: 1, alpha: 0.7)
    }

    override var canBecomeKey: Bool { false }

    /// Shows `entry`: zooming out of `source` (a screen rect) when opening, or sliding in from the
    /// side `direction` points to (-1 left, 1 right) when switching.
    func show(_ entry: HistoryEntry, from source: CGRect?, direction: Int = 0) {
        guard let capture = HistoryLibrary.shared.loadCapture(entry) else { return }
        let opening = self.entry == nil
        self.entry = entry
        self.source = source.map(local)
        ignoresMouseEvents = false

        var details = [Self.timeFormatter.string(from: entry.createdAt)]
        if let app = entry.sourceAppName { details.append(app) }
        details.append("\(entry.pixelWidth) × \(entry.pixelHeight)")
        caption.stringValue = details.joined(separator: " · ")

        let target = targetFrame(for: capture.pointSize)
        let incoming = makeCard(capture.image, frame: target)
        let outgoing = card
        card = incoming
        stage.layer?.addSublayer(incoming)

        if opening, outgoing == nil {
            orderFrontRegardless()
            fadeChrome(in: true, below: target)
            if let start = self.source {
                incoming.add(Motion.spring("transform", from: NSValue(caTransform3D: Motion.transform(from: start, to: target)),
                                           to: NSValue(caTransform3D: CATransform3DIdentity), duration: 0.45, bounce: 0.1), forKey: "zoom")
            } else {
                incoming.add(Motion.spring("transform.scale", from: 0.9, to: 1, duration: 0.4), forKey: "zoom")
                incoming.add(fade(from: 0, to: 1, duration: 0.2), forKey: "fade")
            }
        } else {
            // Reopened mid-close, or switching: the old card makes way.
            if let outgoing { slideAway(outgoing, toward: -direction) }
            let offset = CGFloat(direction) * 80
            var from = CATransform3DMakeTranslation(offset, 0, 0)
            from = CATransform3DScale(from, 0.96, 0.96, 1)
            incoming.add(Motion.spring("transform", from: NSValue(caTransform3D: from),
                                       to: NSValue(caTransform3D: CATransform3DIdentity), duration: 0.4), forKey: "slide")
            incoming.add(fade(from: 0, to: 1, duration: 0.22), forKey: "fade")
            fadeChrome(in: true, below: target)
        }
    }

    /// Shrinks back into the photo on the line, if it's still there, and hides.
    func dismiss(animated: Bool = true) {
        guard entry != nil, let card else { return }
        entry = nil
        ignoresMouseEvents = true
        guard animated else {
            removeCard(card)
            orderOut(nil)
            return
        }
        let current = card.presentation()?.transform ?? card.transform
        let end = source.map { Motion.transform(from: $0, to: card.frame) }
            ?? CATransform3DMakeScale(0.92, 0.92, 1)
        Motion.immediately { card.transform = end }
        card.add(Motion.spring("transform", from: NSValue(caTransform3D: current), to: NSValue(caTransform3D: end), duration: 0.38), forKey: "zoom")
        // Into the photo, the card hands over to it; with nowhere to go, it just fades.
        let fadeOut = CAKeyframeAnimation(keyPath: "opacity")
        fadeOut.values = source == nil ? [1, 0] : [1, 1, 0]
        fadeOut.keyTimes = source == nil ? [0, 1] : [0, 0.7, 1]
        fadeOut.duration = 0.38
        Motion.immediately { card.opacity = 0 }
        card.add(fadeOut, forKey: "fade")
        fadeChrome(in: false, below: card.frame)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.removeCard(card)
            if self.entry == nil { self.orderOut(nil) }
        }
    }

    /// Hides at once and hands back the picture as a loose layer with its frame in this window
    /// (which covers the screen, like the clothesline window), so it can be thrown away.
    func takePicture() -> (layer: CALayer, frame: CGRect)? {
        guard entry != nil, let card, let image = (card.sublayers?.first)?.contents else { return nil }
        let frame = card.presentation()?.frame ?? card.frame
        let loose = CALayer()
        loose.bounds = CGRect(origin: .zero, size: frame.size)
        loose.contents = image
        loose.contentsGravity = .resize
        loose.cornerRadius = Self.cornerRadius
        loose.masksToBounds = true
        dismiss(animated: false)
        backdrop.alphaValue = 0
        dim.alphaValue = 0
        return (loose, frame)
    }

    // MARK: Pieces

    /// A rounded picture with a soft shadow, at `frame`.
    private func makeCard(_ image: CGImage, frame: CGRect) -> CALayer {
        let card = CALayer()
        card.frame = frame
        card.shadowColor = NSColor.black.cgColor
        card.shadowOpacity = 0.4
        card.shadowRadius = 30
        card.shadowOffset = CGSize(width: 0, height: -12)
        card.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)

        let picture = CALayer()
        picture.frame = card.bounds
        picture.contents = image
        picture.contentsGravity = .resize
        picture.cornerRadius = Self.cornerRadius
        picture.cornerCurve = .continuous
        picture.masksToBounds = true
        picture.backgroundColor = NSColor(white: 0.85, alpha: 1).cgColor
        card.addSublayer(picture)
        return card
    }

    /// The old card drifts toward `side` and fades while the new one comes in.
    private func slideAway(_ old: CALayer, toward side: Int) {
        let current = old.presentation()?.transform ?? old.transform
        var end = CATransform3DMakeTranslation(CGFloat(side) * 80, 0, 0)
        end = CATransform3DScale(end, 0.96, 0.96, 1)
        Motion.immediately {
            old.transform = end
            old.opacity = 0
        }
        old.add(Motion.spring("transform", from: NSValue(caTransform3D: current), to: NSValue(caTransform3D: end), duration: 0.35), forKey: "slide")
        old.add(fade(from: old.presentation()?.opacity ?? 1, to: 0, duration: 0.2), forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.removeCard(old) }
    }

    private func removeCard(_ layer: CALayer) {
        layer.removeFromSuperlayer()
        if card === layer { card = nil }
    }

    private func fade(from: Float, to: Float, duration: Double) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return fade
    }

    /// The blurred backdrop and the caption: in quickly as the card arrives (the caption a beat
    /// later, rising a little), out quickly as it leaves.
    private func fadeChrome(in shown: Bool, below picture: CGRect) {
        if shown { layOutCaption(below: picture) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shown ? 0.3 : 0.25
            context.timingFunction = CAMediaTimingFunction(name: shown ? .easeOut : .easeIn)
            backdrop.animator().alphaValue = shown ? 1 : 0
            dim.animator().alphaValue = shown ? 1 : 0
        }
        for label in [caption, hint] {
            guard let layer = label.layer else { continue }
            if shown {
                label.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.3
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    label.animator().alphaValue = 1
                }
                let rise = Motion.spring("transform.translation.y", from: -8, to: 0, duration: 0.45)
                rise.beginTime = CACurrentMediaTime() + 0.08
                rise.fillMode = .backwards
                layer.add(rise, forKey: "rise")
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    label.animator().alphaValue = 0
                }
            }
        }
    }

    // MARK: Layout

    /// As large as the capture, up to most of the screen, centered above the caption.
    private func targetFrame(for imageSize: CGSize) -> CGRect {
        let screen = screen?.visibleFrame ?? frame
        let available = CGRect(x: screen.minX, y: screen.minY + Self.captionHeight, width: screen.width, height: screen.height - Self.captionHeight)
            .insetBy(dx: screen.width * 0.06, dy: screen.height * 0.05)
        let size = ClotheslineLayout.previewSize(imageSize: imageSize, bounds: available.size)
        let onScreen = CGRect(x: (available.midX - size.width / 2).rounded(), y: (available.midY - size.height / 2).rounded(),
                              width: size.width, height: size.height)
        return local(onScreen)
    }

    private func layOutCaption(below picture: CGRect) {
        for label in [caption, hint] { label.sizeToFit() }
        caption.frame = CGRect(x: 0, y: picture.minY - 30, width: frame.width, height: caption.frame.height)
        hint.frame = CGRect(x: 0, y: picture.minY - 48, width: frame.width, height: hint.frame.height)
    }

    /// Screen coordinates to this window's.
    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
    }

    private func clicked(at point: CGPoint) {
        if let card, card.frame.contains(point), let entry {
            onPick?(entry)
        } else {
            onClose?()
        }
    }
}

/// Reports where it was clicked, in its own coordinates.
@MainActor
private final class ClickView: NSView {
    var onClick: ((CGPoint) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil))
    }
}
