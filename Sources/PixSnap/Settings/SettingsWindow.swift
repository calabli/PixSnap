import AppKit
import PixSnapCore
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Called after the notch toggle changes, so the handles can be shown or removed.
    var onNotchSettingChange: () -> Void = {}

    private let settings: AppSettings
    private let recorder: ShortcutRecorder
    private var window: NSWindow?

    init(shortcutService: CaptureShortcutService) {
        self.settings = .shared
        recorder = ShortcutRecorder(service: shortcutService)
    }

    func show() {
        settings.refreshLaunchAtLoginStatus()
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(
            settings: settings, recorder: recorder, onNotchSettingChange: { [weak self] in self?.onNotchSettingChange() }
        ))
        hosting.sizingOptions = [.preferredContentSize]
        let window = ClosableWindow(contentViewController: hosting)
        window.title = "PixSnap 设置"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Open on the current Space, even over a full-screen app, instead of switching to the desktop.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        return window
    }

    /// Recording stops when the window loses focus, so the old shortcut keeps working.
    func windowDidResignKey(_ notification: Notification) {
        recorder.cancel()
    }

    func windowWillClose(_ notification: Notification) {
        recorder.cancel()
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var recorder: ShortcutRecorder
    @State private var loginError: String?
    @State private var confirmingClear = false
    private let history = HistoryLibrary.shared
    /// Shows or hides the notch handles after the toggle changes.
    var onNotchSettingChange: () -> Void = {}

    /// "85 张 · 42.3 MB", or "85 张 · 收藏 4 张 · 洗衣篮 3 张 · 42.3 MB"
    private var historyUsage: String {
        _ = history.revision
        let size = ByteCountFormatter.string(fromByteCount: history.diskUsage(), countStyle: .file)
        var parts = ["\(history.count) 张"]
        let favorites = history.favoriteCount
        if favorites > 0 { parts.append("收藏 \(favorites) 张") }
        let basket = history.basket().count
        if basket > 0 { parts.append("洗衣篮 \(basket) 张") }
        return (parts + [size]).joined(separator: " · ")
    }

    var body: some View {
        Form {
            Section("快捷键") {
                LabeledContent("截取区域") {
                    HStack {
                        Button {
                            recorder.isRecording ? recorder.cancel() : recorder.start()
                        } label: {
                            Text(recorder.isRecording ? "请按下新的快捷键…" : settings.captureShortcut.displayString)
                                .frame(minWidth: 130)
                        }
                        .help(recorder.isRecording ? "按 Esc 取消" : "点击后按下新的快捷键")
                        Button("恢复默认") { recorder.resetToDefault() }
                            .disabled(settings.captureShortcut == .defaultCapture)
                    }
                }
                if let message = recorder.message {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
            }

            Section("截图") {
                Toggle("截图后自动复制到剪贴板", isOn: $settings.copiesAfterCapture)
                LabeledContent("保存位置") {
                    HStack {
                        Text((settings.saveFolder.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(settings.saveFolder.path)
                        Button("更改…", action: chooseSaveFolder)
                    }
                }
                HStack {
                    Spacer()
                    Button("在访达中打开", action: openSaveFolder)
                    Button("恢复默认") { settings.saveFolder = AppSettings.defaultSaveFolder }
                        .disabled(settings.saveFolder == AppSettings.defaultSaveFolder)
                }
            }

            Section("截图历史") {
                Toggle("保存截图历史", isOn: $settings.savesHistory)
                Toggle("从刘海往下拉打开晾衣架", isOn: $settings.pullsHistoryFromNotch)
                    .help("没有刘海的屏幕顶部中间会有一条小黑条，往下拉也能打开")
                    .onChange(of: settings.pullsHistoryFromNotch) { onNotchSettingChange() }
                Picker("保留时长", selection: $settings.historyRetentionDays) {
                    ForEach(AppSettings.historyRetentionChoices, id: \.self) { days in
                        Text(days.map { "\($0) 天" } ?? "永久").tag(days)
                    }
                }
                .onChange(of: settings.historyRetentionDays) { history.cleanUp() }
                LabeledContent("已保存", value: historyUsage)
                HStack {
                    Text("只保存在这台 Mac 上；收藏的截图不会被自动清理。扔进洗衣篮的截图 \(HistoryLibrary.basketDays) 天后删除。")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                HStack {
                    Spacer()
                    Button("在访达中显示") { NSWorkspace.shared.open(history.folder) }
                    Button("清空历史…", role: .destructive) { confirmingClear = true }
                        .disabled(history.count == 0)
                }
            }
            .confirmationDialog("清空全部截图历史？", isPresented: $confirmingClear) {
                Button("清空", role: .destructive) { history.removeAll() }
            } message: {
                Text("会删除 \(history.count) 张截图，包括收藏的，无法恢复。已经保存到“保存位置”的文件不受影响。")
            }

            RopeStyleSection(style: $settings.ropeStyle)

            Section("通用") {
                Toggle("登录时打开 PixSnap", isOn: Binding(
                    get: { settings.launchesAtLogin },
                    set: { enabled in
                        do {
                            try settings.setLaunchesAtLogin(enabled)
                            loginError = nil
                        } catch {
                            loginError = "无法更改：\(error.localizedDescription)"
                        }
                    }
                ))
                if settings.launchAtLoginStatus == .requiresApproval {
                    HStack {
                        Text("还需要在“系统设置 › 通用 › 登录项”里允许 PixSnap。")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("打开登录项") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError {
                    Text(loginError).font(.callout).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择截图保存的文件夹"
        panel.directoryURL = settings.saveFolder
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolder = url
        }
    }

    private func openSaveFolder() {
        try? FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.saveFolder)
    }
}
