import AppKit
import PixSnapCore

/// The pull-down handle: a black shape exactly over the camera notch (or a small bar at the top center
/// of screens without one), so it reads as the notch itself. Hover: it grows a little and hints.
/// Press and pull down: the clotheslines slide down from the top of the screen with the mouse; let go
/// past the threshold, or just click, and they settle. There's no panel behind them — only ropes
/// across the whole screen and the captures hanging from them. Esc, a click elsewhere (it passes
/// through to what's underneath) or a click on the handle puts them away.
@MainActor
final class NotchWindow: NSPanel {
    var onPick: ((HistoryEntry) -> Void)?
    /// Supplies the days to hang each time the lines are about to come down.
    var loadDays: (() -> (days: [HistoryGrouping.Day], emptyMessage: String))?

    let screenFrame: CGRect
    private let collapsedFrame: CGRect
    private let hoverFrame: CGRect
    /// The window while the lines are out: the full screen width, from the top down.
    private var openFrame: CGRect
    /// How far down the lines start: below the notch, or below the menu bar on other screens.
    private let topInset: CGFloat

    private let content = PassthroughContentView()
    private let handle = HandleView()
    private let clothesline: ClotheslineView

    private enum Phase {
        case collapsed, hovering
        /// Pulling down from the handle; `startY` is the mouse's screen y at the press.
        case pulling(startY: CGFloat, distance: CGFloat)
        case open
        case closing
    }

    private var phase = Phase.collapsed
    private var outsideClickMonitor: Any?

    /// Let go after pulling this far and the lines stay down.
    private static let openDistance: CGFloat = 90
    private static let springTiming = CAMediaTimingFunction(controlPoints: 0.25, 1.3, 0.4, 1)

    init(handle handleRect: CGRect, screenFrame: CGRect, menuBarHeight: CGFloat) {
        self.screenFrame = screenFrame
        collapsedFrame = handleRect
        hoverFrame = NotchGeometry.hoverRect(for: handleRect)
        topInset = max(handleRect.height, menuBarHeight) + 6
        openFrame = handleRect
        clothesline = ClotheslineView(frame: CGRect(x: 0, y: 0, width: screenFrame.width, height: ClotheslineView.height(forDays: 0)))

        super.init(contentRect: handleRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above the menu bar, below menus and the selection overlay.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        handle.frame = content.bounds
        handle.autoresizingMask = [.width, .height]
        handle.onMouseEntered = { [weak self] in self?.mouseEnteredHandle() }
        handle.onMouseExited = { [weak self] in self?.mouseExitedHandle() }
        handle.onMouseDown = { [weak self] in self?.pressed() }
        handle.onMouseDragged = { [weak self] in self?.dragged() }
        handle.onMouseUp = { [weak self] in self?.released() }

        clothesline.isHidden = true
        clothesline.onPick = { [weak self] entry in
            self?.collapse()
            self?.onPick?(entry)
        }
        content.addSubview(clothesline)
        content.addSubview(handle)
        contentView = content
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        collapse()
    }

    /// Brings the lines down without a gesture (menu bar item).
    func openNow() {
        guard case .collapsed = phase else { return }
        prepareLines()
        open()
    }

    // MARK: Gestures

    private func mouseEnteredHandle() {
        guard case .collapsed = phase else { return }
        phase = .hovering
        handle.showsHint = true
        animate(to: hoverFrame, duration: 0.18)
    }

    private func mouseExitedHandle() {
        guard case .hovering = phase else { return }
        phase = .collapsed
        handle.showsHint = false
        animate(to: collapsedFrame, duration: 0.2)
    }

    private func pressed() {
        switch phase {
        case .collapsed, .hovering:
            prepareLines()
            phase = .pulling(startY: NSEvent.mouseLocation.y, distance: 0)
            handle.showsHint = false
            placeLines(progress: 0)
            clothesline.isHidden = false
        case .open:
            // A click on the handle puts the lines away (on release).
            break
        default:
            break
        }
    }

    private func dragged() {
        guard case .pulling(let startY, _) = phase else { return }
        let distance = startY - NSEvent.mouseLocation.y
        phase = .pulling(startY: startY, distance: distance)
        placeLines(progress: min(1, max(0, distance / max(clothesline.frame.height, 1))))
    }

    private func released() {
        switch phase {
        case .pulling(_, let distance):
            // A plain click opens too; a short pull springs back up.
            if distance >= Self.openDistance || distance < 4 { open() } else { collapse() }
        case .open:
            collapse()
        default:
            break
        }
    }

    // MARK: Opening and closing

    /// Loads the lines and switches the window to its open size, with the handle kept where it is
    /// on screen.
    private func prepareLines() {
        let loaded = loadDays?() ?? (days: [], emptyMessage: "")
        let height = ClotheslineView.height(forDays: loaded.days.count)
        openFrame = CGRect(x: screenFrame.minX, y: screenFrame.maxY - topInset - height,
                           width: screenFrame.width, height: topInset + height)
        let handleOnScreen = frame
        setFrame(openFrame, display: false)
        handle.autoresizingMask = []
        handle.frame = handleOnScreen.offsetBy(dx: -openFrame.minX, dy: -openFrame.minY)

        clothesline.frame = CGRect(x: 0, y: 0, width: openFrame.width, height: height)
        clothesline.show(loaded.days, thumbnails: { HistoryLibrary.shared.thumbnail(for: $0) }, emptyMessage: loaded.emptyMessage)
    }

    /// 0: the lines are tucked above the top of the screen; 1: hanging in place under the notch.
    private func placeLines(progress: CGFloat) {
        let settled = content.bounds.height - topInset - clothesline.frame.height
        let tucked = content.bounds.height
        clothesline.setFrameOrigin(CGPoint(x: 0, y: tucked + (settled - tucked) * progress))
        clothesline.alphaValue = min(1, progress * 1.6)
    }

    private func open() {
        phase = .open
        clothesline.isHidden = false
        let settled = content.bounds.height - topInset - clothesline.frame.height
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = Self.springTiming
            clothesline.animator().setFrameOrigin(CGPoint(x: 0, y: settled))
            clothesline.animator().alphaValue = 1
        }
        clothesline.playDropAnimation()
        makeKey()
        startWatchingOutsideClicks()
    }

    func collapse() {
        switch phase {
        case .collapsed, .closing: return
        case .hovering:
            phase = .collapsed
            handle.showsHint = false
            animate(to: collapsedFrame, duration: 0.2)
            return
        default:
            break
        }
        phase = .closing
        stopWatchingOutsideClicks()
        handle.showsHint = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            clothesline.animator().setFrameOrigin(CGPoint(x: 0, y: content.bounds.height))
            clothesline.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finishCollapsing() }
        })
    }

    /// Back to just the handle.
    private func finishCollapsing() {
        guard case .closing = phase else { return }
        phase = .collapsed
        clothesline.isHidden = true
        setFrame(collapsedFrame, display: true)
        handle.frame = content.bounds
        handle.autoresizingMask = [.width, .height]
    }

    private func animate(to frame: CGRect, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(frame, display: true)
        }
    }

    /// Clicks in other apps (including on empty space between the lines, which passes through)
    /// put the lines away. Mouse-click monitors need no special permission.
    private func startWatchingOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapse() }
        }
    }

    private func stopWatchingOutsideClicks() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }
}

/// The window's transparent content: only the handle and the photos take clicks.
@MainActor
private final class PassthroughContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// The black notch shape with rounded bottom corners, and the hint shown while hovering.
@MainActor
private final class HandleView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    var onMouseDown: (() -> Void)?
    var onMouseDragged: (() -> Void)?
    var onMouseUp: (() -> Void)?

    var showsHint = false {
        didSet {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; hint.animator().alphaValue = showsHint ? 1 : 0 }
        }
    }

    private let hint = NSTextField(labelWithString: "↓ 下拉看历史")

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner] // bottom corners
        layer?.cornerRadius = 10
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = NSColor(white: 1, alpha: 0.75)
        hint.alphaValue = 0
        hint.sizeToFit()
        hint.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        addSubview(hint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        hint.setFrameOrigin(CGPoint(x: ((bounds.width - hint.frame.width) / 2).rounded(), y: 3))
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        hint.setFrameOrigin(CGPoint(x: ((bounds.width - hint.frame.width) / 2).rounded(), y: 3))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }
    override func mouseDown(with event: NSEvent) { onMouseDown?() }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?() }
    override func mouseUp(with event: NSEvent) { onMouseUp?() }
}
