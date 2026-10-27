import AppKit
import PixSnapCore

/// The space-bar preview: the capture grows out of its photo on the clothesline to a large view
/// over a dimmed screen, with when and where it was taken underneath. It never becomes key, so the
/// clothesline keeps the keyboard (space, arrows, Return, Esc). Clicking the picture floats it;
/// clicking around it closes the preview.
@MainActor
final class PhotoPreviewWindow: NSPanel {
    var onPick: ((HistoryEntry) -> Void)?
    var onClose: (() -> Void)?

    /// The capture being shown; nil while hidden.
    private(set) var entry: HistoryEntry?

    private let backdrop = NSView()
    private let picture = NSImageView()
    /// Holds the picture's shadow, which the picture's rounded mask would clip.
    private let shadowHolder = NSView()
    private let caption = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "← → 切换 · 空格或 Esc 关闭 · 点击图片浮动到屏幕上")
    private var source: CGRect?

    private static let captionHeight: CGFloat = 48
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

        backdrop.frame = content.bounds
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        content.addSubview(backdrop)

        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 6
        picture.layer?.masksToBounds = true
        picture.layer?.backgroundColor = NSColor(white: 0.85, alpha: 1).cgColor
        let frameShadow = NSShadow()
        frameShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        frameShadow.shadowBlurRadius = 24
        frameShadow.shadowOffset = CGSize(width: 0, height: -6)
        shadowHolder.shadow = frameShadow
        shadowHolder.wantsLayer = true
        shadowHolder.addSubview(picture)
        picture.autoresizingMask = [.width, .height]
        content.addSubview(shadowHolder)

        for label in [caption, hint] {
            label.alignment = .center
            label.textColor = .white
            content.addSubview(label)
        }
        caption.font = .systemFont(ofSize: 13, weight: .semibold)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor(white: 1, alpha: 0.7)
    }

    override var canBecomeKey: Bool { false }

    /// Shows `entry`, growing out of `source` (a screen rect) the first time.
    func show(_ entry: HistoryEntry, from source: CGRect?) {
        let opening = self.entry == nil
        self.entry = entry
        self.source = source
        guard let capture = HistoryLibrary.shared.loadCapture(entry) else { return }
        picture.image = NSImage(cgImage: capture.image, size: capture.pointSize)

        var details = [Self.timeFormatter.string(from: entry.createdAt)]
        if let app = entry.sourceAppName { details.append(app) }
        details.append("\(entry.pixelWidth) × \(entry.pixelHeight)")
        caption.stringValue = details.joined(separator: " · ")

        let target = targetFrame(for: capture.pointSize)
        layOutCaption(below: target)
        if opening {
            shadowHolder.frame = source.map(local) ?? target.insetBy(dx: target.width * 0.1, dy: target.height * 0.1)
            backdrop.alphaValue = 0
            for view in [caption, hint] { view.alphaValue = 0 }
            orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = opening ? 0.28 : 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.1, 0.4, 1)
            shadowHolder.animator().frame = target
            backdrop.animator().alphaValue = 1
            for view in [caption, hint] { view.animator().alphaValue = 1 }
        }
    }

    /// Shrinks back into the photo on the line, if it's still there, and hides.
    func dismiss(animated: Bool = true) {
        guard entry != nil else { return }
        entry = nil
        guard animated else { orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if let source { shadowHolder.animator().frame = local(source) }
            shadowHolder.animator().alphaValue = source == nil ? 0 : 1
            backdrop.animator().alphaValue = 0
            for view in [caption, hint] { view.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.entry == nil else { return }
                self.orderOut(nil)
                self.shadowHolder.alphaValue = 1
            }
        })
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
        caption.frame = CGRect(x: 0, y: picture.minY - 26, width: frame.width, height: caption.frame.height)
        hint.frame = CGRect(x: 0, y: picture.minY - 44, width: frame.width, height: hint.frame.height)
    }

    /// Screen coordinates to this window's.
    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
    }

    private func clicked(at point: CGPoint) {
        if shadowHolder.frame.contains(point), let entry {
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
