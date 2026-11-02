import XCTest
@testable import PixSnapCore

final class UpdateTests: XCTestCase {
    func testVersionsCompareNumberByNumber() {
        XCTAssertLessThan(AppVersion("0.9.2")!, AppVersion("0.10.0")!)
        XCTAssertLessThan(AppVersion("0.3")!, AppVersion("v0.3.1")!)
        XCTAssertEqual(AppVersion("1.0")!, AppVersion("1.0.0")!)
        XCTAssertEqual(AppVersion("v0.3.1")?.description, "0.3.1")
        XCTAssertNil(AppVersion("0.3.1-beta"))
        XCTAssertNil(AppVersion(""))
    }

    private func info(_ version: String, needs system: String = "14.0") -> UpdateInfo {
        UpdateInfo(version: version, notes: "", url: URL(string: "https://example.com/PixSnap.pkg")!, sha256: "", size: 0,
                   minimumSystemVersion: system)
    }

    func testOnlyNewerVersionsThatRunHereAreUpdates() {
        XCTAssertTrue(info("0.4.0").isUpdate(over: "0.3.1", system: "14.6.1"))
        XCTAssertFalse(info("0.3.1").isUpdate(over: "0.3.1", system: "14.6.1"))
        XCTAssertFalse(info("0.3.0").isUpdate(over: "0.3.1", system: "14.6.1"))
        XCTAssertFalse(info("0.4.0", needs: "15.0").isUpdate(over: "0.3.1", system: "14.6.1"))
        XCTAssertTrue(info("0.4.0", needs: "15.0").isUpdate(over: "0.3.1", system: "26.1"))
    }

    func testDecodesLatestJSON() throws {
        let json = """
        {"version":"0.4.0","notes":"## 新功能\\n- **自动更新**","url":"https://github.com/calabli/PixSnap/releases/download/v0.4.0/PixSnap-0.4.0.pkg",
         "sha256":"abc","size":123,"minimumSystemVersion":"14.0"}
        """
        let decoded = try JSONDecoder().decode(UpdateInfo.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.version, "0.4.0")
        XCTAssertEqual(decoded.url.lastPathComponent, "PixSnap-0.4.0.pkg")
        XCTAssertEqual(decoded.size, 123)
    }
}
