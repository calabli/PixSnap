import XCTest
@testable import PixSnapCore

final class NotchConflictTests: XCTestCase {
    func testFindsKnownAppsByBundleIDOrName() {
        let running: [(bundleID: String?, name: String?)] = [
            ("com.apple.finder", "访达"), ("lo.cafe.NotchNook", "NotchNook"), (nil, "Alcove"), ("com.apple.Safari", "Safari"),
        ]
        XCTAssertEqual(NotchConflict.conflicting(in: running), ["NotchNook", "Alcove"])
    }

    func testFindsOtherAppsWithNotchInTheName() {
        XCTAssertEqual(NotchConflict.conflicting(in: [("com.example.supernotch", "SuperNotch")]), ["SuperNotch"])
    }

    func testIgnoresPixSnapTopNotchAndDuplicates() {
        let running: [(bundleID: String?, name: String?)] = [
            ("com.pixsnap.PixSnap", "PixSnap Notch"), ("pl.maketheweb.TopNotch", "TopNotch"),
            ("lo.cafe.NotchNook", "NotchNook"), (nil, "NotchNook"),
        ]
        XCTAssertEqual(NotchConflict.conflicting(in: running), ["NotchNook"])
    }
}
