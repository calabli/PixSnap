import AppKit
import PixSnapCore

/// A screen recording in progress: the region is outlined in red with the rest of the screen dimmed,
/// and a small bar beside it shows the time with 停止 and 取消. The recording shortcut pressed again
/// also stops it. Esc is left alone, since what's being recorded may need it.
@MainActor
final class RecordingSession {
    /// The finished file and its length, or nil if it was cancelled or nothing was recorded.
    var onFinish: ((URL, Double)?) -> Void = { _ in }

    let region: CGRect
    private let screen: NSScreen
    private let outline: RegionFrameWindow
    private let controls: RecordingControlsPanel
    private var recorder: ScreenRecorder?
    private var started = Date()
    private var timer: Timer?
    private var isEnding = false

    init(region: CGRect, on screen: NSScreen) {
        self.region = region
        self.screen = screen
        outline = RegionFrameWindow(region: region, screen: screen, color: .systemRed)
        controls = RecordingControlsPanel()
        controls.onStop = { [weak self] in self?.stop() }
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
            let recorder = try await ScreenCapturer.shared.makeRecorder(for: region, on: screen, fps: settings.recordingFPS,
                                                                        showsCursor: settings.recordsCursor,
                                                                        hiding: [outline.windowNumber, controls.windowNumber])
            self.recorder = recorder
            try await recorder.start()
            started = Date()
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
        controls.elapsed = Date().timeIntervalSince(started)
    }

    func stop() {
        guard !isEnding, let recorder else { return }
        isEnding = true
        controls.isFinishing = true
        Task {
            let duration = await recorder.stop()
            close()
            onFinish(duration.map { (recorder.url, $0) })
        }
    }

    func cancel() {
        guard !isEnding else { return }
        isEnding = true
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
    }
}

/// The bar beside the region while recording: a pulsing red dot, the time, 停止 and 取消.
@MainActor
private final class RecordingControlsPanel: NSPanel {
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

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
            if isFinishing { time.stringValue = "正在保存…" }
        }
    }

    private let dot = NSView()
    private let time = NSTextField(labelWithString: "00:00")
    private let stop = NSButton(title: "停止", target: nil, action: nil)
    private let cancel = NSButton(title: "取消", target: nil, action: nil)
    private static let size = CGSize(width: 250, height: 40)

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
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.3
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")

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

        let stack = NSStackView(views: [dot, time, NSView(), cancel, stop])
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
}
