/// Modifier keys of a shortcut, independent of any platform's event types.
public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let shift = ShortcutModifiers(rawValue: 1 << 2)
    public static let command = ShortcutModifiers(rawValue: 1 << 3)
}

/// A global keyboard shortcut. `keyCode` is the platform's virtual key code; `keyLabel` is what
/// the key shows to people ("2", "A", "F1", "Space"), captured when the shortcut was recorded.
public struct Shortcut: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: ShortcutModifiers
    public var keyLabel: String

    public init(keyCode: UInt32, modifiers: ShortcutModifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// ⌘⇧2 — 19 is the "2" key on macOS.
    public static let defaultCapture = Shortcut(keyCode: 19, modifiers: [.command, .shift], keyLabel: "2")

    /// Symbols in the conventional macOS order: ⌃⌥⇧⌘, then the key.
    public var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + keyLabel
    }

    public var isFunctionKey: Bool {
        guard keyLabel.first == "F", let number = Int(keyLabel.dropFirst()) else { return false }
        return (1...20).contains(number)
    }

    /// A global shortcut needs ⌘, ⌥ or ⌃ so it doesn't swallow ordinary typing (Shift alone only
    /// changes case). Function keys are fine on their own.
    public var isUsableGlobally: Bool {
        isFunctionKey || !modifiers.intersection([.command, .option, .control]).isEmpty
    }
}
