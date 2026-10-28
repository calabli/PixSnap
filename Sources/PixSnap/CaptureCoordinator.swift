import AppKit
import PixSnapCore
import PixSnapRender

/// Runs one capture: freeze every screen, let the user select, then pin the result on screen.
@MainActor
final class CaptureCoordinator {
    private var overlays: [SelectionWindow] = []
    private var isCapturing = false
    /// Increases with every capture, so screens that finish after their capture ended are ignored.
    private var sessionID = 0
    private var previousApp: NSRunningApplication?
    private var floatingCaptures: [FloatingCaptureWindow] = []
    private var editors: [EditorWindowController] = []
    /// Display frames when the current capture started.
    private var captureScreenFrames: [CGRect] = []
    private var screenObserver: NSObjectProtocol?
    /// The selection is for a long screenshot rather than a plain capture.
    private var selectsScrollingRegion = false
    /// The selection is for a delayed capture: the region is taken when the countdown ends.
    private var selectsDelayedRegion = false
    private var scrollSession: ScrollCaptureSession?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensDidChange() }
        }
    }

    /// A display was added, removed or rearranged. A selection in progress no longer matches the
    /// screens, so it's cancelled; pinned captures left where a display used to be come back.
    private func screensDidChange() {
        let frames = NSScreen.screens.map(\.frame)
        if isCapturing, frames != captureScreenFrames { cancelSelection() }
        guard let main = NSScreen.main ?? NSScreen.screens.first else { return }
        for window in floatingCaptures where !ScreenGeometry.isReachable(window.frame, on: frames) {
            window.setFrame(ScreenGeometry.centered(window.frame.size, in: main.visibleFrame), display: true)
        }
    }

    /// Opens edit mode. When it ends, the capture floats again with its annotations:
    /// at `returnFrame`'s top-left corner if given, otherwise in the middle of the screen.
    func openEditor(
        for capture: Capture,
        history: EditHistory<AnnotationDocument>? = nil,
        on screen: NSScreen,
        returnFrame: CGRect? = nil,
        historyID: UUID? = nil
    ) {
        let editor = EditorWindowController(capture: capture, history: history, screen: screen)
        editor.onClose = { [weak self] closed in self?.editors.removeAll { $0 === closed } }
        editor.onExit = { [weak self] history in
            // A crop in edit mode changes the size; keep the top-left corner where it was.
            let size = history.current.outputRect.size
            let visible = screen.visibleFrame
            let frame = returnFrame.map { CGRect(x: $0.minX, y: $0.maxY - size.height, width: size.width, height: size.height) }
                ?? CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
            self?.pin(capture, history: history, at: frame, on: screen, historyID: historyID)
        }
        editors.append(editor)
        editor.show()
    }

    /// Opens an image file in the editor.
    func openEditor(forImageAt url: URL) {
        guard let capture = Self.loadCapture(at: url), let screen = NSScreen.main else { return }
        openEditor(for: capture, on: screen)
    }

    /// Development: records an image file in history as if it had just been captured.
    func addToHistory(imageAt url: URL) {
        guard let capture = Self.loadCapture(at: url) else { return }
        HistoryLibrary.shared.add(capture, sourceApp: NSWorkspace.shared.frontmostApplication)
    }

    /// Floats a capture from history in the middle of the screen under the cursor.
    func pinHistoryEntry(_ entry: HistoryEntry) {
        let mouse = NSEvent.mouseLocation
        guard let capture = HistoryLibrary.shared.loadCapture(entry),
              let screen = NSScreen.screens.first(where: { ScreenGeometry.screen($0.frame, containsMouse: mouse) }) ?? NSScreen.main
        else { return }
        pin(capture, at: ScreenGeometry.centered(capture.pointSize, in: screen.visibleFrame), on: screen, historyID: entry.id)
    }

    /// Floats an image file in the middle of the screen under the cursor, optionally pinned (no bar).
    func pinImage(at url: URL, pinned: Bool = false) {
        let mouse = NSEvent.mouseLocation
        guard let capture = Self.loadCapture(at: url),
              let screen = NSScreen.screens.first(where: { ScreenGeometry.screen($0.frame, containsMouse: mouse) }) ?? NSScreen.main
        else { return }
        pin(capture, at: ScreenGeometry.centered(capture.pointSize, in: screen.visibleFrame), on: screen)
        if pinned { floatingCaptures.last?.setPinned(true) }
        if CommandLine.arguments.contains("--bar") { floatingCaptures.last?.showBar() }
    }

    /// Development: shows the selection overlay over an image file instead of the live screen.
    func showOverlay(forImageAt url: URL) {
        guard !isCapturing, let capture = Self.loadCapture(at: url),
              let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) else { return }
        isCapturing = true
        captureScreenFrames = NSScreen.screens.map(\.frame)
        sessionID += 1
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        showOverlay(
            for: FrozenScreen(screen: screen, image: capture.image),
            windows: WindowDetector.visibleWindows(primaryScreenHeight: primaryHeight),
            isFirst: true,
            timing: CaptureTiming()
        )
    }

    /// Loads an image file, using its DPI to recover the Retina scale.
    private static func loadCapture(at url: URL) -> Capture? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            NSLog("PixSnap could not open \(url.path)")
            return nil
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        return Capture(image: image, scale: max(1, dpi / 72))
    }

    /// Called with the timings once the overlay has drawn its first frame.
    var onOverlayDrawn: ((CaptureTiming) -> Void)?

    func startCapture() {
        startCapture(timing: CaptureTiming())
    }

    /// The whole screen under the cursor, at once.
    func startFullScreenCapture() {
        guard !isCapturing, PermissionGuide.ensureScreenCapture() else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { ScreenGeometry.screen($0.frame, containsMouse: mouse) }) ?? NSScreen.main else { return }
        let sourceApp = NSWorkspace.shared.frontmostApplication
        Task {
            do {
                let image = try await ScreenCapturer.shared.captureDisplay(screen)
                let capture = Capture(image: image, scale: screen.backingScaleFactor)
                // Floated at half size in the middle, so it doesn't look like the screen itself.
                let visible = screen.visibleFrame
                let fit = min(0.5, (visible.width - 80) / capture.pointSize.width, (visible.height - 80) / capture.pointSize.height)
                let size = CGSize(width: (capture.pointSize.width * fit).rounded(), height: (capture.pointSize.height * fit).rounded())
                keep(capture, sourceApp: sourceApp, at: ScreenGeometry.centered(size, in: visible), on: screen)
            } catch {
                NSLog("PixSnap full-screen capture failed: \(error)")
                PermissionGuide.showScreenCaptureAlert()
            }
        }
    }

    private var countdown: CountdownWindow?

    /// Select a region first; it stays outlined while a countdown runs beside it (time to open a
    /// menu, hover something, or let an animation get there), then what's in it right then is
    /// captured.
    func startDelayedCapture() {
        guard !isCapturing, countdown == nil else { return }
        selectsDelayedRegion = true
        startCapture()
        if !isCapturing { selectsDelayedRegion = false }
    }

    /// Development: a delayed capture of `region` (global AppKit coordinates) without selecting it.
    func startDelayedCapture(of region: CGRect) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(region) }) else { return }
        startCountdown(over: region, on: screen, sourceApp: nil)
    }

    private func startCountdown(over region: CGRect, on screen: NSScreen, sourceApp: NSRunningApplication?) {
        let outline = RegionFrameWindow(region: region, screen: screen)
        let window = CountdownWindow(seconds: AppSettings.shared.captureDelay, beside: region, on: screen)
        window.onFinish = { [weak self] in
            outline.orderOut(nil)
            self?.countdown = nil
            Task {
                do {
                    let image = try await ScreenCapturer.shared.captureRegion(region, on: screen)
                    self?.keep(Capture(image: image, scale: screen.backingScaleFactor), sourceApp: sourceApp, at: region, on: screen)
                } catch {
                    NSLog("PixSnap delayed capture failed: \(error)")
                    NSSound.beep()
                }
            }
        }
        window.onCancel = { [weak self] in
            outline.orderOut(nil)
            self?.countdown = nil
        }
        countdown = window
        outline.orderFrontRegardless()
        window.start()
    }

    /// The window under the cursor, by itself.
    func startWindowCapture() {
        guard !isCapturing, PermissionGuide.ensureScreenCapture() else { return }
        guard let target = WindowDetector.window(at: NSEvent.mouseLocation) else {
            NSSound.beep()
            return
        }
        let sourceApp = NSRunningApplication(processIdentifier: Self.ownerPID(of: target.id) ?? 0)
        captureWindow(target.id, frame: target.frame, sourceApp: sourceApp)
    }

    private static func ownerPID(of window: CGWindowID) -> pid_t? {
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, window) as? [[String: Any]]
        return info?.first?[kCGWindowOwnerPID as String] as? pid_t
    }

    /// Captures one window by itself, finished the way Settings says (shadow, background), and
    /// floats it centered where the window is.
    private func captureWindow(_ id: CGWindowID, frame: CGRect, sourceApp: NSRunningApplication?) {
        let style = AppSettings.shared.windowCaptureStyle
        // The screen showing most of the window.
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.frame.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        let screen = NSScreen.screens.max { overlap($0) < overlap($1) } ?? NSScreen.main
        Task {
            do {
                let (image, scale) = try await ScreenCapturer.shared.captureWindow(id)
                let finished = WindowBackdrop.render(image, scale: scale, background: style.background, shadow: style.keepsShadow) ?? image
                let capture = Capture(image: finished, scale: scale)
                guard let screen else { return }
                let visible = screen.visibleFrame
                let fit = min(1, (visible.width - 40) / capture.pointSize.width, (visible.height - 60) / capture.pointSize.height)
                let size = CGSize(width: (capture.pointSize.width * fit).rounded(), height: (capture.pointSize.height * fit).rounded())
                var origin = CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
                origin.x = min(max(origin.x, visible.minX + 10), visible.maxX - size.width - 10)
                origin.y = min(max(origin.y, visible.minY + 50), visible.maxY - size.height - 10)
                keep(capture, sourceApp: sourceApp, at: CGRect(origin: origin, size: size), on: screen)
            } catch {
                NSLog("PixSnap window capture failed: \(error)")
                NSSound.beep()
            }
        }
    }

    /// What every finished capture goes through: copied if Settings says so, kept in history,
    /// and floated at `frame`.
    private func keep(_ capture: Capture, sourceApp: NSRunningApplication?, at frame: CGRect, on screen: NSScreen) {
        if AppSettings.shared.copiesAfterCapture { ImageExporter.copyToPasteboard(capture) }
        let entry = HistoryLibrary.shared.add(capture, sourceApp: sourceApp)
        pin(capture, at: frame, on: screen, historyID: entry?.id)
    }

    /// A long screenshot: select the region as usual, then scroll its content while PixSnap
    /// stitches it together.
    func startScrollingCapture() {
        guard !isCapturing, scrollSession == nil else { return }
        selectsScrollingRegion = true
        startCapture()
        if !isCapturing { selectsScrollingRegion = false }
    }

    func startCapture(timing: CaptureTiming) {
        guard !isCapturing else { return }
        guard PermissionGuide.ensureScreenCapture() else { return }
        isCapturing = true
        captureScreenFrames = NSScreen.screens.map(\.frame)
        timing.mark("权限")

        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        // The window list is read on another thread while the screens are being captured.
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let windowList = Task.detached(priority: .userInitiated) {
            WindowDetector.visibleWindows(primaryScreenHeight: primaryHeight)
        }

        sessionID += 1
        let session = sessionID
        // The status bar item is always there; any other visible window (a pinned capture, the
        // editor, Settings) has to be kept out of the screenshot.
        let hasOwnWindowsOnScreen = NSApp.windows.contains { $0.isVisible && !$0.className.contains("StatusBar") }

        Task {
            var shownAny = false
            do {
                try await ScreenCapturer.shared.captureScreens(hasOwnWindowsOnScreen: hasOwnWindowsOnScreen, timing: timing) { frozen in
                    let windowFrames = await windowList.value
                    // Esc, a finished selection or a newer capture: drop screens that arrive late.
                    guard isCapturing, sessionID == session else { return }
                    showOverlay(for: frozen, windows: windowFrames, isFirst: !shownAny, timing: timing)
                    shownAny = true
                }
                if !shownAny, sessionID == session { isCapturing = false }
            } catch {
                guard !shownAny, sessionID == session else { return }
                isCapturing = false
                NSLog("PixSnap capture failed: \(error)")
                PermissionGuide.showScreenCaptureAlert()
            }
        }
    }

    /// Shows the overlay for one screen as soon as its image is ready; the screen under the cursor is
    /// captured first, so that's normally the first to appear.
    private func showOverlay(for frozen: FrozenScreen, windows: [(id: CGWindowID, frame: CGRect)], isFirst: Bool, timing: CaptureTiming) {
        if isFirst { NSApp.activate() }
        let window = SelectionWindow(frozen: frozen, windowFrames: windows.map(\.frame))
        window.selectionView.onSelect = { [weak self] rect in self?.finish(frozen: frozen, viewRect: rect) }
        // A clicked window is captured by itself, unless this selection is for a long screenshot or a
        // delayed capture, where its frame is just the region.
        if !selectsScrollingRegion, !selectsDelayedRegion {
            window.selectionView.onSelectWindow = { [weak self] index in
                guard let self else { return }
                let sourceApp = previousApp
                endSession()
                captureWindow(windows[index].id, frame: windows[index].frame, sourceApp: sourceApp)
            }
        }
        window.selectionView.onCancel = { [weak self] in self?.endSession() }
        window.orderFrontRegardless()
        overlays.append(window)

        let isUnderMouse = NSMouseInRect(NSEvent.mouseLocation, frozen.screen.frame, false)
        // Keyboard focus goes to the screen under the cursor so Esc works right away.
        if isUnderMouse {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(window.selectionView)
        }

        // Draw now and hand the frame to the window server instead of waiting for the next run loop pass.
        window.displayIfNeeded()
        CATransaction.flush()
        if isUnderMouse {
            timing.mark(CaptureTiming.firstFrameStage)
            timing.log()
            onOverlayDrawn?(timing)
        }
    }

    /// Ends the selection without capturing, as Esc does.
    func cancelSelection() {
        guard isCapturing else { return }
        endSession()
    }

    private func finish(frozen: FrozenScreen, viewRect: CGRect) {
        let pixelRect = SelectionGeometry.pixelRect(
            forViewRect: viewRect,
            viewSize: frozen.screen.frame.size,
            imageSize: frozen.imageSize
        )
        // The app that was in front when the capture started, recorded in history ("微信", "Figma"…).
        let sourceApp = previousApp
        let scrolling = selectsScrollingRegion, delayed = selectsDelayedRegion
        endSession()
        let scale = frozen.screen.backingScaleFactor
        if scrolling || delayed {
            let screenFrame = frozen.screen.frame
            let region = CGRect(x: screenFrame.minX + pixelRect.minX / scale, y: screenFrame.minY + screenFrame.height - pixelRect.maxY / scale,
                                width: pixelRect.width / scale, height: pixelRect.height / scale).integral
            if scrolling {
                guard region.width >= 20, region.height >= 40 else { return }
                startScrolling(in: region, on: frozen.screen, sourceApp: sourceApp)
            } else {
                guard region.width >= 1, region.height >= 1 else { return }
                startCountdown(over: region, on: frozen.screen, sourceApp: sourceApp)
            }
            return
        }
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = frozen.image.cropping(to: pixelRect) else { return }

        let capture = Capture(image: cropped, scale: scale)
        if AppSettings.shared.copiesAfterCapture { ImageExporter.copyToPasteboard(capture) }
        let entry = HistoryLibrary.shared.add(capture, sourceApp: sourceApp)
        // Pin it exactly where it was taken (pixel rect has a top-left origin; the screen a bottom-left one).
        let screenFrame = frozen.screen.frame
        let imageFrame = CGRect(
            x: screenFrame.minX + pixelRect.minX / scale,
            y: screenFrame.minY + screenFrame.height - pixelRect.maxY / scale,
            width: capture.pointSize.width,
            height: capture.pointSize.height
        )
        pin(capture, at: imageFrame, on: frozen.screen, historyID: entry?.id)
    }

    private func pin(
        _ capture: Capture,
        history: EditHistory<AnnotationDocument>? = nil,
        at imageFrame: CGRect,
        on screen: NSScreen,
        historyID: UUID? = nil
    ) {
        let floating = FloatingCaptureWindow(capture: capture, history: history, imageFrame: imageFrame, screen: screen, historyID: historyID)
        floating.onEdit = { [weak self] window in
            let frame = window.imageFrame
            let history = window.history
            window.close()
            self?.openEditor(for: window.capture, history: history, on: screen, returnFrame: frame, historyID: window.historyID)
        }
        floating.onClosed = { [weak self] window in self?.floatingCaptures.removeAll { $0 === window } }
        floatingCaptures.append(floating)
        floating.orderFrontRegardless()
    }

    /// Development: a long screenshot of `region` (global AppKit coordinates) without selecting it,
    /// finished after `seconds`, also written to `output` as PNG.
    func startScrollingCapture(in region: CGRect, finishingAfter seconds: Double, writingTo output: URL?) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(region) }) else { return }
        startScrolling(in: region, on: screen, sourceApp: nil)
        let session = scrollSession
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { session?.finishNow() }
        scrollOutput = output
    }

    private var scrollOutput: URL?

    /// Runs the long screenshot over `region`; when it's done, it floats like any capture, shrunk
    /// to fit the screen, and goes into history.
    private func startScrolling(in region: CGRect, on screen: NSScreen, sourceApp: NSRunningApplication?) {
        let session = ScrollCaptureSession(region: region, on: screen)
        session.onFinish = { [weak self] capture in
            self?.scrollSession = nil
            guard let self, let capture else { return }
            if let output = scrollOutput, let png = ImageExporter.pngData(for: capture) {
                try? png.write(to: output)
                scrollOutput = nil
            }
            if AppSettings.shared.copiesAfterCapture { ImageExporter.copyToPasteboard(capture) }
            let entry = HistoryLibrary.shared.add(capture, sourceApp: sourceApp)
            // Its top where the region's top was, as tall as the screen allows.
            let visible = screen.visibleFrame
            let fit = min(1, (visible.height - 60) / capture.pointSize.height, (visible.width - 40) / capture.pointSize.width)
            let size = CGSize(width: (capture.pointSize.width * fit).rounded(), height: (capture.pointSize.height * fit).rounded())
            let top = min(region.maxY, visible.maxY - 10)
            let x = min(max(region.midX - size.width / 2, visible.minX + 10), visible.maxX - size.width - 10)
            pin(capture, at: CGRect(x: x, y: top - size.height, width: size.width, height: size.height), on: screen, historyID: entry?.id)
        }
        scrollSession = session
        session.start()
    }

    private func endSession() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        isCapturing = false
        selectsScrollingRegion = false
        selectsDelayedRegion = false
        previousApp?.activate()
        previousApp = nil
    }
}
