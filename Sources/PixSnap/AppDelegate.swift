import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var captureMenuItem: NSMenuItem?
    private let coordinator = CaptureCoordinator()
    private lazy var captureShortcut = CaptureShortcutService { [weak self] in self?.coordinator.startCapture() }
    private lazy var settingsWindow = SettingsWindowController(shortcutService: captureShortcut)

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        captureShortcut.onChange = { [weak self] in self?.refreshCaptureMenuItem() }
        if !captureShortcut.start() {
            let alert = NSAlert()
            alert.messageText = "快捷键 \(captureShortcut.shortcut.displayString) 已被占用"
            alert.informativeText = "其他应用正在使用这个快捷键。你可以在“设置”里换一个，或者从菜单栏图标开始截图。"
            alert.addButton(withTitle: "打开设置")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn { settingsWindow.show() }
        }

        // `PixSnap --edit <image>` opens an image in the annotation editor; `--pin <image>` pins it on screen.
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--edit"), arguments.indices.contains(flag + 1) {
            coordinator.openEditor(forImageAt: URL(fileURLWithPath: arguments[flag + 1]))
        }
        if let flag = arguments.firstIndex(of: "--pin"), arguments.indices.contains(flag + 1) {
            coordinator.pinImage(at: URL(fileURLWithPath: arguments[flag + 1]))
        }
        if arguments.contains("--settings") { settingsWindow.show() }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "PixSnap")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let capture = NSMenuItem(title: "截取区域", action: #selector(captureFromMenu), keyEquivalent: "")
        menu.addItem(capture)
        captureMenuItem = capture
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "打开截图文件夹", action: #selector(openSaveFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "关于 PixSnap", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "退出 PixSnap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for menuItem in menu.items where menuItem.action != #selector(NSApplication.terminate(_:)) {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
        refreshCaptureMenuItem()
    }

    /// Shows the current shortcut next to the menu item: as a key equivalent when it's a single
    /// character, otherwise in the title (F-keys, Space and arrows can't be menu key equivalents here).
    private func refreshCaptureMenuItem() {
        guard let item = captureMenuItem else { return }
        let shortcut = captureShortcut.shortcut
        if shortcut.keyLabel.count == 1 {
            item.title = "截取区域"
            item.keyEquivalent = shortcut.keyLabel.lowercased()
            var mask: NSEvent.ModifierFlags = []
            if shortcut.modifiers.contains(.command) { mask.insert(.command) }
            if shortcut.modifiers.contains(.shift) { mask.insert(.shift) }
            if shortcut.modifiers.contains(.option) { mask.insert(.option) }
            if shortcut.modifiers.contains(.control) { mask.insert(.control) }
            item.keyEquivalentModifierMask = mask
        } else {
            item.title = "截取区域（\(shortcut.displayString)）"
            item.keyEquivalent = ""
        }
    }

    @objc private func captureFromMenu() {
        // Let the menu finish closing so it doesn't end up in the frozen screenshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [coordinator] in
            coordinator.startCapture()
        }
    }

    @objc private func openSaveFolder() {
        let folder = ImageExporter.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
