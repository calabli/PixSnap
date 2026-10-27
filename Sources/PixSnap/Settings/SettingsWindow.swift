import AppKit
import PixSnapCore
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
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
        let hosting = NSHostingController(rootView: SettingsView(settings: settings, recorder: recorder))
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
