import Foundation

/// 智能美化: what a screenshot shows, guessed from its text, colors and source app, and the finish
/// that suits it — a background, room around it, rounded corners, a shadow and maybe a frame.
public enum ContentKind: String, CaseIterable, Sendable {
    case code, chat, document, photo, interface

    public var title: String {
        switch self {
        case .code: "代码"
        case .chat: "聊天"
        case .document: "文档"
        case .photo: "照片"
        case .interface: "界面"
        }
    }
}

/// A color with components from 0 to 1.
public struct RGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Perceived brightness, 0 (black) to 1 (white).
    public var luminance: Double { 0.299 * red + 0.587 * green + 0.114 * blue }

    /// Hue (0..<1), saturation and brightness.
    public var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maximum = max(red, green, blue), minimum = min(red, green, blue), delta = maximum - minimum
        guard delta > 0 else { return (0, 0, maximum) }
        var hue: Double
        if maximum == red {
            hue = (green - blue) / delta
        } else if maximum == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, delta / maximum, maximum)
    }

    public init(hue: Double, saturation: Double, brightness: Double) {
        let h = (hue - hue.rounded(.down)) * 6, s = min(max(saturation, 0), 1), v = min(max(brightness, 0), 1)
        let sector = Int(h) % 6, f = h - Double(Int(h))
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch sector {
        case 0: self.init(v, t, p)
        case 1: self.init(q, v, p)
        case 2: self.init(p, v, t)
        case 3: self.init(p, q, v)
        case 4: self.init(t, p, v)
        default: self.init(v, p, q)
        }
    }
}

/// What was measured in a screenshot.
public struct ContentSignals: Equatable, Sendable {
    /// Recognized lines of text, top to bottom.
    public var lines: [String]
    /// Where each line starts and ends across the image, 0 (left edge) to 1 (right edge).
    public var lineSpans: [ClosedRange<Double>]
    /// The share of the image the text covers, 0 to 1.
    public var textCoverage: Double
    /// Average brightness, 0 to 1.
    public var brightness: Double
    /// The share of neighboring pixels that are (nearly) the same color: high for app UI and
    /// text, low for photos.
    public var flatness: Double
    /// The share of pixels in the 8 most common colors: high for app UI and text (a few flat
    /// colors), low for photos and smooth artwork.
    public var concentration: Double
    /// The most telling color: the most common clearly saturated one, else the most common one.
    public var accent: RGB
    /// Width over height.
    public var aspectRatio: Double
    /// The app it was captured from, if known.
    public var sourceApp: String?

    public init(lines: [String], lineSpans: [ClosedRange<Double>] = [], textCoverage: Double, brightness: Double, flatness: Double,
                concentration: Double, accent: RGB, aspectRatio: Double, sourceApp: String? = nil) {
        self.lines = lines
        self.lineSpans = lineSpans
        self.textCoverage = textCoverage
        self.brightness = brightness
        self.flatness = flatness
        self.concentration = concentration
        self.accent = accent
        self.aspectRatio = aspectRatio
        self.sourceApp = sourceApp
    }

    public var isDark: Bool { brightness < 0.42 }

    /// The hue backgrounds are built around: the accent's, or a calm blue when the screenshot is
    /// all grays.
    public var hue: Double {
        let hsb = accent.hsb
        return hsb.saturation < 0.15 ? 0.6 : hsb.hue
    }
}

public enum ContentClassifier {
    /// The best guess, checked in order: photo, code, chat, document, else app interface.
    public static func classify(_ signals: ContentSignals) -> ContentKind {
        let app = signals.sourceApp?.lowercased() ?? ""
        if signals.textCoverage < 0.08, signals.flatness < 0.45 || signals.concentration < 0.6 { return .photo }
        if codeScore(signals.lines) >= 0.3, signals.lines.count >= 3 { return .code }
        if codeApps.contains(where: app.contains), signals.lines.count >= 3 { return .code }
        if chatApps.contains(where: app.contains) || looksLikeChat(signals) { return .chat }
        let words = signals.lines.reduce(0) { $0 + $1.count }
        if signals.lines.count >= 8, signals.textCoverage > 0.12, words >= 160 { return .document }
        return .interface
    }

    /// Short lines in bubbles on both sides: some hugging the left, some the right.
    public static func looksLikeChat(_ signals: ContentSignals) -> Bool {
        let spans = signals.lineSpans
        guard spans.count >= 3, signals.lines.count == spans.count else { return false }
        let left = spans.filter { $0.lowerBound < 0.3 && $0.upperBound < 0.7 }.count
        let right = spans.filter { $0.lowerBound > 0.3 && $0.upperBound > 0.7 }.count
        let averageLength = Double(signals.lines.reduce(0) { $0 + $1.count }) / Double(signals.lines.count)
        return left >= 1 && right >= 1 && left + right >= spans.count * 3 / 4 && averageLength < 30
    }

    /// The share of lines that look like code: brackets, operators, comments or a keyword first.
    public static func codeScore(_ lines: [String]) -> Double {
        // Line numbers and stray bits don't count.
        let meaningful = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.count >= 3 && !trimmed.allSatisfy(\.isNumber)
        }
        guard !meaningful.isEmpty else { return 0 }
        let looksLikeCode = meaningful.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let symbols = trimmed.filter { "{}();=<>[]".contains($0) }.count
            if symbols >= 2 || trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasSuffix(";") || trimmed.hasSuffix("{") { return true }
            let first = trimmed.split(separator: " ").first.map(String.init) ?? ""
            return codeKeywords.contains(first)
        }
        return Double(looksLikeCode.count) / Double(meaningful.count)
    }

    static let codeKeywords: Set<String> = [
        "func", "let", "var", "import", "return", "class", "struct", "enum", "if", "else", "for", "while", "guard",
        "def", "const", "function", "public", "private", "static", "package", "from", "async", "await", "fn", "pub",
        "int", "void", "export", "case", "switch", "self", "try", "catch", "SELECT", "$",
    ]
    static let codeApps = ["xcode", "terminal", "iterm", "code", "cursor", "zed", "intellij", "pycharm", "webstorm",
                           "android studio", "sublime", "nova", "ghostty", "warp", "终端"]
    static let chatApps = ["微信", "wechat", "qq", "messages", "信息", "telegram", "slack", "飞书", "lark", "钉钉",
                           "dingtalk", "whatsapp", "discord", "企业微信"]
}

/// The finish for a screenshot. Sizes are in points, scaled by the screenshot's pixels per point.
public struct BeautifyStyle: Equatable, Sendable {
    public enum Background: Equatable, Sendable {
        /// Top-left to bottom-right.
        case gradient(RGB, RGB)
        /// The screenshot itself, enlarged and blurred, under it.
        case blurredImage
    }

    public enum Shadow: Equatable, Sendable {
        case none, thin, soft, deep
    }

    public enum Frame: Equatable, Sendable {
        case none
        /// A macOS window title bar with the red, yellow and green buttons.
        case window(dark: Bool)
        /// A hairline around the screenshot.
        case border
    }

    public var name: String
    public var background: Background
    /// Room around the screenshot, as a share of its shorter side, within `paddingRange`.
    public var padding: Double
    public var cornerRadius: Double
    public var shadow: Shadow
    public var frame: Frame

    public init(name: String, background: Background, padding: Double, cornerRadius: Double, shadow: Shadow, frame: Frame) {
        self.name = name
        self.background = background
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.frame = frame
    }

    public static let paddingRange: ClosedRange<Double> = 28 ... 110

    /// The room around a screenshot `width` × `height` points.
    public func paddingPoints(width: Double, height: Double) -> Double {
        min(max(min(width, height) * padding, Self.paddingRange.lowerBound), Self.paddingRange.upperBound)
    }

    /// The style that suits `kind`, colored from the screenshot.
    public static func recommended(for kind: ContentKind, _ signals: ContentSignals) -> BeautifyStyle {
        let dark = signals.isDark
        let hue = signals.hue
        switch kind {
        case .code:
            return BeautifyStyle(name: "代码", background: vivid(hue: hue, dark: dark), padding: 0.12, cornerRadius: 12,
                                 shadow: .deep, frame: .window(dark: dark))
        case .chat:
            return BeautifyStyle(name: "聊天", background: pastel(hue: hue, dark: dark), padding: 0.1, cornerRadius: 18,
                                 shadow: .soft, frame: .none)
        case .document:
            return BeautifyStyle(name: "文档", background: paper(hue: hue, dark: dark), padding: 0.07, cornerRadius: 6,
                                 shadow: .thin, frame: .none)
        case .photo:
            return BeautifyStyle(name: "照片", background: .blurredImage, padding: 0.09, cornerRadius: 14,
                                 shadow: .deep, frame: .none)
        case .interface:
            return BeautifyStyle(name: "界面", background: pastel(hue: hue, dark: dark), padding: 0.1, cornerRadius: 12,
                                 shadow: .soft, frame: .none)
        }
    }

    /// The recommended style first, then the others that might do, each colored from the screenshot.
    public static func choices(for kind: ContentKind, _ signals: ContentSignals) -> [BeautifyStyle] {
        let dark = signals.isDark
        let hue = signals.hue
        var styles = [recommended(for: kind, signals)]
        styles += ContentKind.allCases.filter { $0 != kind }.map { recommended(for: $0, signals) }
        styles.append(BeautifyStyle(name: "简洁", background: .gradient(RGB(1, 1, 1), RGB(1, 1, 1)), padding: 0.06, cornerRadius: 8,
                                    shadow: .none, frame: .border))
        styles.append(BeautifyStyle(name: "对比色", background: vivid(hue: hue + 0.5, dark: dark), padding: 0.1, cornerRadius: 12,
                                    shadow: .soft, frame: .none))
        return styles
    }

    /// A rich gradient around `hue`: deep for dark screenshots, bright for light ones.
    static func vivid(hue: Double, dark: Bool) -> Background {
        dark
            ? .gradient(RGB(hue: hue, saturation: 0.65, brightness: 0.5), RGB(hue: hue + 0.12, saturation: 0.75, brightness: 0.22))
            : .gradient(RGB(hue: hue - 0.04, saturation: 0.45, brightness: 1), RGB(hue: hue + 0.1, saturation: 0.6, brightness: 0.85))
    }

    /// A soft gradient around `hue`.
    static func pastel(hue: Double, dark: Bool) -> Background {
        dark
            ? .gradient(RGB(hue: hue, saturation: 0.35, brightness: 0.32), RGB(hue: hue + 0.08, saturation: 0.45, brightness: 0.16))
            : .gradient(RGB(hue: hue, saturation: 0.18, brightness: 0.99), RGB(hue: hue + 0.08, saturation: 0.3, brightness: 0.93))
    }

    /// Nearly plain, like paper: a whisper of `hue`.
    static func paper(hue: Double, dark: Bool) -> Background {
        dark
            ? .gradient(RGB(hue: hue, saturation: 0.08, brightness: 0.2), RGB(hue: hue, saturation: 0.1, brightness: 0.14))
            : .gradient(RGB(hue: hue, saturation: 0.03, brightness: 0.97), RGB(hue: hue, saturation: 0.05, brightness: 0.92))
    }
}
