import AppKit
import ScreenCaptureKit

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

@MainActor
enum ScreenCapturer {
    static func captureAllScreens() async throws -> [FrozenScreen] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }

        var frozen: [FrozenScreen] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else { continue }

            let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            configuration.width = Int(CGFloat(display.width) * scale)
            configuration.height = Int(CGFloat(display.height) * scale)
            configuration.showsCursor = false
            configuration.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            frozen.append(FrozenScreen(screen: screen, image: image))
        }
        return frozen
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
