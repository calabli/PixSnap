import PixSnapCore

/// Owns the global shortcuts, one per capture mode: registers the saved ones, and lets Settings
/// record new ones.
@MainActor
final class CaptureShortcutService {
    /// Called after a shortcut changed, so the menu can show it.
    var onChange: (() -> Void)?

    private var hotKeys: [CaptureAction: HotKey] = [:]
    private let settings: AppSettings

    init(onPress: @escaping (CaptureAction) -> Void) {
        self.settings = .shared
        for action in CaptureAction.allCases {
            let hotKey = HotKey()
            hotKey.onPress = { onPress(action) }
            hotKeys[action] = hotKey
        }
    }

    func shortcut(for action: CaptureAction) -> Shortcut { settings.shortcut(for: action) }

    /// Registers the saved shortcuts. Returns the modes whose shortcut another app owns.
    func start() -> [CaptureAction] {
        CaptureAction.allCases.filter { !(hotKeys[$0]?.register(shortcut(for: $0)) ?? false) }
    }

    /// While recording, the old shortcut must not fire, or pressing it again couldn't be recorded.
    func suspend(_ action: CaptureAction) {
        hotKeys[action]?.unregister()
    }

    func resume(_ action: CaptureAction) {
        _ = hotKeys[action]?.register(shortcut(for: action))
    }

    enum ChangeError: Error {
        /// Another capture mode already uses it.
        case usedBy(CaptureAction)
        /// Another app owns it.
        case taken
    }

    /// Switches `action` to `shortcut` and saves it. When that can't be done, the old one is
    /// restored and the reason returned.
    func change(_ action: CaptureAction, to shortcut: Shortcut) -> ChangeError? {
        if let other = CaptureAction.allCases.first(where: { $0 != action && self.shortcut(for: $0) == shortcut }) {
            resume(action)
            return .usedBy(other)
        }
        guard hotKeys[action]?.register(shortcut) ?? false else {
            resume(action)
            return .taken
        }
        settings.shortcuts[action] = shortcut
        onChange?()
        return nil
    }
}
