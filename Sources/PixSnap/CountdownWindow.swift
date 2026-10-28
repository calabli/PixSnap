import AppKit

/// The delayed capture's countdown: a big number beside the selected region that ticks down, each
/// second popping in. It never takes the mouse and stays out of the region, so menus, hover states
/// and animations can be set up in it meanwhile; Esc (taken as a global shortcut while it runs)
/// cancels.
@MainActor
final class CountdownWindow: NSPanel {
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    private var remaining: Int
    private let number = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "按 Esc 取消")
    private let escapeKey = HotKey()
    private var timer: Timer?

    private static let size = CGSize(width: 150, height: 150)

    init(seconds: Int, beside region: CGRect, on screen: NSScreen) {
        remaining = seconds
        let frame = Self.place(beside: region, in: screen.visibleFrame)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let content = NSVisualEffectView(frame: CGRect(origin: .zero, size: Self.size))
        content.material = .hudWindow
        content.state = .active
        content.appearance = NSAppearance(named: .darkAqua)
        content.wantsLayer = true
        content.layer?.cornerRadius = 28
        content.layer?.masksToBounds = true
        number.font = .monospacedDigitSystemFont(ofSize: 72, weight: .semibold)
        number.textColor = .white
        number.alignment = .center
        number.frame = CGRect(x: 0, y: 40, width: Self.size.width, height: 90)
        number.wantsLayer = true
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor(white: 1, alpha: 0.6)
        hint.alignment = .center
        hint.frame = CGRect(x: 0, y: 18, width: Self.size.width, height: 16)
        content.addSubview(number)
        content.addSubview(hint)
        contentView = content
    }

    /// To the right of the region, else left, below, above; vertically centered on it where it fits.
    /// When the region fills the screen, in its top-right corner.
    private static func place(beside region: CGRect, in visible: CGRect) -> CGRect {
        let gap: CGFloat = 16
        let middleY = min(max(region.midY - size.height / 2, visible.minY + 8), visible.maxY - size.height - 8)
        let middleX = min(max(region.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let candidates = [
            CGRect(x: region.maxX + gap, y: middleY, width: size.width, height: size.height),
            CGRect(x: region.minX - gap - size.width, y: middleY, width: size.width, height: size.height),
            CGRect(x: middleX, y: region.minY - gap - size.height, width: size.width, height: size.height),
            CGRect(x: middleX, y: region.maxY + gap, width: size.width, height: size.height),
        ]
        return candidates.first { visible.contains($0) }
            ?? CGRect(x: region.maxX - size.width - gap, y: region.maxY - size.height - gap, width: size.width, height: size.height)
    }

    func start() {
        escapeKey.onPress = { [weak self] in self?.cancel() }
        _ = escapeKey.register(.init(keyCode: 53, modifiers: [], keyLabel: "Esc"))
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
        show(remaining)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        remaining -= 1
        guard remaining > 0 else { return finish() }
        show(remaining)
    }

    /// Each number pops in.
    private func show(_ value: Int) {
        number.stringValue = "\(value)"
        guard let layer = number.layer else { return }
        // Scale about the number's center rather than the layer's corner.
        let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        var from = CATransform3DMakeTranslation(center.x, center.y, 0)
        from = CATransform3DScale(from, 1.35, 1.35, 1)
        from = CATransform3DTranslate(from, -center.x, -center.y, 0)
        layer.add(Motion.spring("transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: CATransform3DIdentity),
                                duration: 0.35, bounce: 0.3), forKey: "pop")
    }

    /// Gone before the region is captured.
    private func finish() {
        stop()
        onFinish?()
    }

    private func cancel() {
        stop()
        onCancel?()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        escapeKey.unregister()
        orderOut(nil)
    }
}
