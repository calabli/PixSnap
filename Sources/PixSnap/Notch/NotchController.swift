import AppKit
import PixSnapCore

/// One pull-down handle per screen: over the notch where there is one, a small bar at the top
/// center elsewhere. Rebuilt when displays change or the setting is toggled.
@MainActor
final class NotchController {
    private let onPick: (HistoryEntry) -> Void
    private var windows: [NotchWindow] = []
    private var screenObserver: NSObjectProtocol?

    init(onPick: @escaping (HistoryEntry) -> Void) {
        self.onPick = onPick
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    /// Shows the handles when the setting is on, removes them when it's off.
    func rebuild() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        let settings = AppSettings.shared
        guard settings.pullsHistoryFromNotch else { return }

        for screen in NSScreen.screens {
            let notch = NotchGeometry.notchRect(
                screenFrame: screen.frame,
                topLeftArea: screen.auxiliaryTopLeftArea,
                topRightArea: screen.auxiliaryTopRightArea,
                safeAreaTop: screen.safeAreaInsets.top
            )
            let handle = NotchGeometry.handleRect(notch ?? NotchGeometry.standInRect(screenFrame: screen.frame),
                                                  size: settings.notchHandleSize, isNotch: notch != nil)
            let window = NotchWindow(handle: handle, screenFrame: screen.frame, menuBarHeight: Self.menuBarHeight(on: screen))
            window.hidesHandle = settings.hidesNotchHandle
            window.loadDays = { Self.days(matching: $0) }
            window.onPick = { [weak self] entry in self?.onPick(entry) }
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    /// Opens the clothesline on the screen under the cursor, without a gesture.
    func openOnScreenUnderMouse(previewingNewest: Bool = false, openingBasket: Bool = false, throwingNewest: Bool = false,
                                searching: String? = nil, olderBy ropes: Int = 0) {
        let mouse = NSEvent.mouseLocation
        let screenWindow = windows.first { ScreenGeometry.screen($0.screenFrame, containsMouse: mouse) } ?? windows.first
        if let screenWindow {
            screenWindow.openNow()
            if previewingNewest { screenWindow.previewNewest() }
            if openingBasket { screenWindow.openBasket() }
            if throwingNewest { screenWindow.throwNewest() }
            if let searching { screenWindow.searchNow(searching) }
            if ropes > 0 { screenWindow.pageNow(by: ropes) }
        } else {
            // The handles are turned off: open a temporary one on this screen.
            guard let screen = NSScreen.screens.first(where: { ScreenGeometry.screen($0.frame, containsMouse: mouse) }) ?? NSScreen.main else { return }
            let window = NotchWindow(handle: NotchGeometry.standInRect(screenFrame: screen.frame, height: 1),
                                     screenFrame: screen.frame, menuBarHeight: Self.menuBarHeight(on: screen))
            window.loadDays = { Self.days(matching: $0) }
            window.onPick = { [weak self] entry in self?.onPick(entry) }
            window.orderFrontRegardless()
            windows.append(window)
            window.openNow()
        }
    }

    /// 0 on screens that don't show the menu bar.
    private static func menuBarHeight(on screen: NSScreen) -> CGFloat {
        max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// The days to hang: every capture, or with `query`, the ones whose text or app matches. `found` counts every match.
    private static func days(matching query: String) -> NotchWindow.Lines {
        let settings = AppSettings.shared
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        // All of history, a scroll at a time.
        let entries = searching ? HistoryLibrary.shared.search(query, limit: 3000) : HistoryLibrary.shared.recent(limit: 3000)
        let days = HistoryGrouping.days(entries, now: Date(), limit: .max)
        let empty: String
        if searching {
            empty = settings.recognizesText ? "没有找到包含“\(query)”的截图。" : "没有找到。截图文字识别已在设置中关闭，只能按应用名搜索。"
        } else {
            empty = settings.savesHistory
                ? "还没有截图。按 \(settings.captureShortcut.displayString) 截一张，它就会挂在这里。"
                : "截图历史已在设置中关闭。"
        }
        return NotchWindow.Lines(days: days, emptyMessage: empty, found: searching ? entries.count : nil)
    }
}
