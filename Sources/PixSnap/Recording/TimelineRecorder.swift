import AppKit
import ApplicationServices
import PixSnapCore

/// Writes down a recording's timeline as it's made (see `RecordingTimeline`): the pointer's path
/// about 30 times a second, every click with the name of what it landed on (asked of the system
/// when PixSnap may use accessibility), shortcuts, and ⌥⇧M marks. Times come from the recorder,
/// so pauses are left out like they are in the video.
@MainActor
final class TimelineRecorder {
    private(set) var timeline: RecordingTimeline
    private let region: CGRect
    private weak var recorder: ScreenRecorder?
    private var monitors: [Any] = []
    private var lastMove: TimeInterval = 0

    init(region: CGRect, recorder: ScreenRecorder) {
        self.region = region
        self.recorder = recorder
        timeline = RecordingTimeline(width: region.width, height: region.height)
    }

    func start() {
        let pointer: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        for mask in [pointer, clicks, NSEvent.EventTypeMask.keyDown] {
            monitors.append(NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated { self?.take(event) }
            } as Any)
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.take(event)
                return event
            } as Any)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// A step marked by hand (⌥⇧M, or the flag on the controls), now.
    func mark() {
        guard let t = recorder?.videoTime(atHostSeconds: ProcessInfo.processInfo.systemUptime) else { return }
        timeline.marks.append(t)
    }

    /// Saved beside the video: `<video name>.timeline.json`.
    static func url(forVideo video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("timeline.json")
    }

    func save(besideVideo video: URL) {
        guard let data = try? JSONEncoder().encode(timeline) else { return }
        try? data.write(to: Self.url(forVideo: video))
    }

    private func take(_ event: NSEvent) {
        guard let t = recorder?.videoTime(atHostSeconds: event.timestamp) else { return }
        let location = NSEvent.mouseLocation
        let x = (location.x - region.minX) / max(region.width, 1)
        let y = (region.maxY - location.y) / max(region.height, 1)
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard event.timestamp - lastMove >= 1.0 / 30 else { return }
            lastMove = event.timestamp
            timeline.moves.append(.init(t: t, x: x, y: y))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button: RecordingTimeline.Click.Button = event.type == .leftMouseDown ? .left : event.type == .rightMouseDown ? .right : .other
            timeline.clicks.append(.init(t: t, x: x, y: y, button: button, count: max(1, event.clickCount),
                                         element: Self.elementName(at: location),
                                         app: NSWorkspace.shared.frontmostApplication?.localizedName))
            timeline.moves.append(.init(t: t, x: x, y: y))
        case .keyDown:
            let flags = event.modifierFlags
            var modifiers: ShortcutModifiers = []
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.command) { modifiers.insert(.command) }
            if let label = Keystroke.label(keyCode: event.keyCode, modifiers: modifiers, characters: event.charactersIgnoringModifiers) {
                timeline.keys.append(.init(t: t, label: label))
            }
        default:
            break
        }
    }

    /// The name of the control at `point` (screen coordinates, bottom-left origin): its title, or
    /// its description when it has none, or a label's text. A text field's value is what was typed
    /// in it (a password, say), so that's never read. Nil without accessibility permission.
    static func elementName(at point: CGPoint) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let top = (NSScreen.screens.first?.frame.maxY ?? 0) - point.y
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(top), &element) == .success,
              var current = element else { return nil }
        // A label inside a button names the button: look a couple of levels up for a title.
        for _ in 0 ..< 3 {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role)
            let isLabel = (role as? String) == kAXStaticTextRole as String
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] + (isLabel ? [kAXValueAttribute] : []) {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(current, attribute as CFString, &value) == .success,
                   let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 60 {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { break }
            current = next as! AXUIElement
        }
        return nil
    }
}
