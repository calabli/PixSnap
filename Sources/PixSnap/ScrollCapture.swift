import AppKit
import PixSnapCore

/// A long screenshot in progress: the selected region stays outlined with the rest of the screen
/// dimmed, and while the person scrolls the content inside it (with the mouse or trackpad, in
/// whatever app it is, down or up), the region is captured several times a second and the rows
/// that come into view are stitched on at the bottom or the top. A preview beside the region shows the long image growing; Return or 完成 finishes,
/// Esc or 取消 gives up.
///
/// PixSnap's own windows are left out of the captures, and the frame and dimming ignore the mouse,
/// so scrolling goes straight to the app underneath. That app keeps the keyboard too, so Esc and
/// Return are taken as global shortcuts for as long as the session runs.
@MainActor
final class ScrollCaptureSession {
    /// Called once with the long image, or nil if it was cancelled.
    var onFinish: ((Capture?) -> Void)?

    private let screen: NSScreen
    private let region: CGRect
    private let scale: CGFloat
    private let stitcher: SendableStitcher
    private let frameWindow: RegionFrameWindow
    private let controls: ScrollControlsPanel
    private let preview: StitchPreviewWindow
    private var isRunning = true
    private var lastPreview = Date.distantPast
    private let escapeKey = HotKey()
    private let returnKey = HotKey()

    /// About eight captures a second: smooth enough to follow normal scrolling.
    private static let interval: Duration = .milliseconds(120)

    init(region: CGRect, on screen: NSScreen) {
        self.screen = screen
        self.region = region.integral
        scale = screen.backingScaleFactor
        stitcher = SendableStitcher(ScrollStitcher(width: Int((self.region.width * scale).rounded()),
                                                   frameHeight: Int((self.region.height * scale).rounded())))
        frameWindow = RegionFrameWindow(region: self.region, screen: screen)
        controls = ScrollControlsPanel()
        preview = StitchPreviewWindow(region: self.region, screen: screen)
        controls.onDone = { [weak self] in self?.finish() }
        controls.onCancel = { [weak self] in self?.cancel() }
    }

    func start() {
        frameWindow.orderFrontRegardless()
        preview.orderFrontRegardless()
        controls.place(near: region, on: screen)
        controls.makeKeyAndOrderFront(nil)
        escapeKey.onPress = { [weak self] in self?.cancel() }
        returnKey.onPress = { [weak self] in self?.finish() }
        if !escapeKey.register(Shortcut(keyCode: 53, modifiers: [], keyLabel: "Esc"))
            || !returnKey.register(Shortcut(keyCode: 36, modifiers: [], keyLabel: "↩")) {
            NSLog("PixSnap long screenshot: Esc or Return is taken by another app; use the buttons")
        }
        Task { await run() }
    }

    private func run() async {
        while isRunning {
            do {
                let image = try await ScreenCapturer.shared.captureRegion(region, on: screen)
                guard isRunning else { return }
                let stitcher = self.stitcher
                let outcome = await Task.detached(priority: .userInitiated) { stitcher.add(image) }.value
                show(outcome)
            } catch {
                NSLog("PixSnap long screenshot capture failed: \(error)")
            }
            try? await Task.sleep(for: Self.interval)
        }
    }

    private func show(_ outcome: ScrollStitcher.Outcome?) {
        let height = Int((CGFloat(stitcher.height) / scale).rounded())
        switch outcome {
        case .started, .unchanged, .moved, nil:
            controls.status = stitcher.height > stitcher.frameHeight
                ? "已拼接 \(height) 点高 · 继续上下滚动，或按回车完成"
                : "在框里上下滚动内容（鼠标滚轮或触控板）"
            controls.isWarning = false
        case .added, .addedAbove:
            controls.status = "已拼接 \(height) 点高 · 继续上下滚动，或按回车完成"
            controls.isWarning = false
        case .lost:
            controls.status = "跟丢了：滚得太快了，往回滚一点就能接上"
            controls.isWarning = true
        case .full:
            controls.status = "已经够长了（\(height) 点高），按回车完成"
            controls.isWarning = true
        }
        // Rebuilding the preview image copies the whole long image, so not on every frame.
        // The preview shows the end that's growing.
        let growsAtTop: Bool
        switch outcome {
        case .added: growsAtTop = false
        case .addedAbove: growsAtTop = true
        default: return
        }
        if Date().timeIntervalSince(lastPreview) > 0.25 {
            lastPreview = Date()
            preview.show(stitcher.image(), showingTop: growsAtTop)
        }
    }

    /// Finishes as if 完成 was clicked (`--scroll-capture`).
    func finishNow() { finish() }

    private func finish() {
        guard isRunning else { return }
        isRunning = false
        let image = stitcher.image()
        close()
        onFinish?(image.map { Capture(image: $0, scale: scale) })
    }

    private func cancel() {
        guard isRunning else { return }
        isRunning = false
        close()
        onFinish?(nil)
    }

    private func close() {
        escapeKey.unregister()
        returnKey.unregister()
        frameWindow.orderOut(nil)
        preview.orderOut(nil)
        controls.orderOut(nil)
    }
}

/// The stitcher, handed to a background task for the heavy row hashing. Only one task uses it at a
/// time: each frame is stitched before the next is captured.
private final class SendableStitcher: @unchecked Sendable {
    private let stitcher: ScrollStitcher
    private let lock = NSLock()

    init(_ stitcher: ScrollStitcher) { self.stitcher = stitcher }

    var height: Int { lock.withLock { stitcher.height } }
    var frameHeight: Int { stitcher.frameHeight }

    /// Returns nil when the frame isn't the expected size (the display changed).
    func add(_ image: CGImage) -> ScrollStitcher.Outcome? {
        guard image.width == stitcher.width, image.height == stitcher.frameHeight,
              let bytes = Self.rgba(image) else { return nil }
        return lock.withLock { stitcher.add(bytes) }
    }

    /// The long image so far.
    func image() -> CGImage? {
        lock.withLock {
            guard stitcher.height > 0 else { return nil }
            let data = Data(stitcher.pixels) as CFData
            guard let provider = CGDataProvider(data: data) else { return nil }
            return CGImage(width: stitcher.width, height: stitcher.height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: stitcher.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }

    /// The image redrawn as 8-bit RGBA, top row first, so every frame compares byte for byte.
    private static func rgba(_ image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? bytes : nil
    }
}

/// The outline around the region, with the rest of the screen dimmed. It never takes the mouse,
/// so scrolling reaches the app underneath.
@MainActor
private final class RegionFrameWindow: NSPanel {
    init(region: CGRect, screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        let local = region.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)

        // Dim everything but the region.
        let dim = CAShapeLayer()
        let path = CGMutablePath()
        path.addRect(view.bounds)
        path.addRect(local)
        dim.path = path
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.3).cgColor
        view.layer?.addSublayer(dim)

        // A dashed outline just outside it, marching slowly so it reads as "recording".
        let outline = CAShapeLayer()
        outline.path = CGPath(rect: local.insetBy(dx: -1.5, dy: -1.5), transform: nil)
        outline.fillColor = nil
        outline.strokeColor = NSColor.controlAccentColor.cgColor
        outline.lineWidth = 2
        outline.lineDashPattern = [8, 5]
        let march = CABasicAnimation(keyPath: "lineDashPhase")
        march.fromValue = 0
        march.toValue = -13
        march.duration = 0.6
        march.repeatCount = .infinity
        outline.add(march, forKey: "march")
        view.layer?.addSublayer(outline)
        contentView = view
    }
}

/// The long image growing, beside the region: scaled to fit its width, showing the newest part.
@MainActor
private final class StitchPreviewWindow: NSPanel {
    private let imageLayer = CALayer()
    private let width: CGFloat = 150

    init(region: CGRect, screen: NSScreen) {
        let visible = screen.visibleFrame
        // To the right of the region when there's room, otherwise to the left.
        let x = region.maxX + 16 + width <= visible.maxX ? region.maxX + 16 : max(visible.minX + 8, region.minX - 16 - width)
        let height = min(region.height, visible.height - 40)
        let frame = CGRect(x: x, y: region.maxY - height, width: width, height: height)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.85).cgColor
        view.layer?.cornerRadius = 8
        view.layer?.masksToBounds = true
        imageLayer.frame = view.bounds.insetBy(dx: 6, dy: 6)
        imageLayer.contentsGravity = .bottom
        imageLayer.masksToBounds = true
        view.layer?.addSublayer(imageLayer)
        contentView = view
        alphaValue = 0
    }

    /// Shows the image scaled to the preview's width; when it's taller than the preview, the end
    /// just added stays in view.
    func show(_ image: CGImage?, showingTop: Bool) {
        guard let image else { return }
        let fit = imageLayer.bounds.width / CGFloat(image.width)
        imageLayer.contentsScale = 1 / fit
        Motion.immediately {
            // Layer gravity is in unflipped coordinates: "top" is the image's top row.
            imageLayer.contentsGravity = showingTop ? .top : .bottom
            imageLayer.contents = image
        }
        if alphaValue == 0 { animator().alphaValue = 1 }
    }
}

/// The small panel under the region: what's happening, and 完成 / 取消. It takes the keyboard
/// (Return, Esc) without bringing PixSnap forward, so the app being scrolled stays active.
@MainActor
private final class ScrollControlsPanel: NSPanel {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    var status = "" {
        didSet { label.stringValue = status; layOut() }
    }

    var isWarning = false {
        didSet { label.textColor = isWarning ? .systemOrange : .labelColor }
    }

    private let label = NSTextField(labelWithString: "")
    private let done = NSButton(title: "完成", target: nil, action: nil)
    private let cancel = NSButton(title: "取消", target: nil, action: nil)
    private let content = NSVisualEffectView()
    private var region = CGRect.zero
    private var screenArea = CGRect.zero

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 420, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        content.material = .popover
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        done.target = self
        done.action = #selector(doneClicked)
        done.keyEquivalent = "\r"
        done.bezelStyle = .rounded
        cancel.target = self
        cancel.action = #selector(cancelClicked)
        cancel.bezelStyle = .rounded
        let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.down.to.line.compact", accessibilityDescription: "长截图")!)
        icon.contentTintColor = .controlAccentColor
        let stack = NSStackView(views: [icon, label, cancel, done])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        contentView = content
        status = "在框里上下滚动内容（鼠标滚轮或触控板）"
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// Under the region, or above it when it reaches the bottom of the screen, or inside its
    /// bottom edge when it fills the screen.
    func place(near region: CGRect, on screen: NSScreen) {
        self.region = region
        screenArea = screen.visibleFrame
        layOut()
    }

    private func layOut() {
        guard screenArea != .zero else { return }
        let size = CGSize(width: min(max(content.fittingSize.width, 360), screenArea.width - 20), height: 40)
        var y = region.minY - size.height - 10
        if y < screenArea.minY + 4 { y = region.maxY + 10 }
        if y + size.height > screenArea.maxY { y = region.minY + 12 }
        let x = min(max(region.midX - size.width / 2, screenArea.minX + 8), screenArea.maxX - size.width - 8)
        setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    @objc private func doneClicked() { onDone?() }
    @objc private func cancelClicked() { onCancel?() }
}
