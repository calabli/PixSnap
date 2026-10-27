import AppKit
import PixSnapCore

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
        returnFrame: CGRect? = nil
    ) {
        let editor = EditorWindowController(capture: capture, history: history, screen: screen)
        editor.onClose = { [weak self] closed in self?.editors.removeAll { $0 === closed } }
        editor.onExit = { [weak self] history in
            // A crop in edit mode changes the size; keep the top-left corner where it was.
            let size = history.current.outputRect.size
            let visible = screen.visibleFrame
            let frame = returnFrame.map { CGRect(x: $0.minX, y: $0.maxY - size.height, width: size.width, height: size.height) }
                ?? CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
            self?.pin(capture, history: history, at: frame, on: screen)
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
        pin(capture, at: ScreenGeometry.centered(capture.pointSize, in: screen.visibleFrame), on: screen)
    }

    /// Floats an image file in the middle of the screen under the cursor, optionally pinned (no bar).
    func pinImage(at url: URL, pinned: Bool = false) {
        let mouse = NSEvent.mouseLocation
        guard let capture = Self.loadCapture(at: url),
              let screen = NSScreen.screens.first(where: { ScreenGeometry.screen($0.frame, containsMouse: mouse) }) ?? NSScreen.main
        else { return }
        pin(capture, at: ScreenGeometry.centered(capture.pointSize, in: screen.visibleFrame), on: screen)
        if pinned { floatingCaptures.last?.setPinned(true) }
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
            windowFrames: WindowDetector.visibleWindowFrames(primaryScreenHeight: primaryHeight),
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
            WindowDetector.visibleWindowFrames(primaryScreenHeight: primaryHeight)
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
                    showOverlay(for: frozen, windowFrames: windowFrames, isFirst: !shownAny, timing: timing)
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
    private func showOverlay(for frozen: FrozenScreen, windowFrames: [CGRect], isFirst: Bool, timing: CaptureTiming) {
        if isFirst { NSApp.activate() }
        let window = SelectionWindow(frozen: frozen, windowFrames: windowFrames)
        window.selectionView.onSelect = { [weak self] rect in self?.finish(frozen: frozen, viewRect: rect) }
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
        endSession()
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = frozen.image.cropping(to: pixelRect) else { return }

        let scale = frozen.screen.backingScaleFactor
        let capture = Capture(image: cropped, scale: scale)
        if AppSettings.shared.copiesAfterCapture { ImageExporter.copyToPasteboard(capture) }
        HistoryLibrary.shared.add(capture, sourceApp: sourceApp)
        // Pin it exactly where it was taken (pixel rect has a top-left origin; the screen a bottom-left one).
        let screenFrame = frozen.screen.frame
        let imageFrame = CGRect(
            x: screenFrame.minX + pixelRect.minX / scale,
            y: screenFrame.minY + screenFrame.height - pixelRect.maxY / scale,
            width: capture.pointSize.width,
            height: capture.pointSize.height
        )
        pin(capture, at: imageFrame, on: frozen.screen)
    }

    private func pin(
        _ capture: Capture,
        history: EditHistory<AnnotationDocument>? = nil,
        at imageFrame: CGRect,
        on screen: NSScreen
    ) {
        let floating = FloatingCaptureWindow(capture: capture, history: history, imageFrame: imageFrame, screen: screen)
        floating.onEdit = { [weak self] window in
            let frame = window.imageFrame
            let history = window.history
            window.close()
            self?.openEditor(for: window.capture, history: history, on: screen, returnFrame: frame)
        }
        floating.onClosed = { [weak self] window in self?.floatingCaptures.removeAll { $0 === window } }
        floatingCaptures.append(floating)
        floating.orderFrontRegardless()
    }

    private func endSession() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        isCapturing = false
        previousApp?.activate()
        previousApp = nil
    }
}
