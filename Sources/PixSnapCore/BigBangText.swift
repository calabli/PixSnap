import Foundation

/// Text broken into pieces for picking one by one ("大爆炸"): words, and the punctuation and symbols
/// between them, in reading order, so the picked pieces join back into the original text.
public enum BigBangText {
    public struct Piece: Equatable, Sendable {
        public let text: String
        /// A word (or number); false for punctuation and symbols.
        public let isWord: Bool
        /// Which line of the image it was on.
        public let line: Int

        public init(text: String, isWord: Bool, line: Int) {
            self.text = text
            self.isWord = isWord
            self.line = line
        }
    }

    /// Splits one line into pieces: the given word ranges, plus whatever non-blank text lies
    /// between them (each punctuation run one piece). Spaces are dropped; they come back in `join`.
    public static func pieces(of line: String, words: [Range<String.Index>], lineNumber: Int) -> [Piece] {
        var pieces: [Piece] = []
        var cursor = line.startIndex
        func addGap(upTo end: String.Index) {
            guard cursor < end else { return }
            for run in line[cursor ..< end].split(whereSeparator: \.isWhitespace) {
                pieces.append(Piece(text: String(run), isWord: false, line: lineNumber))
            }
        }
        for range in words.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.lowerBound >= cursor {
            addGap(upTo: range.lowerBound)
            let word = line[range].trimmingCharacters(in: .whitespaces)
            if !word.isEmpty { pieces.append(Piece(text: word, isWord: true, line: lineNumber)) }
            cursor = range.upperBound
        }
        addGap(upTo: line.endIndex)
        return pieces
    }

    /// Joins picked pieces back into text: a space between two pieces only where both sides are
    /// letters or digits of a spaced script (English words, numbers), none for Chinese or around
    /// punctuation, and a line break where the picks jump to a later line of the image.
    public static func join(_ pieces: [Piece]) -> String {
        var text = ""
        var previous: Piece?
        for piece in pieces {
            if let previous {
                if piece.line != previous.line, needsSpace(after: previous.text, before: piece.text) || piece.line > previous.line + 1 {
                    text += "\n"
                } else if needsSpace(after: previous.text, before: piece.text) {
                    text += " "
                }
            }
            text += piece.text
            previous = piece
        }
        return text
    }

    private static func needsSpace(after left: String, before right: String) -> Bool {
        guard let last = left.unicodeScalars.last, let first = right.unicodeScalars.first else { return false }
        return isSpacedWordCharacter(last) && isSpacedWordCharacter(first)
    }

    /// Latin letters and digits are separated by spaces; CJK characters aren't.
    private static func isSpacedWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic && !isCJK(scalar) || ("0" ... "9").contains(scalar)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040 ... 0x30FF, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xAC00 ... 0xD7AF, 0xF900 ... 0xFAFF, 0x20000 ... 0x2FA1F: true
        default: false
        }
    }
}
