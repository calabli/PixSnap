import AppKit

@MainActor
enum PermissionGuide {
    /// Returns true when PixSnap may record the screen. Otherwise triggers the system prompt
    /// (shown only once by macOS) and explains how to grant access in System Settings.
    static func ensureScreenCapture() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        showScreenCaptureAlert()
        return false
    }

    static func showScreenCaptureAlert() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "PixSnap 需要“屏幕录制”权限"
        alert.informativeText = "请在“系统设置 › 隐私与安全性 › 屏幕与系统录音”中打开 PixSnap，然后重新打开 PixSnap。截图只保存在你的电脑上。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
