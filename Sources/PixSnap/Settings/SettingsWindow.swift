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

    private var microphoneAvailable: Bool {
        if #available(macOS 15, *) { true } else { false }
    }

    var body: some View {
        Form {
            Section("快捷键") {
                ForEach(CaptureAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        HStack {
                            Button {
                                recorder.recording == action ? recorder.cancel() : recorder.start(action)
                            } label: {
                                Text(recorder.recording == action ? "请按下新的快捷键…" : settings.shortcut(for: action).displayString)
                                    .frame(minWidth: 130)
                            }
                            .help(recorder.recording == action ? "按 Esc 取消" : "点击后按下新的快捷键")
                            Button("恢复默认") { recorder.resetToDefault(action) }
                                .disabled(settings.shortcut(for: action) == action.defaultShortcut)
                        }
                    }
                    if let message = recorder.message, message.action == action {
                        Text(message.text).font(.callout).foregroundStyle(.red)
                    }
                }
            }

            Section("截图") {
                Toggle("截图后自动复制到剪贴板", isOn: $settings.copiesAfterCapture)
                Picker("延时截图倒计时", selection: $settings.captureDelay) {
                    ForEach(AppSettings.captureDelayChoices, id: \.self) { Text("\($0) 秒").tag($0) }
                }
                Toggle("点“保存”时选择保存位置", isOn: $settings.asksWhereToSave)
                    .help("关闭后，点“保存”直接存进下面的文件夹")
                LabeledContent(settings.asksWhereToSave ? "默认位置" : "保存位置") {
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
                Toggle("识别截图里的文字，用于搜索", isOn: $settings.recognizesText)
                    .help("在这台 Mac 上用系统的文字识别（中文和英文），不会上传")
                    .onChange(of: settings.recognizesText) { if settings.recognizesText { history.recognizeMissingText() } }
                Toggle("从刘海往下拉打开晾衣架", isOn: $settings.pullsHistoryFromNotch)
                    .help("没有刘海的屏幕顶部中间会有一条小黑条，往下拉也能打开")
                    .onChange(of: settings.pullsHistoryFromNotch) { onNotchSettingChange() }
                Picker("把手大小", selection: $settings.notchHandleSize) {
                    ForEach(NotchHandleSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("刘海处可以抓的宽度；没有刘海的屏幕上小黑条也跟着变大变小")
                .disabled(!settings.pullsHistoryFromNotch)
                .onChange(of: settings.notchHandleSize) { onNotchSettingChange() }
                Toggle("隐藏把手，鼠标移上去才显示", isOn: $settings.hidesNotchHandle)
                    .help("平时看不见，但还在原处，鼠标移到屏幕顶部中间就会出现，照样可以往下拉")
                    .disabled(!settings.pullsHistoryFromNotch)
                    .onChange(of: settings.hidesNotchHandle) { onNotchSettingChange() }
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

            Section("录屏") {
                Picker("帧率", selection: $settings.recordingFPS) {
                    ForEach(AppSettings.recordingFPSChoices, id: \.self) { Text("\($0) 帧/秒").tag($0) }
                }
                Toggle("录制鼠标指针", isOn: $settings.recordsCursor)
                Toggle("高亮鼠标点击", isOn: $settings.highlightsClicks)
                    .help("点击的地方出现一圈涟漪，录进视频里")
                Toggle("显示按键", isOn: $settings.showsKeystrokes)
                    .help("按下的快捷键（如 ⌘C）和回车、方向键等显示在区域底部；普通打字不显示。需要在“辅助功能”里允许 PixSnap")
                    .onChange(of: settings.showsKeystrokes) { if settings.showsKeystrokes { PermissionGuide.ensureAccessibility() } }
                Toggle("录制系统声音", isOn: $settings.recordsSystemAudio)
                    .help("Mac 播放的声音（视频、提示音等），不含 PixSnap 自己的声音")
                Toggle("录制麦克风", isOn: $settings.recordsMicrophone)
                    .help(microphoneAvailable ? "第一次录制时 macOS 会询问是否允许 PixSnap 使用麦克风" : "需要 macOS 15 或更新版本")
                    .disabled(!microphoneAvailable)
                HStack {
                    Text("先框选区域或单击一个窗口，然后开始录制；录制中可以暂停，点“停止”或再按一次录屏快捷键结束。录完可以剪掉头尾，存成 MP4 或 GIF。")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
            }

            Section("窗口截图") {
                Toggle("保留窗口阴影", isOn: $settings.windowCaptureStyle.keepsShadow)
                Picker("背景", selection: $settings.windowCaptureStyle.background) {
                    ForEach(WindowCaptureStyle.Background.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                HStack {
                    Text("单击选区里高亮的窗口，或按“截取窗口”的快捷键截取鼠标下的窗口；只截这个窗口，不会带上挡在前面的其他窗口。")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
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
        // Taller than most screens now, so it scrolls.
        .frame(width: 500, height: 720)
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
