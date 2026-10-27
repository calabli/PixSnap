import AppKit

/// Drags a capture out to other apps as a PNG file: chat apps, mail, Finder, design tools all take
/// a file URL, and the PNG data rides along for apps that only take images. The picture under the
/// mouse shrinks to a handy size around the cursor, and slides back if nothing takes it.
@MainActor
enum CaptureDrag {
    /// The longest side of the picture that follows the mouse.
    private static let maximumDragSide: CGFloat = 220

    /// Starts dragging `capture` from `view`. `frame` is where its picture is now, in `view`'s
    /// coordinates, and `image` what it looks like there. `ended` is called when the drag is over,
    /// with whether some app took it.
    static func begin(_ capture: Capture, image: NSImage, from frame: CGRect, in view: NSView, event: NSEvent,
                      ended: @escaping (Bool) -> Void = { _ in }) {
        let url: URL
        do {
            url = try ImageExporter.temporaryFile(for: capture)
        } catch {
            NSLog("PixSnap could not prepare a capture for dragging: \(error)")
            return
        }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if let png = try? Data(contentsOf: url) { item.setData(png, forType: .png) }

        let dragging = NSDraggingItem(pasteboardWriter: item)
        // A smaller copy, centered where the mouse holds the picture.
        let mouse = view.convert(event.locationInWindow, from: nil)
        let scale = min(1, maximumDragSide / max(frame.width, frame.height, 1))
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        // Held by the same spot it was picked up by; from a handle beside it, by the nearest edge.
        let grab = CGPoint(x: min(max((mouse.x - frame.minX) / max(frame.width, 1), 0), 1),
                           y: min(max((mouse.y - frame.minY) / max(frame.height, 1), 0), 1))
        dragging.setDraggingFrame(CGRect(x: mouse.x - size.width * grab.x, y: mouse.y - size.height * grab.y,
                                         width: size.width, height: size.height), contents: image)

        let source = Source(ended: ended)
        let session = view.beginDraggingSession(with: [dragging], event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    /// Keeps itself alive for the length of the drag.
    private final class Source: NSObject, NSDraggingSource {
        private static var active: Set<Source> = []
        private let ended: (Bool) -> Void

        init(ended: @escaping (Bool) -> Void) {
            self.ended = ended
            super.init()
            Self.active.insert(self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            MainActor.assumeIsolated {
                ended(operation != [])
                Self.active.remove(self)
            }
        }
    }
}
