import AppKit
import PixSnapCore

/// Lists the frames of visible app windows so the overlay can highlight the one under the cursor.
enum WindowDetector {
    /// Window frames in global AppKit coordinates (bottom-left origin), front-most first.
    /// Safe to call off the main thread; `primaryScreenHeight` is the main display's height.
    static func visibleWindowFrames(primaryScreenHeight: CGFloat) -> [CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width > 40, frame.height > 40 else { return nil }
            return ScreenGeometry.appKitRect(fromCGRect: frame, primaryScreenHeight: primaryScreenHeight)
        }
    }
}
