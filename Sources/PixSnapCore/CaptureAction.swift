import Foundation

/// The ways to take a screenshot, each with its own global shortcut.
public enum CaptureAction: String, Codable, CaseIterable, Sendable {
    /// Select a region (or click a window) on the frozen screen.
    case region
    /// The whole screen under the cursor, at once.
    case fullScreen
    /// A region that's scrolled and stitched into a long image.
    case scrolling
    /// A countdown first, then select a region.
    case delayed
    /// The window under the cursor, by itself.
    case window
    /// A screen recording of a region, kept as MP4 or GIF.
    case recording

    public var title: String {
        switch self {
        case .region: "截取区域"
        case .fullScreen: "全屏截图"
        case .scrolling: "长截图"
        case .delayed: "延时截图"
        case .window: "截取窗口"
        case .recording: "录屏"
        }
    }

    /// ⌘⇧2 for the everyday one; the others on ⌥⇧ and a number, away from the system's ⌘⇧3/4/5.
    /// 18–21 and 23 are the "1"–"5" keys on macOS.
    public var defaultShortcut: Shortcut {
        switch self {
        case .region: .defaultCapture
        case .fullScreen: Shortcut(keyCode: 18, modifiers: [.option, .shift], keyLabel: "1")
        case .scrolling: Shortcut(keyCode: 19, modifiers: [.option, .shift], keyLabel: "2")
        case .delayed: Shortcut(keyCode: 20, modifiers: [.option, .shift], keyLabel: "3")
        case .window: Shortcut(keyCode: 21, modifiers: [.option, .shift], keyLabel: "4")
        case .recording: Shortcut(keyCode: 23, modifiers: [.option, .shift], keyLabel: "5")
        }
    }
}

/// How a captured window is finished: with its shadow or without, on a background or not.
public struct WindowCaptureStyle: Codable, Equatable, Sendable {
    public enum Background: String, Codable, CaseIterable, Sendable {
        /// Just the window, on transparency.
        case none
        case sunrise, ocean, mint, lavender, graphite
        case white

        public var title: String {
            switch self {
            case .none: "无（透明）"
            case .sunrise: "晨曦"
            case .ocean: "海洋"
            case .mint: "薄荷"
            case .lavender: "薰衣草"
            case .graphite: "石墨"
            case .white: "白色"
            }
        }
    }

    public var keepsShadow: Bool
    public var background: Background

    public init(keepsShadow: Bool, background: Background) {
        self.keepsShadow = keepsShadow
        self.background = background
    }

    public static let `default` = WindowCaptureStyle(keepsShadow: true, background: .none)

    /// Unknown or damaged fields fall back to the default instead of failing the whole style.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keepsShadow = (try? container.decode(Bool.self, forKey: .keepsShadow)) ?? Self.default.keepsShadow
        background = (try? container.decode(Background.self, forKey: .background)) ?? Self.default.background
    }

    private enum CodingKeys: String, CodingKey {
        case keepsShadow, background
    }
}
