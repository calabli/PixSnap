import Foundation

/// The keys shown on screen while recording ("显示按键"): shortcuts and the special keys, the way
/// macOS menus write them. Plain typing isn't shown, so what's typed (a password, a message)
/// doesn't end up in the video.
public enum Keystroke {
    /// "⌘⇧4", "⌥←", "↩"; nil for a key that's just typing.
    public static func label(keyCode: UInt16, modifiers: ShortcutModifiers, characters: String?) -> String? {
        let special = specialKeys[keyCode]
        let isShortcut = !modifiers.intersection([.command, .control, .option]).isEmpty
        guard isShortcut || special != nil else { return nil }
        let key = special ?? characters.map { $0.uppercased() }.flatMap { $0.isEmpty ? nil : $0 }
        guard let key else { return nil }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key
    }

    /// A label as a caption a newcomer can read: "⌘ Command + ⇧ Shift + 4", "↩ Return".
    public static func spelledOut(_ label: String) -> String {
        let names: [Character: String] = ["⌃": "⌃ Control", "⌥": "⌥ Option", "⇧": "⇧ Shift", "⌘": "⌘ Command"]
        let keyNames: [String: String] = ["↩": "↩ Return", "⌤": "⌤ Enter", "⇥": "⇥ Tab", "⌫": "⌫ Delete", "⌦": "⌦ Forward Delete",
                                          "esc": "Esc", "空格": "Space"]
        var parts: [String] = []
        var rest = Substring(label)
        while let first = rest.first, let name = names[first] {
            parts.append(name)
            rest = rest.dropFirst()
        }
        let key = String(rest)
        parts.append(keyNames[key] ?? key)
        return parts.joined(separator: " + ")
    }

    private static let specialKeys: [UInt16: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 49: "空格", 51: "⌫", 117: "⌦", 53: "esc",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}
