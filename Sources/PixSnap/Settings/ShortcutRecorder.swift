import AppKit
import Observation
import PixSnapCore

/// Records a new shortcut for one capture mode from the next key press in the Settings window.
@MainActor
@Observable
final class ShortcutRecorder {
    /// The mode being recorded, if any.
    private(set) var recording: CaptureAction?
    /// Why the last key press wasn't accepted, and for which mode, shown under its row.
    private(set) var message: (action: CaptureAction, text: String)?

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private let service: CaptureShortcutService

    init(service: CaptureShortcutService) {
        self.service = service
    }

    func start(_ action: CaptureAction) {
        cancel()
        message = nil
        recording = action
        service.suspend(action)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    func cancel() {
        guard let recording else { return }
        stopMonitoring()
        service.resume(recording)
    }

    func resetToDefault(_ action: CaptureAction) {
        cancel()
        apply(action.defaultShortcut, to: action)
    }

    private func handle(_ event: NSEvent) {
        let modifiers = Self.modifiers(of: event)
        if event.keyCode == 53, modifiers.isEmpty { // Esc cancels
            cancel()
            return
        }
        guard let action = recording else { return }
        let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: KeyLabel.label(for: event))
        guard shortcut.isUsableGlobally else {
            message = (action, "需要同时按住 ⌘、⌥ 或 ⌃（F1–F12 可以单独使用）")
            return
        }
        stopMonitoring()
        apply(shortcut, to: action)
    }

    private func apply(_ shortcut: Shortcut, to action: CaptureAction) {
        switch service.change(action, to: shortcut) {
        case nil: message = nil
        case .usedBy(let other): message = (action, "\(shortcut.displayString) 已经用于“\(other.title)”，请换一个")
        case .taken: message = (action, "\(shortcut.displayString) 已被其他应用占用，请换一个")
        }
    }

    private func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    private static func modifiers(of event: NSEvent) -> ShortcutModifiers {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: ShortcutModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}

/// What a key is called on screen.
enum KeyLabel {
    private static let special: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    static func label(for event: NSEvent) -> String {
        if let name = special[event.keyCode] { return name }
        // The key's own character, as if no modifier were held (so ⇧2 is "2", not "@").
        let character = event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        let printable = !character.isEmpty && character.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        return printable ? character : "Key \(event.keyCode)"
    }
}
