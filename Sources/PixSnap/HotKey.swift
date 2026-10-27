import Carbon.HIToolbox
import Foundation
import PixSnapCore

/// A system-wide keyboard shortcut registered through Carbon's RegisterEventHotKey,
/// which works without the Accessibility permission.
@MainActor
final class HotKey {
    var onPress: (() -> Void)?
    private(set) var shortcut: Shortcut?

    private let id: UInt32
    private var reference: EventHotKeyRef?

    private static var registered: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    init() {
        self.id = HotKey.nextID
        HotKey.nextID += 1
    }

    /// Replaces the current shortcut. Returns false (and leaves nothing registered) when another
    /// app already owns `shortcut`.
    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        HotKey.installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x5058_5350), id: id) // "PXSP"
        let status = RegisterEventHotKey(
            shortcut.keyCode, Self.carbonModifiers(shortcut.modifiers), hotKeyID, GetApplicationEventTarget(), 0, &reference
        )
        guard status == noErr else {
            reference = nil
            return false
        }
        self.shortcut = shortcut
        HotKey.registered[id] = self
        return true
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        shortcut = nil
        HotKey.registered[id] = nil
    }

    private static func carbonModifiers(_ modifiers: ShortcutModifiers) -> UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        return UInt32(flags)
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            let pressedID = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKey.registered[pressedID]?.onPress?() }
            }
            return noErr
        }, 1, &eventType, nil, nil)
        handlerInstalled = true
    }
}
