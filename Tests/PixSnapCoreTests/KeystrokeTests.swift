import XCTest
@testable import PixSnapCore

final class KeystrokeTests: XCTestCase {
    func testShortcutsShowModifiersInMenuOrder() {
        XCTAssertEqual(Keystroke.label(keyCode: 21, modifiers: [.command, .shift], characters: "4"), "⇧⌘4")
        XCTAssertEqual(Keystroke.label(keyCode: 8, modifiers: [.command, .option, .control], characters: "c"), "⌃⌥⌘C")
    }

    func testSpecialKeysShowAlone() {
        XCTAssertEqual(Keystroke.label(keyCode: 36, modifiers: [], characters: "\r"), "↩")
        XCTAssertEqual(Keystroke.label(keyCode: 123, modifiers: [.option], characters: nil), "⌥←")
        XCTAssertEqual(Keystroke.label(keyCode: 53, modifiers: [], characters: nil), "esc")
    }

    func testPlainTypingIsNotShown() {
        XCTAssertNil(Keystroke.label(keyCode: 0, modifiers: [], characters: "a"))
        XCTAssertNil(Keystroke.label(keyCode: 0, modifiers: [.shift], characters: "A"))
    }
}
