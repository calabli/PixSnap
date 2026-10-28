import CoreGraphics
import NaturalLanguage
import PixSnapCore
import Vision

/// Finds the text in a screenshot with Vision, on this Mac: Chinese (simplified and traditional)
/// and English, accurate mode. Lines come back top to bottom, left to right.
enum TextRecognizer {
    static func text(in image: CGImage) async -> String {
        await Task.detached(priority: .utility) { readLines(image).map(\.candidate.string).joined(separator: "\n") }.value
    }

    /// A piece of text and where it is in the image: unit coordinates, bottom-left origin.
    struct PlacedPiece: Sendable {
        let piece: BigBangText.Piece
        let box: CGRect
    }

    /// The text broken into words and punctuation (see `BigBangText`), each with its place.
    static func pieces(in image: CGImage) async -> [PlacedPiece] {
        await Task.detached(priority: .userInitiated) {
            readLines(image).enumerated().flatMap { number, line -> [PlacedPiece] in
                let text = line.candidate.string
                let tokenizer = NLTokenizer(unit: .word)
                tokenizer.string = text
                let pieces = BigBangText.pieces(of: text, words: tokenizer.tokens(for: text.startIndex ..< text.endIndex), lineNumber: number)
                // Each piece's own box, found by walking the line in order.
                var cursor = text.startIndex
                return pieces.map { piece in
                    guard let range = text.range(of: piece.text, range: cursor ..< text.endIndex) else {
                        return PlacedPiece(piece: piece, box: line.box)
                    }
                    cursor = range.upperBound
                    let box = (try? line.candidate.boundingBox(for: range))?.boundingBox ?? line.box
                    return PlacedPiece(piece: piece, box: box)
                }
            }
        }.value
    }

    /// Recognized lines in reading order.
    private static func readLines(_ image: CGImage) -> [(box: CGRect, candidate: VNRecognizedText)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return []
        }
        let lines = (request.results ?? []).compactMap { observation -> (box: CGRect, candidate: VNRecognizedText)? in
            guard let best = observation.topCandidates(1).first else { return nil }
            return (observation.boundingBox, best)
        }
        // Vision's boxes have a bottom-left origin: higher first, then left to right on a line.
        return lines.sorted { a, b in
            abs(a.box.midY - b.box.midY) > min(a.box.height, b.box.height) / 2 ? a.box.midY > b.box.midY : a.box.minX < b.box.minX
        }
    }
}
