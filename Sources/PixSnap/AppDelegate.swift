import AppKit
import PixSnapCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let recentMenu = NSMenu()
    private var recentEntries: [UUID: HistoryEntry] = [:]
    private let coordinator = CaptureCoordinator()
    private lazy var captureShortcut = CaptureShortcutService { [weak self] action in self?.start(action) }
    private lazy var settingsWindow = SettingsWindowController(shortcutService: captureShortcut)
    private var benchmark: CaptureBenchmark?
    /// The menu items for each capture mode, to show their shortcuts.
    private var captureMenuItems: [CaptureAction: NSMenuItem] = [:]
    private lazy var notch = NotchController { [weak self] entry in self?.coordinator.pinHistoryEntry(entry) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        Task { await ScreenCapturer.shared.warmUp() }
        HistoryLibrary.shared.cleanUp()
        ImageExporter.removeOldTemporaryFiles()
        notch.rebuild()
        settingsWindow.onNotchSettingChange = { [weak self] in self?.notch.rebuild() }

        captureShortcut.onChange = { [weak self] in self?.refreshCaptureMenuItems() }
        let taken = captureShortcut.start()
        if !taken.isEmpty {
            let alert = NSAlert()
            alert.messageText = "快捷键 " + taken.map { "\(captureShortcut.shortcut(for: $0).displayString)（\($0.title)）" }.joined(separator: "、") + " 已被占用"
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
            coordinator.pinImage(at: URL(fileURLWithPath: arguments[flag + 1]), pinned: arguments.contains("--pinned"))
        }
        if arguments.contains("--settings") { settingsWindow.show() }
        // `--capture region|fullScreen|scrolling|delayed|window` starts that capture, as its shortcut would.
        if let flag = arguments.firstIndex(of: "--capture"), arguments.indices.contains(flag + 1),
           let action = CaptureAction(rawValue: arguments[flag + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.start(action) }
        }
        // `--clothesline` opens the clothesline; add `--preview` to also preview the newest photo,
        // `--basket` to open the laundry basket, or `--throw` to throw the newest photo into it.
        if arguments.contains("--clothesline") {
            notch.openOnScreenUnderMouse(previewingNewest: arguments.contains("--preview"), openingBasket: arguments.contains("--basket"),
                                         throwingNewest: arguments.contains("--throw"))
        }
        if let flag = arguments.firstIndex(of: "--history-add"), arguments.indices.contains(flag + 1) {
            coordinator.addToHistory(imageAt: URL(fileURLWithPath: arguments[flag + 1]))
        }
        // `--scroll-capture x,y,w,h seconds output.png`: a long screenshot of that region (global
        // AppKit coordinates), finished after `seconds` and written to `output.png`.
        if let flag = arguments.firstIndex(of: "--scroll-capture"), arguments.indices.contains(flag + 3) {
            let numbers = arguments[flag + 1].split(separator: ",").compactMap { Double($0) }
            if numbers.count == 4 {
                coordinator.startScrollingCapture(in: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]),
                                                  finishingAfter: Double(arguments[flag + 2]) ?? 5,
                                                  writingTo: URL(fileURLWithPath: arguments[flag + 3]))
            }
        }
        if let flag = arguments.firstIndex(of: "--overlay"), arguments.indices.contains(flag + 1) {
            coordinator.showOverlay(forImageAt: URL(fileURLWithPath: arguments[flag + 1]))
        }
        if let flag = arguments.firstIndex(of: "--benchmark-capture") {
            let runs = arguments.indices.contains(flag + 1) ? Int(arguments[flag + 1]) ?? 10 : 10
            let output = arguments.firstIndex(of: "--benchmark-output")
                .flatMap { arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("pixsnap-benchmark.txt")
            benchmark = CaptureBenchmark(coordinator: coordinator, runs: runs, outputURL: output)
            benchmark?.start()
        }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "PixSnap")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        for action in CaptureAction.allCases {
            let item = NSMenuItem(title: action.title, action: #selector(captureFromMenu(_:)), keyEquivalent: "")
            item.representedObject = action.rawValue
            menu.addItem(item)
            captureMenuItems[action] = item
        }
        let recent = NSMenuItem(title: "最近截图", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recent.submenu = recentMenu
        menu.addItem(recent)
        menu.addItem(NSMenuItem(title: "打开晾衣架", action: #selector(openClothesline), keyEquivalent: ""))
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
        refreshCaptureMenuItems()
    }

    /// Shows each mode's shortcut next to its menu item: as a key equivalent when it's a single
    /// character, otherwise in the title (F-keys, Space and arrows can't be menu key equivalents here).
    private func refreshCaptureMenuItems() {
        for (action, item) in captureMenuItems {
            let shortcut = captureShortcut.shortcut(for: action)
            if shortcut.keyLabel.count == 1 {
                item.title = action.title
                item.keyEquivalent = shortcut.keyLabel.lowercased()
                var mask: NSEvent.ModifierFlags = []
                if shortcut.modifiers.contains(.command) { mask.insert(.command) }
                if shortcut.modifiers.contains(.shift) { mask.insert(.shift) }
                if shortcut.modifiers.contains(.option) { mask.insert(.option) }
                if shortcut.modifiers.contains(.control) { mask.insert(.control) }
                item.keyEquivalentModifierMask = mask
            } else {
                item.title = "\(action.title)（\(shortcut.displayString)）"
                item.keyEquivalent = ""
            }
        }
    }

    private func start(_ action: CaptureAction) {
        switch action {
        case .region: coordinator.startCapture()
        case .fullScreen: coordinator.startFullScreenCapture()
        case .scrolling: coordinator.startScrollingCapture()
        case .delayed: coordinator.startDelayedCapture()
        case .window: coordinator.startWindowCapture()
        }
    }

    // MARK: Recent captures

    private static let recentDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true // "今天 14:32"
        return formatter
    }()

    /// Rebuilt every time the submenu opens, so it's always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let library = HistoryLibrary.shared
        let entries = library.recent(limit: 8)
        recentEntries = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

        guard !entries.isEmpty else {
            let empty = NSMenuItem(title: AppSettings.shared.savesHistory ? "还没有截图" : "截图历史已在设置中关闭", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for entry in entries {
            var title = (entry.isFavorite ? "★ " : "") + Self.recentDateFormatter.string(from: entry.createdAt)
            if let app = entry.sourceAppName { title += " · \(app)" }
            let item = NSMenuItem(title: title, action: #selector(pinRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            item.toolTip = "\(entry.pixelWidth) × \(entry.pixelHeight)，点击浮动到屏幕上"
            if let thumbnail = library.thumbnail(for: entry) {
                // Fit within 64 × 40 points, keeping the aspect ratio.
                let fit = min(64 / max(thumbnail.size.width, 1), 40 / max(thumbnail.size.height, 1))
                thumbnail.size = CGSize(width: (thumbnail.size.width * fit).rounded(), height: (thumbnail.size.height * fit).rounded())
                item.image = thumbnail
            }
            menu.addItem(item)
        }
    }

    @objc private func openClothesline() {
        // Let the menu close first, or its click would count as a click outside the panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.notch.openOnScreenUnderMouse() }
    }

    @objc private func pinRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let entry = recentEntries[id] else { return }
        coordinator.pinHistoryEntry(entry)
    }

    @objc private func captureFromMenu(_ item: NSMenuItem) {
        guard let action = (item.representedObject as? String).flatMap(CaptureAction.init(rawValue:)) else { return }
        // Let the menu finish closing so it doesn't end up in the screenshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.start(action) }
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
