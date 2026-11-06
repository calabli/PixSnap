import AVFoundation
import AppKit
import PixSnapCore

/// The space-bar preview: the capture zooms out of its photo on the clothesline to a large card
/// over a blurred, dimmed screen, with when and where it was taken underneath. ← → slide to the
/// neighbors; closing shrinks the card back into its photo. Everything moves on system springs and
/// starts from wherever the previous motion was, so quick presses never jump. It never becomes key,
/// so the clothesline keeps the keyboard (space, arrows, Return, Esc). Clicking the picture floats
/// it; clicking around it closes the preview; dragging the picture takes it to another app.
@MainActor
final class PhotoPreviewWindow: NSPanel {
    var onPick: ((HistoryEntry) -> Void)?
    var onClose: (() -> Void)?
    /// The picture is being dragged out: the view to drag from, its frame and look there, the
    /// mouse event that started it.
    var onDragOut: ((HistoryEntry, NSView, CGRect, NSImage, NSEvent) -> Void)?

    /// The capture being shown; nil while hidden or closing.
    private(set) var entry: HistoryEntry?

    private let backdrop = NSVisualEffectView()
    private let dim = NSView()
    /// Hosts the cards, above the backdrop.
    private let stage = NSView()
    /// The picture being shown, at its final frame; motion is all in its transform.
    private var card: CALayer?
    private let caption = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: PhotoPreviewWindow.hintText)
    private static let hintText = "← → 切换 · F 收藏 · B 大爆炸 · T 翻译 · ⌘C 复制文字 · 空格或 Esc 关闭 · 点击图片浮动到屏幕上 · Delete 扔进洗衣篮 · ⌥⌘⌫ 永久删除"
    private var details = ""
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
        content.onDrag = { [weak self] event, start in self?.dragged(event, from: start) }
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
        // A recording shows its poster, with the video playing over it.
        let picture: (image: CGImage, pointSize: CGSize)
        if entry.isRecording {
            guard let poster = HistoryLibrary.shared.image(for: entry, pixelSize: 1600) else { return }
            picture = (poster, CGSize(width: CGFloat(entry.pixelWidth) / entry.scale, height: CGFloat(entry.pixelHeight) / entry.scale))
        } else {
            guard let capture = HistoryLibrary.shared.loadCapture(entry) else { return }
            picture = (capture.image, capture.pointSize)
        }
        let opening = self.entry == nil
        self.entry = entry
        self.source = source.map(local)
        ignoresMouseEvents = false

        var details = [Self.timeFormatter.string(from: entry.createdAt)]
        if let app = entry.sourceAppName { details.append(app) }
        details.append("\(entry.pixelWidth) × \(entry.pixelHeight)")
        if let duration = entry.recordingDuration {
            let seconds = Int(duration.rounded())
            details.insert(String(format: "录屏 %d:%02d", seconds / 60, seconds % 60), at: 0)
        }
        self.details = details.joined(separator: " · ")
        setCaption(favorite: HistoryLibrary.shared.isFavorite(entry.id))
        hint.stringValue = Self.hintText

        let target = targetFrame(for: picture.pointSize)
        let incoming = makeCard(picture.image, frame: target)
        if entry.isRecording, let video = HistoryLibrary.shared.videoURL(for: entry) { play(video, on: incoming) }
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

    /// Where the picture is on screen, while showing.
    var pictureScreenFrame: CGRect? {
        card.map { $0.frame.offsetBy(dx: frame.minX, dy: frame.minY) }
    }

    /// The caption picks up or drops its star.
    func showFavorite(_ favorite: Bool) {
        setCaption(favorite: favorite)
        layOutCaption(below: card?.frame ?? .zero)
    }

    /// A favorite can't be thrown away: the card shakes "no" and the hint says why.
    func refuseToThrow() {
        guard let card else { return }
        let shake = CAKeyframeAnimation(keyPath: "position.x")
        shake.values = [0, -14, 12, -8, 5, -2, 0]
        shake.keyTimes = [0, 0.15, 0.32, 0.5, 0.68, 0.85, 1]
        shake.duration = 0.45
        shake.isAdditive = true
        card.add(shake, forKey: "shake")
        hint.stringValue = "已收藏的截图不能扔 · 先按 F 取消收藏"
        hint.sizeToFit()
        hint.frame = CGRect(x: 0, y: hint.frame.minY, width: frame.width, height: hint.frame.height)
        let shown = entry
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.entry == shown else { return }
            self.hint.stringValue = Self.hintText
        }
    }

    private func setCaption(favorite: Bool) {
        caption.stringValue = favorite ? "★ 已收藏 · " + details : details
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
        if let playing = players[ObjectIdentifier(layer)] {
            playing.player.pause()
            players[ObjectIdentifier(layer)] = nil
        }
    }

    /// Recordings playing on cards, kept until their card goes.
    private var players: [ObjectIdentifier: (player: AVQueuePlayer, looper: AVPlayerLooper)] = [:]

    /// Plays `video` on a loop, muted, over the card's poster.
    private func play(_ video: URL, on card: CALayer) {
        let player = AVQueuePlayer()
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: video))
        player.isMuted = true
        let layer = AVPlayerLayer(player: player)
        layer.frame = card.bounds
        layer.videoGravity = .resizeAspectFill
        layer.cornerRadius = Self.cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        card.addSublayer(layer)
        players[ObjectIdentifier(card)] = (player, looper)
        player.play()
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

    /// Out of the way while the picture is dragged elsewhere: it travels with the mouse, and the
    /// screen behind it should be visible to drop onto.
    private func dragged(_ event: NSEvent, from start: CGPoint) {
        guard let entry, let card, card.frame.contains(start),
              let contents = card.sublayers?.first?.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return }
        let image = NSImage(cgImage: contents as! CGImage, size: card.frame.size)
        guard let content = contentView else { return }
        // Hidden rather than closed: the drag's source view lives in this window until it ends.
        isDraggingOut = true
        alphaValue = 0
        ignoresMouseEvents = true
        onDragOut?(entry, content, card.frame, image, event)
    }

    /// The picture is on its way to another app.
    private(set) var isDraggingOut = false

    /// The drag that started here is over: the preview is done too.
    func endDragOut() {
        guard isDraggingOut else { return }
        isDraggingOut = false
        dismiss(animated: false)
        alphaValue = 1
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
    /// Dragged a few points from `start`: the drag event and where the press was.
    var onDrag: ((NSEvent, CGPoint) -> Void)?
    private var pressedAt: CGPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        pressedAt = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressedAt else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 6 else { return }
        pressedAt = nil
        onDrag?(event, start)
    }

    override func mouseUp(with event: NSEvent) {
        // A drag that went elsewhere isn't a click.
        guard pressedAt != nil else { return }
        pressedAt = nil
        onClick?(convert(event.locationInWindow, from: nil))
    }
}
