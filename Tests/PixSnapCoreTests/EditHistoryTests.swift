import XCTest
@testable import PixSnapCore

final class EditHistoryTests: XCTestCase {
    func testUndoAndRedoWalkThroughCommits() {
        var history = EditHistory(0)
        history.commit(1)
        history.commit(2)
        history.undo()
        XCTAssertEqual(history.current, 1)
        history.undo()
        XCTAssertEqual(history.current, 0)
        XCTAssertFalse(history.canUndo)
        history.redo()
        XCTAssertEqual(history.current, 1)
        XCTAssertTrue(history.canRedo)
    }

    func testUnchangedCommitIsNotAStep() {
        var history = EditHistory(5)
        history.apply { $0 = 5 }
        XCTAssertFalse(history.canUndo)
    }

    func testNewCommitClearsRedo() {
        var history = EditHistory("a")
        history.commit("b")
        history.undo()
        history.commit("c")
        XCTAssertFalse(history.canRedo)
        history.undo()
        XCTAssertEqual(history.current, "a")
    }

    func testOldestStepsAreDroppedPastTheLimit() {
        var history = EditHistory(0, limit: 2)
        (1...4).forEach { history.commit($0) }
        history.undo()
        history.undo()
        history.undo()
        XCTAssertEqual(history.current, 2)
    }
}
