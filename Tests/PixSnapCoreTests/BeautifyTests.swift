@testable import PixSnapCore
import XCTest

final class BeautifyTests: XCTestCase {
    private func signals(lines: [String] = [], spans: [ClosedRange<Double>] = [], text: Double = 0, brightness: Double = 0.9,
                         flatness: Double = 0.9, concentration: Double = 0.95, accent: RGB = RGB(0.2, 0.5, 1),
                         app: String? = nil) -> ContentSignals {
        ContentSignals(lines: lines, lineSpans: spans, textCoverage: text, brightness: brightness, flatness: flatness,
                       concentration: concentration, accent: accent, aspectRatio: 1.5, sourceApp: app)
    }

    func testCodeIsRecognizedByItsSymbolsAndKeywords() {
        let code = ["import SwiftUI", "struct ContentView: View {", "@State private var count = 0", "var body: some View {", "Text(\"Hi\")", "}"]
        XCTAssertGreaterThan(ContentClassifier.codeScore(code), 0.6)
        XCTAssertEqual(ContentClassifier.classify(signals(lines: code, text: 0.2, brightness: 0.1)), .code)
        // Line numbers don't dilute it.
        XCTAssertEqual(ContentClassifier.codeScore(code + ["1", "2", "3", "4", "5", "6"]), ContentClassifier.codeScore(code))
    }

    func testProseIsADocument() {
        let prose = Array(repeating: "一个好的截图工具应该尽量少打扰用户，按下快捷键之后画面应该立即冻结。", count: 8)
        XCTAssertEqual(ContentClassifier.codeScore(prose), 0)
        XCTAssertEqual(ContentClassifier.classify(signals(lines: prose, text: 0.25)), .document)
    }

    func testBubblesOnBothSidesAreAChat() {
        let chat = signals(lines: ["今晚一起吃饭吗？", "好呀，几点？", "七点，老地方", "没问题"],
                           spans: [0.15 ... 0.45, 0.55 ... 0.85, 0.15 ... 0.4, 0.6 ... 0.85], text: 0.05)
        XCTAssertTrue(ContentClassifier.looksLikeChat(chat))
        XCTAssertEqual(ContentClassifier.classify(chat), .chat)
        XCTAssertEqual(ContentClassifier.classify(signals(lines: ["hi"], app: "微信")), .chat)
    }

    func testPhotosHaveLittleTextAndManyColors() {
        XCTAssertEqual(ContentClassifier.classify(signals(flatness: 0.3, concentration: 0.2)), .photo)
        XCTAssertEqual(ContentClassifier.classify(signals(flatness: 0.7, concentration: 0.5)), .photo)
        // Text on it makes it something else.
        XCTAssertNotEqual(ContentClassifier.classify(signals(text: 0.3, flatness: 0.3, concentration: 0.2)), .photo)
    }

    func testEverythingElseIsInterface() {
        XCTAssertEqual(ContentClassifier.classify(signals(lines: ["订单详情", "客户：张三", "确认发货"], text: 0.03)), .interface)
    }

    func testHueRoundTripsAndGraysGetBlue() {
        let color = RGB(hue: 0.3, saturation: 0.6, brightness: 0.8)
        XCTAssertEqual(color.hsb.hue, 0.3, accuracy: 0.001)
        XCTAssertEqual(color.hsb.saturation, 0.6, accuracy: 0.001)
        XCTAssertEqual(color.hsb.brightness, 0.8, accuracy: 0.001)
        XCTAssertEqual(signals(accent: RGB(0.5, 0.5, 0.5)).hue, 0.6)
    }

    func testStylesFollowTheContentAndItsBrightness() {
        let dark = signals(brightness: 0.1)
        XCTAssertEqual(BeautifyStyle.recommended(for: .code, dark).frame, .window(dark: true))
        XCTAssertEqual(BeautifyStyle.recommended(for: .photo, dark).background, .blurredImage)
        guard case let .gradient(from, _) = BeautifyStyle.recommended(for: .interface, signals(brightness: 0.95)).background else {
            return XCTFail("a gradient")
        }
        XCTAssertGreaterThan(from.luminance, 0.8)
        let choices = BeautifyStyle.choices(for: .document, dark)
        XCTAssertEqual(choices.first?.name, "文档")
        XCTAssertEqual(Set(choices.map(\.name)).count, choices.count)
    }

    func testPaddingScalesWithinLimits() {
        let style = BeautifyStyle.recommended(for: .interface, signals())
        XCTAssertEqual(style.paddingPoints(width: 50, height: 50), BeautifyStyle.paddingRange.lowerBound)
        XCTAssertEqual(style.paddingPoints(width: 5000, height: 4000), BeautifyStyle.paddingRange.upperBound)
        XCTAssertEqual(style.paddingPoints(width: 800, height: 500), 50, accuracy: 0.001)
    }

    func testFixedPaddingOverridesShareAndStaysInRange() {
        var style = BeautifyStyle(name: "x", background: .blurredImage, padding: 0.1, cornerRadius: 12, shadow: .soft, frame: .none)
        XCTAssertEqual(style.paddingPoints(width: 600, height: 400), 40)
        style.fixedPadding = 0
        XCTAssertEqual(style.paddingPoints(width: 600, height: 400), 0)
        style.fixedPadding = 500
        XCTAssertEqual(style.paddingPoints(width: 600, height: 400), BeautifyStyle.manualPaddingRange.upperBound)
    }

    func testTallChatsGoInAPhone() {
        var tall = signals(brightness: 0.9)
        tall.aspectRatio = 0.5
        XCTAssertEqual(BeautifyStyle.recommended(for: .chat, tall).frame, .phone(dark: false))
        var wide = signals(brightness: 0.9)
        wide.aspectRatio = 1.6
        XCTAssertEqual(BeautifyStyle.recommended(for: .chat, wide).frame, BeautifyStyle.Frame.none)
    }

    func testStylesRoundTripThroughJSON() throws {
        let style = BeautifyStyle(name: "我的", background: .gradient(RGB(1, 0.5, 0), RGB(0, 0, 1)), padding: 0.1, cornerRadius: 20,
                                  shadow: .deep, frame: .phone(dark: true), fixedPadding: 64)
        let decoded = try JSONDecoder().decode(BeautifyStyle.self, from: JSONEncoder().encode(style))
        XCTAssertEqual(decoded, style)
    }
}

