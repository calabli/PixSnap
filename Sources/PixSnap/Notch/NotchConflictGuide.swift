import AppKit
import PixSnapCore

/// When another notch app (NotchNook and the like, see `NotchConflict`) is running while
/// "从刘海往下拉打开晾衣架" is on, says that both answer the mouse at the notch, and offers to turn the
/// pull-down off (the clothesline still opens from the menu) or to keep both. Asked once per app:
/// a few seconds after launch, and when one of them starts later.
@MainActor
final class NotchConflictGuide {
    /// The pull-down was turned off here; the handles need rebuilding.
    var onTurnedOff: (() -> Void)?

    private var observer: NSObjectProtocol?
    private var isAsking = false
    private static let keptKey = "notchConflictKeptApps"

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.check() }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Give it a moment to put itself in the notch first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { self?.check() } }
        }
    }

    /// The notch apps running now (and `--pretend-notch-app <name>`, for testing).
    static var running: [String] {
        var apps = NSWorkspace.shared.runningApplications.map { (bundleID: $0.bundleIdentifier, name: $0.localizedName) }
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--pretend-notch-app"), arguments.indices.contains(flag + 1) {
            apps.append((bundleID: nil, name: arguments[flag + 1]))
        }
        return NotchConflict.conflicting(in: apps)
    }

    private func check() {
        guard AppSettings.shared.pullsHistoryFromNotch, !isAsking else { return }
        let kept = Set(UserDefaults.standard.stringArray(forKey: Self.keptKey) ?? [])
        let apps = Self.running.filter { !kept.contains($0) }
        guard !apps.isEmpty else { return }
        isAsking = true
        defer { isAsking = false }

        let names = apps.joined(separator: "、")
        let alert = NSAlert()
        alert.messageText = "\(names) 也在用刘海"
        alert.informativeText = """
        鼠标移到刘海、往下拉的时候，\(names) 和 PixSnap 的晾衣架都会做出反应，可能会互相挡住。

        可以关掉 PixSnap 的“从刘海往下拉”，晾衣架改从菜单栏 › 打开晾衣架打开；也可以两个都留着。设置 › 截图历史里随时能改。
        """
        if let icon = NSWorkspace.shared.runningApplications.first(where: { apps.contains($0.localizedName ?? "") })?.icon {
            alert.icon = icon
        }
        alert.addButton(withTitle: "关掉刘海下拉")
        alert.addButton(withTitle: "两个都留着")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            AppSettings.shared.pullsHistoryFromNotch = false
            onTurnedOff?()
        } else {
            UserDefaults.standard.set(Array(kept.union(apps)), forKey: Self.keptKey)
        }
    }
}
