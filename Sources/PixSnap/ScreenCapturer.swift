import AppKit
import PixSnapCore
@preconcurrency import ScreenCaptureKit

/// One display captured at full resolution right before the selection overlay appears,
/// so the user selects from a still image instead of a moving screen.
struct FrozenScreen {
    let screen: NSScreen
    let image: CGImage

    var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
}

/// A finished capture, ready to copy, save or drag.
struct Capture {
    let image: CGImage
    /// Pixels per point of the screen it came from (2 on Retina).
    let scale: CGFloat
    let date = Date()

    var pointSize: CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }
}

/// Captures every display with ScreenCaptureKit. Fetching the list of displays takes ~25 ms, so it's
/// cached: fetched at launch, refreshed in the background after each capture and when displays change.
@MainActor
final class ScreenCapturer {
    static let shared = ScreenCapturer()

    private var cachedContent: SCShareableContent?
    /// PixSnap itself, used to keep its own windows (pinned captures) out of screenshots. The display
    /// list only names apps that have windows on screen, so this is remembered once it's been seen.
    private var ownApplication: SCRunningApplication?
    private var screenObserver: NSObjectProtocol?

    private init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInBackground() }
        }
    }

    /// Loads the display list and runs one tiny capture so the first real capture isn't slowed by
    /// ScreenCaptureKit starting up.
    func warmUp() async {
        guard CGPreflightScreenCaptureAccess(), let content = try? await freshContent(),
              let display = content.displays.first else { return }
        let configuration = SCStreamConfiguration()
        configuration.width = 16
        configuration.height = 16
        _ = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration
        )
    }

    /// Captures every display, the one under the cursor first, calling `onScreen` as each image arrives
    /// so its overlay can appear without waiting for the others.
    /// `hasOwnWindowsOnScreen`: PixSnap windows are visible and must be left out of the images.
    func captureScreens(
        hasOwnWindowsOnScreen: Bool,
        timing: CaptureTiming,
        onScreen: (FrozenScreen) async -> Void
    ) async throws {
        var content = try await contentForCapture()
        let missingDisplay = NSScreen.screens.contains { screen in !content.displays.contains { $0.displayID == screen.displayID } }
        if missingDisplay || (hasOwnWindowsOnScreen && ownApplication == nil) {
            content = try await freshContent()
        }
        timing.mark("屏幕信息")

        let excluded = ownApplication.map { [$0] } ?? []
        let allScreens = NSScreen.screens
        let screens = ScreenGeometry.indicesStartingWithScreen(under: NSEvent.mouseLocation, in: allScreens.map(\.frame))
            .map { allScreens[$0] }
        let jobs: [(screen: NSScreen, filter: SCContentFilter, configuration: SCStreamConfiguration)] =
            screens.compactMap { screen in
                guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return nil }
                let configuration = SCStreamConfiguration()
                let scale = screen.backingScaleFactor
                configuration.width = Int(CGFloat(display.width) * scale)
                configuration.height = Int(CGFloat(display.height) * scale)
                configuration.showsCursor = false
                configuration.captureResolution = .best
                let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
                return (screen, filter, configuration)
            }

        // ScreenCaptureKit works through requests one at a time in its own order, so the screen under
        // the cursor goes alone and first; the others are requested together once it's on screen.
        if let first = jobs.first {
            let image = try await SCScreenshotManager.captureImage(contentFilter: first.filter, configuration: first.configuration)
            timing.mark("截取屏幕1")
            await onScreen(FrozenScreen(screen: first.screen, image: image))
        }
        try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            for (index, job) in jobs.enumerated().dropFirst() {
                let filter = job.filter, configuration = job.configuration
                group.addTask {
                    (index, try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration))
                }
            }
            for try await (index, image) in group {
                timing.mark("截取屏幕\(index + 1)")
                await onScreen(FrozenScreen(screen: jobs[index].screen, image: image))
            }
        }
        refreshInBackground()
    }

    /// Captures all of `screen` at full resolution, leaving PixSnap's own windows out.
    func captureDisplay(_ screen: NSScreen) async throws -> CGImage {
        try await captureRegion(screen.frame, on: screen)
    }

    /// A recorder for `rect` (global AppKit coordinates, inside `screen`), leaving out only the
    /// windows numbered `windowNumbers` (the recording's own frame and controls); PixSnap's other
    /// windows are recorded like any app's.
    func makeRecorder(for rect: CGRect, on screen: NSScreen, fps: Int, showsCursor: Bool, systemAudio: Bool = false, microphone: Bool = false,
                      microphoneID: String? = nil, hidingNotifications: Bool = false,
                      hiding windowNumbers: [Int]) async throws -> ScreenRecorder {
        // Fresh, so the windows to hide (just put on screen) are in it.
        var content = try await freshContent()
        let wanted = Set(windowNumbers.map(CGWindowID.init))
        if content.windows.filter({ wanted.contains($0.windowID) }).count < wanted.count {
            try await Task.sleep(for: .milliseconds(150))
            content = try await freshContent()
        }
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CocoaError(.featureUnsupported)
        }
        // Notification banners belong to Notification Center's own process.
        let hidden = content.windows.filter {
            wanted.contains($0.windowID) || (hidingNotifications && $0.owningApplication?.bundleIdentifier == "com.apple.notificationcenterui")
        }
        let filter = SCContentFilter(display: display, excludingWindows: hidden)
        let sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        return try ScreenRecorder(filter: filter, sourceRect: sourceRect,
                                  pixelSize: recordingPixelSize(points: rect.size, scale: screen.backingScaleFactor),
                                  fps: fps, showsCursor: showsCursor, recordsSystemAudio: systemAudio, recordsMicrophone: microphone,
                                  microphoneID: microphoneID)
    }

    /// Captures one window by itself: nothing in front of or behind it, on transparency. The capture
    /// covers only the window's frame, so its shadow is added afterwards (`WindowBackdrop`).
    /// Returns the image and its pixels per point.
    func captureWindow(_ id: CGWindowID) async throws -> (image: CGImage, scale: CGFloat) {
        var content = try await contentForCapture()
        if !content.windows.contains(where: { $0.windowID == id }) { content = try await freshContent() }
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CocoaError(.fileNoSuchFile) }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int((filter.contentRect.width * scale).rounded())
        configuration.height = Int((filter.contentRect.height * scale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return (image, scale)
    }

    /// Captures `rect` (global AppKit coordinates, inside `screen`) at the screen's full
    /// resolution, leaving PixSnap's own windows out. Used over and over by long screenshots.
    func captureRegion(_ rect: CGRect, on screen: NSScreen) async throws -> CGImage {
        var content = try await contentForCapture()
        if ownApplication == nil || !content.displays.contains(where: { $0.displayID == screen.displayID }) {
            content = try await freshContent()
        }
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CocoaError(.featureUnsupported)
        }
        let scale = screen.backingScaleFactor
        let configuration = SCStreamConfiguration()
        // The display's own coordinates: points, top-left origin.
        configuration.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                                          width: rect.width, height: rect.height)
        configuration.width = Int((rect.width * scale).rounded())
        configuration.height = Int((rect.height * scale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        let filter = SCContentFilter(display: display, excludingApplications: ownApplication.map { [$0] } ?? [], exceptingWindows: [])
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private func contentForCapture() async throws -> SCShareableContent {
        if let cachedContent { return cachedContent }
        return try await freshContent()
    }

    private func freshContent() async throws -> SCShareableContent {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cachedContent = content
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let own = content.applications.first(where: { $0.processID == ownPID }) { ownApplication = own }
        return content
    }

    private func refreshInBackground() {
        Task { _ = try? await freshContent() }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
