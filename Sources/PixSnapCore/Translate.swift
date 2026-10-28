import Foundation

/// 截图翻译: recognized lines gathered into paragraphs, so a sentence wrapped over several lines
/// is translated whole, and the translation laid back over where the paragraph was.
public enum TranslationLayout {
    /// Lines of text that read as one, and the box they fill together. Boxes are in unit
    /// coordinates with a bottom-left origin, as Vision gives them.
    public struct Paragraph: Equatable, Sendable {
        public var text: String
        public var box: CGRect
        public var lineCount: Int
        /// The average line's height.
        public var lineHeight: Double

        public init(text: String, box: CGRect, lineCount: Int, lineHeight: Double) {
            self.text = text
            self.box = box
            self.lineCount = lineCount
            self.lineHeight = lineHeight
        }
    }

    /// `lines` (top to bottom) gathered into paragraphs: a line joins the one above when it
    /// starts at about the same place, is about as tall, and follows closely underneath.
    /// `aspectRatio` (width over height) puts horizontal and vertical distances on one scale.
    public static func paragraphs(_ lines: [(text: String, box: CGRect)], aspectRatio: Double) -> [Paragraph] {
        var paragraphs: [Paragraph] = []
        var last: CGRect?
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if let previous = last, var paragraph = paragraphs.last, !endsSentence(paragraph.text),
               follows(line.box, previous, paragraph: paragraph, aspectRatio: aspectRatio) {
                paragraph.text = joined(paragraph.text, text)
                paragraph.lineHeight = (paragraph.lineHeight * Double(paragraph.lineCount) + line.box.height) / Double(paragraph.lineCount + 1)
                paragraph.lineCount += 1
                paragraph.box = paragraph.box.union(line.box)
                paragraphs[paragraphs.count - 1] = paragraph
            } else {
                paragraphs.append(Paragraph(text: text, box: line.box, lineCount: 1, lineHeight: line.box.height))
            }
            last = line.box
        }
        return paragraphs
    }

    static func follows(_ line: CGRect, _ previous: CGRect, paragraph: Paragraph, aspectRatio: Double) -> Bool {
        let height = paragraph.lineHeight
        let gap = previous.minY - line.maxY
        let sameSize = abs(line.height - height) < height * 0.3
        // Left edges compared in the image's own proportions.
        let indent = abs(line.minX - paragraph.box.minX) * aspectRatio
        // A line that stops well short of the others ends its paragraph; one reaching well past
        // them (after a label, say) starts another.
        let shortfall = (paragraph.box.maxX - previous.maxX) * aspectRatio
        let overrun = (line.maxX - paragraph.box.maxX) * aspectRatio
        return sameSize && gap > -height * 0.3 && gap < height * 0.8 && indent < height * 1.2 && shortfall < height * 3 && overrun < height * 3
    }

    /// Ends with a full stop, question or exclamation mark, or a colon.
    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "。！？：.!?:".contains(last)
    }

    /// Two wrapped lines joined: straight on for Chinese and Japanese, with a space otherwise,
    /// and a hyphenated break mended.
    static func joined(_ first: String, _ second: String) -> String {
        if first.hasSuffix("-"), first.dropLast().last?.isLetter == true, second.first?.isLowercase == true {
            return String(first.dropLast()) + second
        }
        guard let end = first.unicodeScalars.last, let start = second.unicodeScalars.first else { return first + second }
        return isCJK(end) || isCJK(start) ? first + second : first + " " + second
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000 ... 0x30FF, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF, 0xFF00 ... 0xFFEF, 0xAC00 ... 0xD7AF: true
        default: false
        }
    }
}

/// Languages 截图翻译 offers to translate into.
public enum TranslationTarget: String, CaseIterable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"

    public var title: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .french: "Français"
        case .german: "Deutsch"
        case .spanish: "Español"
        }
    }

    /// The language a screenshot is put into when nothing else is chosen: English for Chinese
    /// text, else Simplified Chinese.
    public static func suggested(forSource source: String?, preferred: TranslationTarget?) -> TranslationTarget {
        let isChinese = source?.hasPrefix("zh") == true
        if let preferred, !matches(preferred, source) { return preferred }
        return isChinese ? .english : .simplifiedChinese
    }

    /// Whether `target` is the language `source` already is.
    public static func matches(_ target: TranslationTarget, _ source: String?) -> Bool {
        guard let source else { return false }
        if target == .simplifiedChinese { return source.hasPrefix("zh") }
        return source == target.rawValue || source.hasPrefix(target.rawValue + "-")
    }
}
