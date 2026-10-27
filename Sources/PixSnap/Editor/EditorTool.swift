import Foundation

enum EditorTool: Int, CaseIterable {
    case select, rectangle, arrow, text, counter, mosaic, crop

    var title: String {
        switch self {
        case .select: "选择"
        case .rectangle: "矩形"
        case .arrow: "箭头"
        case .text: "文字"
        case .counter: "序号"
        case .mosaic: "马赛克"
        case .crop: "裁剪"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .rectangle: "rectangle"
        case .arrow: "arrow.up.right"
        case .text: "character.cursor.ibeam"
        case .counter: "1.circle"
        case .mosaic: "checkerboard.rectangle"
        case .crop: "crop"
        }
    }

    /// Single-key shortcut, typed without modifiers.
    var key: String {
        switch self {
        case .select: "v"
        case .rectangle: "r"
        case .arrow: "a"
        case .text: "t"
        case .counter: "n"
        case .mosaic: "m"
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
