import Foundation
import PixSnapCore

enum EditorTool: Int, CaseIterable {
    case select, rectangle, ellipse, arrow, line, pen, highlight, text, counter, mosaic, blur, magnifier, ruler, crop

    var title: String {
        switch self {
        case .select: "选择"
        case .rectangle: "矩形"
        case .ellipse: "椭圆"
        case .arrow: "箭头"
        case .line: "直线"
        case .pen: "画笔"
        case .highlight: "荧光笔"
        case .text: "文字"
        case .counter: "序号"
        case .mosaic: "马赛克"
        case .blur: "模糊"
        case .magnifier: "放大镜"
        case .ruler: "量尺"
        case .crop: "裁剪"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .pen: "pencil.tip"
        case .highlight: "highlighter"
        case .text: "character.cursor.ibeam"
        case .counter: "1.circle"
        case .mosaic: "checkerboard.rectangle"
        case .blur: "drop.halffull"
        case .magnifier: "magnifyingglass.circle"
        case .ruler: "ruler"
        case .crop: "crop"
        }
    }

    /// Single-key shortcut, typed without modifiers.
    var key: String {
        switch self {
        case .select: "v"
        case .rectangle: "r"
        case .ellipse: "o"
        case .arrow: "a"
        case .line: "l"
        case .pen: "p"
        case .highlight: "h"
        case .text: "t"
        case .counter: "n"
        case .mosaic: "m"
        case .blur: "b"
        case .magnifier: "g"
        case .ruler: "u"
        case .crop: "c"
        }
    }
}

enum StrokeWidth: Int, CaseIterable {
    case thin, medium, thick

    var title: String {
        switch self {
        case .thin: "细"
        case .medium: "中"
        case .thick: "粗"
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .thin: 2
        case .medium: 4
        case .thick: 6
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .thin: 16
        case .medium: 22
        case .thick: 30
        }
    }
}

/// What each tool was last drawn with, so going back to a tool brings back its color and width
/// (red arrows and yellow highlighter, say). Arrow style and font are one each, for all arrows
/// and all text. Kept in UserDefaults; shared by the editor and floating captures.
@MainActor
enum ToolStyles {
    struct Style: Codable {
        var color: AnnotationColor
        var width: Int
    }

    private static let key = "toolStyles"
    private static let arrowKey = "arrowStyle"
    private static let fontKey = "textFont"

    static func style(for tool: EditorTool) -> (color: AnnotationColor, width: StrokeWidth) {
        let stored = all[String(describing: tool)]
        return (stored?.color ?? defaultColor(for: tool), stored.flatMap { StrokeWidth(rawValue: $0.width) } ?? .medium)
    }

    static func save(color: AnnotationColor, width: StrokeWidth, for tool: EditorTool) {
        guard tool != .select, tool != .crop else { return }
        var styles = all
        styles[String(describing: tool)] = Style(color: color, width: width.rawValue)
        if let data = try? JSONEncoder().encode(styles) { UserDefaults.standard.set(data, forKey: key) }
    }

    static var arrowStyle: ArrowStyle {
        get { UserDefaults.standard.string(forKey: arrowKey).flatMap(ArrowStyle.init(rawValue:)) ?? .filled }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: arrowKey) }
    }

    static var font: TextFont {
        get { UserDefaults.standard.string(forKey: fontKey).flatMap(TextFont.init(rawValue:)) ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: fontKey) }
    }

    private static var all: [String: Style] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Style].self, from: $0) } ?? [:]
    }

    /// Before a tool's been used: yellow for the marker, red for the rest.
    private static func defaultColor(for tool: EditorTool) -> AnnotationColor {
        tool == .highlight ? .yellow : .red
    }
}
