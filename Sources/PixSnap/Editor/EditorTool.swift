import Foundation

enum EditorTool: Int, CaseIterable {
    case select, rectangle, ellipse, arrow, line, pen, highlight, text, counter, mosaic, blur, magnifier, crop

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
