import XCTest
@testable import PixSnapCore

final class ShortcutTests: XCTestCase {
    func testDisplayUsesMacModifierOrder() {
        let shortcut = Shortcut(keyCode: 0, modifiers: [.command, .shift, .control, .option], keyLabel: "A")
        XCTAssertEqual(shortcut.displayString, "⌃⌥⇧⌘A")
        XCTAssertEqual(Shortcut.defaultCapture.displayString, "⇧⌘2")
    }

    func testGlobalShortcutNeedsARealModifier() {
        XCTAssertFalse(Shortcut(keyCode: 0, modifiers: [], keyLabel: "A").isUsableGlobally)
        XCTAssertFalse(Shortcut(keyCode: 0, modifiers: [.shift], keyLabel: "A").isUsableGlobally)
        XCTAssertTrue(Shortcut(keyCode: 0, modifiers: [.option], keyLabel: "A").isUsableGlobally)
        XCTAssertTrue(Shortcut.defaultCapture.isUsableGlobally)
    }

    func testFunctionKeysWorkAlone() {
        XCTAssertTrue(Shortcut(keyCode: 122, modifiers: [], keyLabel: "F1").isUsableGlobally)
        XCTAssertFalse(Shortcut(keyCode: 3, modifiers: [], keyLabel: "F").isUsableGlobally)
    }

    func testRoundTripsThroughJSON() throws {
        let shortcut = Shortcut(keyCode: 122, modifiers: [.option, .shift], keyLabel: "F1")
        let decoded = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(shortcut))
        XCTAssertEqual(decoded, shortcut)
    }
}
