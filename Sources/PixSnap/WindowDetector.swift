import AppKit

/// Lists the frames of visible app windows so the overlay can highlight the one under the cursor.
@MainActor
enum WindowDetector {
    /// Window frames in global AppKit coordinates (bottom-left origin), front-most first.
    static func visibleWindowFrames() -> [CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
              let primaryScreen = NSScreen.screens.first else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        // CGWindow bounds use a top-left origin relative to the primary display.
        let primaryHeight = primaryScreen.frame.maxY

        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width > 40, frame.height > 40 else { return nil }
            return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        }
    }
}
