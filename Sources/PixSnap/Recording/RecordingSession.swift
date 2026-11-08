import AppKit
import PixSnapCore

/// A screen recording in progress: the region is outlined in red with the rest of the screen dimmed,
/// and a small bar beside it shows the time with 暂停, 停止 and 取消. The recording shortcut pressed
/// again also stops it. Esc is left alone, since what's being recorded may need it. Clicks and
/// shortcuts can be shown in the recording (Settings › 录屏).
@MainActor
final class RecordingSession {
    /// The finished file and its length, or nil if it was cancelled or nothing was recorded.
    var onFinish: ((URL, Double)?) -> Void = { _ in }

    let region: CGRect
    private let screen: NSScreen
    private let outline: RegionFrameWindow
    private let controls: RecordingControlsPanel
    private let inputs: InputOverlayWindow?
    private var recorder: ScreenRecorder?
    /// The clicks, keys and marks, saved beside the video for zooming and the guide afterwards.
    private var timeline: TimelineRecorder?
    private let markKey = HotKey()
    private var started = Date()
    /// Time spent paused, and when the current pause began.
    private var pausedFor: TimeInterval = 0
    private var pausedAt: Date?
    private var timer: Timer?
    private var isEnding = false

    init(region: CGRect, on screen: NSScreen) {
        self.region = region
        self.screen = screen
        outline = RegionFrameWindow(region: region, screen: screen, color: .systemRed)
        controls = RecordingControlsPanel()
        let settings = AppSettings.shared
        inputs = settings.highlightsClicks || settings.showsKeystrokes
            ? InputOverlayWindow(region: region, clicks: settings.highlightsClicks, keys: settings.showsKeystrokes) : nil
        controls.onStop = { [weak self] in self?.stop() }
        controls.onPause = { [weak self] in self?.togglePause() }
        controls.onMark = { [weak self] in self?.mark() }
        controls.onCancel = { [weak self] in self?.cancel() }
    }

    func start() async {
        let settings = AppSettings.shared
        do {
            // On screen first, so the recording can leave out just these two windows (and still show
            // PixSnap's others: the clothesline, floating captures, the editor).
            outline.orderFrontRegardless()
            controls.place(near: region, on: screen)
            controls.orderFrontRegardless()
            // Recorded, unlike the frame and controls: the clicks and keys are meant to show.
            inputs?.orderFrontRegardless()
            if settings.showsKeystrokes { PermissionGuide.ensureAccessibility() }
            let recorder = try await ScreenCapturer.shared.makeRecorder(for: region, on: screen, fps: settings.recordingFPS,
                                                                        showsCursor: settings.recordsCursor,
                                                                        systemAudio: settings.recordsSystemAudio,
                                                                        microphone: settings.recordsMicrophone,
                                                                        hiding: [outline.windowNumber, controls.windowNumber])
            self.recorder = recorder
            try await recorder.start()
            started = Date()
            inputs?.start()
            let timeline = TimelineRecorder(region: region, recorder: recorder)
            timeline.start()
            self.timeline = timeline
            markKey.onPress = { [weak self] in self?.mark() }
            _ = markKey.register(Shortcut(keyCode: 46, modifiers: [.option, .shift], keyLabel: "M"))
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            tick()
        } catch {
            NSLog("PixSnap could not start recording: \(error)")
            close()
            NSSound.beep()
            onFinish(nil)
        }
    }

    private func tick() {
        let now = pausedAt ?? Date()
        controls.elapsed = now.timeIntervalSince(started) - pausedFor
    }

    /// Pauses, or carries on after a pause; the paused stretch is left out of the video.
    func togglePause() {
        guard !isEnding, let recorder else { return }
        if let pausedAt {
            pausedFor += Date().timeIntervalSince(pausedAt)
            self.pausedAt = nil
            recorder.resume()
        } else {
            pausedAt = Date()
            recorder.pause()
        }
        controls.isPaused = pausedAt != nil
        tick()
    }

    /// ⌥⇧M or the flag: this moment becomes a step of its own in the guide.
    func mark() {
        guard !isEnding, pausedAt == nil, let timeline else { return }
        timeline.mark()
        controls.flashMark()
    }

    func stop() {
        guard !isEnding, let recorder else { return }
        isEnding = true
        controls.isFinishing = true
        timeline?.stop()
        Task {
            let duration = await recorder.stop()
            if duration != nil { timeline?.save(besideVideo: recorder.url) }
            close()
            onFinish(duration.map { (recorder.url, $0) })
        }
    }

    func cancel() {
        guard !isEnding else { return }
        isEnding = true
        timeline?.stop()
        Task {
            await recorder?.cancel()
            close()
            onFinish(nil)
        }
    }

    private func close() {
        timer?.invalidate()
        timer = nil
        outline.orderOut(nil)
        controls.orderOut(nil)
        inputs?.stop()
        inputs?.orderOut(nil)
        markKey.unregister()
    }
}

/// The bar beside the region while recording: a pulsing red dot, the time, 暂停, 停止 and 取消.
@MainActor
private final class RecordingControlsPanel: NSPanel {
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPause: (() -> Void)?
    var onMark: (() -> Void)?

    var isPaused = false {
        didSet {
            pause.image = NSImage(systemSymbolName: isPaused ? "record.circle" : "pause.fill", accessibilityDescription: nil)
            pause.toolTip = isPaused ? "继续录制" : "暂停：暂停的这段不会录进去"
            dot.layer?.backgroundColor = (isPaused ? NSColor.systemGray : NSColor.systemRed).cgColor
            dot.layer?.opacity = 1
            if isPaused { dot.layer?.removeAnimation(forKey: "pulse") } else { dot.layer?.add(Self.pulse, forKey: "pulse") }
        }
    }

    var elapsed: Double = 0 {
        didSet {
            let seconds = Int(elapsed)
            time.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
    }

    var isFinishing = false {
        didSet {
            stop.isEnabled = !isFinishing
            cancel.isEnabled = !isFinishing
            pause.isEnabled = !isFinishing
            if isFinishing { time.stringValue = "正在保存…" }
        }
    }

    private let dot = NSView()
    private let time = NSTextField(labelWithString: "00:00")
    private let stop = NSButton(title: "停止", target: nil, action: nil)
    private let cancel = NSButton(title: "取消", target: nil, action: nil)
    private let pause = NSButton(image: NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "暂停")!, target: nil, action: nil)
    private let flag = NSButton(image: NSImage(systemSymbolName: "flag", accessibilityDescription: "标记一步")!, target: nil, action: nil)
    private static let size = CGSize(width: 330, height: 40)

    private static var pulse: CABasicAnimation {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.3
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        return pulse
    }

    init() {
        super.init(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let content = NSVisualEffectView(frame: CGRect(origin: .zero, size: Self.size))
        content.material = .popover
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.layer?.masksToBounds = true

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer?.add(Self.pulse, forKey: "pulse")

        time.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        stop.bezelStyle = .rounded
        stop.target = self
        stop.action = #selector(stopClicked)
        stop.contentTintColor = .systemRed
        stop.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "停止")
        stop.imagePosition = .imageLeading
        stop.toolTip = "停止录制（再按一次录屏快捷键也可以）"
        cancel.bezelStyle = .rounded
        cancel.target = self
        cancel.action = #selector(cancelClicked)
        pause.bezelStyle = .rounded
        pause.target = self
        pause.action = #selector(pauseClicked)
        pause.toolTip = "暂停：暂停的这段不会录进去"
        flag.bezelStyle = .rounded
        flag.target = self
        flag.action = #selector(flagClicked)
        flag.contentTintColor = .systemOrange
        flag.toolTip = "标记一步（⌥⇧M）：这一刻在图文教程里单独成一步"

        let stack = NSStackView(views: [dot, time, NSView(), flag, pause, cancel, stop])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        contentView = content
    }

    /// Under the region, or above it, or inside its bottom edge when it fills the screen.
    func place(near region: CGRect, on screen: NSScreen) {
        let visible = screen.visibleFrame
        var y = region.minY - Self.size.height - 10
        if y < visible.minY + 4 { y = region.maxY + 10 }
        if y + Self.size.height > visible.maxY { y = region.minY + 12 }
        let x = min(max(region.midX - Self.size.width / 2, visible.minX + 8), visible.maxX - Self.size.width - 8)
        setFrame(CGRect(x: x, y: y, width: Self.size.width, height: Self.size.height), display: true)
    }

    @objc private func stopClicked() { onStop?() }
    @objc private func cancelClicked() { onCancel?() }
    @objc private func pauseClicked() { onPause?() }
    @objc private func flagClicked() { onMark?() }

    /// The flag fills in for a moment to say the mark was taken.
    func flashMark() {
        flag.image = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: "已标记")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.flag.image = NSImage(systemSymbolName: "flag", accessibilityDescription: "标记一步")
        }
    }
}

/// Over the region while recording, and recorded with it: a ring where each click lands, and the
/// shortcuts pressed (see `Keystroke`) in a pill at the bottom. Clicks pass through it.
@MainActor
private final class InputOverlayWindow: NSPanel {
    private let region: CGRect
    private let showsClicks: Bool
    private let showsKeys: Bool
    private var monitors: [Any] = []
    private let keyPill = NSView()
    private let keyLabel = NSTextField(labelWithString: "")
    private var keyWork: DispatchWorkItem?

    init(region: CGRect, clicks: Bool, keys: Bool) {
        self.region = region
        showsClicks = clicks
        showsKeys = keys
        super.init(contentRect: region, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let content = NSView(frame: CGRect(origin: .zero, size: region.size))
        content.wantsLayer = true
        keyLabel.font = .systemFont(ofSize: max(16, min(28, region.height / 18)), weight: .semibold)
        keyLabel.textColor = .white
        keyPill.addSubview(keyLabel)
        keyPill.wantsLayer = true
        keyPill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        keyPill.alphaValue = 0
        content.addSubview(keyPill)
        contentView = content
    }

    func start() {
        if showsClicks {
            let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            monitors.append(NSEvent.addGlobalMonitorForEvents(matching: clicks) { _ in
                MainActor.assumeIsolated { self.ring(at: NSEvent.mouseLocation) }
            } as Any)
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
                self?.ring(at: NSEvent.mouseLocation)
                return event
            } as Any)
        }
        if showsKeys {
            monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated { self.show(event) }
            } as Any)
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.show(event)
                return event
            } as Any)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// A ring that grows and fades where the click landed (screen coordinates).
    private func ring(at point: CGPoint) {
        guard region.contains(point), let layer = contentView?.layer else { return }
        let size: CGFloat = 44
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -size / 2, y: -size / 2, width: size, height: size), transform: nil)
        ring.fillColor = NSColor.systemYellow.withAlphaComponent(0.25).cgColor
        ring.strokeColor = NSColor.systemYellow.cgColor
        ring.lineWidth = 3
        ring.position = CGPoint(x: point.x - region.minX, y: point.y - region.minY)
        layer.addSublayer(ring)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3
        grow.toValue = 1.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.opacity = 0
        ring.add(group, forKey: "click")
        CATransaction.commit()
    }

    private func show(_ event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers: ShortcutModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        guard let label = Keystroke.label(keyCode: event.keyCode, modifiers: modifiers, characters: event.charactersIgnoringModifiers),
              let content = contentView else { return }
        keyLabel.stringValue = label
        keyLabel.sizeToFit()
        let size = CGSize(width: keyLabel.frame.width + 28, height: keyLabel.frame.height + 12)
        keyLabel.setFrameOrigin(CGPoint(x: 14, y: 6))
        keyPill.frame = CGRect(x: ((content.bounds.width - size.width) / 2).rounded(), y: 24, width: size.width, height: size.height)
        keyPill.layer?.cornerRadius = size.height / 2
        keyPill.alphaValue = 1
        keyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; self?.keyPill.animator().alphaValue = 0 }
        }
        keyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}
