import XCTest
@testable import PixSnapCore

final class CaptureActionTests: XCTestCase {
    func testDefaultShortcutsAreDistinctAndUsable() {
        let shortcuts = CaptureAction.allCases.map(\.defaultShortcut)
        XCTAssertEqual(Set(shortcuts).count, shortcuts.count)
        XCTAssertTrue(shortcuts.allSatisfy(\.isUsableGlobally))
        XCTAssertEqual(CaptureAction.window.defaultShortcut.displayString, "⌥⇧4")
    }

    func testWindowStyleFallsBackFieldByField() throws {
        let data = Data(#"{"keepsShadow":false,"background":"neon"}"#.utf8)
        let style = try JSONDecoder().decode(WindowCaptureStyle.self, from: data)
        XCTAssertEqual(style, WindowCaptureStyle(keepsShadow: false, background: .none))
        let roundTrip = WindowCaptureStyle(keepsShadow: true, background: .ocean)
        XCTAssertEqual(try JSONDecoder().decode(WindowCaptureStyle.self, from: JSONEncoder().encode(roundTrip)), roundTrip)
    }
}
