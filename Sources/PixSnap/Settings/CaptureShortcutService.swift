import PixSnapCore

/// Owns the global capture shortcut: registers the saved one, and lets Settings record a new one.
@MainActor
final class CaptureShortcutService {
    /// Called after the shortcut changed, so the menu can show it.
    var onChange: (() -> Void)?

    private let hotKey = HotKey()
    private let settings: AppSettings

    init(onPress: @escaping () -> Void) {
        self.settings = .shared
        hotKey.onPress = onPress
    }

    var shortcut: Shortcut { settings.captureShortcut }

    /// Registers the saved shortcut. Returns false when another app owns it.
    func start() -> Bool {
        hotKey.register(settings.captureShortcut)
    }

    /// While recording, the old shortcut must not fire, or pressing it again couldn't be recorded.
    func suspend() {
        hotKey.unregister()
    }

    func resume() {
        _ = hotKey.register(settings.captureShortcut)
    }

    /// Switches to `shortcut` and saves it. When it can't be registered, the old one is restored
    /// and false is returned.
    func change(to shortcut: Shortcut) -> Bool {
        guard hotKey.register(shortcut) else {
            resume()
            return false
        }
        settings.captureShortcut = shortcut
        onChange?()
        return true
    }
}
