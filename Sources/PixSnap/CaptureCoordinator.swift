import AppKit
import PixSnapCore

/// Runs one capture: freeze every screen, let the user select, then pin the result on screen.
@MainActor
final class CaptureCoordinator {
    private var overlays: [SelectionWindow] = []
    private var isCapturing = false
    private var previousApp: NSRunningApplication?
    private var floatingCaptures: [FloatingCaptureWindow] = []
    private var editors: [EditorWindowController] = []

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

    /// Pins an image file in the middle of the main screen.
    func pinImage(at url: URL) {
        guard let capture = Self.loadCapture(at: url), let screen = NSScreen.main else { return }
        let size = capture.pointSize
        let visible = screen.visibleFrame
        pin(capture, at: CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                width: size.width, height: size.height), on: screen)
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

    func startCapture() {
        guard !isCapturing else { return }
        guard PermissionGuide.ensureScreenCapture() else { return }
        isCapturing = true

        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        let windowFrames = WindowDetector.visibleWindowFrames()

        Task {
            do {
                let frozen = try await ScreenCapturer.captureAllScreens()
                showOverlays(for: frozen, windowFrames: windowFrames)
            } catch {
                isCapturing = false
                NSLog("PixSnap capture failed: \(error)")
                PermissionGuide.showScreenCaptureAlert()
            }
        }
    }

    private func showOverlays(for frozenScreens: [FrozenScreen], windowFrames: [CGRect]) {
        guard !frozenScreens.isEmpty else {
            isCapturing = false
            return
        }
        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        for frozen in frozenScreens {
            let window = SelectionWindow(frozen: frozen, windowFrames: windowFrames)
            window.selectionView.onSelect = { [weak self] rect in self?.finish(frozen: frozen, viewRect: rect) }
            window.selectionView.onCancel = { [weak self] in self?.endSession() }
            window.orderFrontRegardless()
            overlays.append(window)
            // Keyboard focus goes to the screen under the cursor so Esc works right away.
            if NSMouseInRect(mouse, frozen.screen.frame, false) {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(window.selectionView)
            }
        }
    }

    private func finish(frozen: FrozenScreen, viewRect: CGRect) {
        let pixelRect = SelectionGeometry.pixelRect(
            forViewRect: viewRect,
            viewSize: frozen.screen.frame.size,
            imageSize: frozen.imageSize
        )
        endSession()
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = frozen.image.cropping(to: pixelRect) else { return }

        let scale = frozen.screen.backingScaleFactor
        let capture = Capture(image: cropped, scale: scale)
        if AppSettings.shared.copiesAfterCapture { ImageExporter.copyToPasteboard(capture) }
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
