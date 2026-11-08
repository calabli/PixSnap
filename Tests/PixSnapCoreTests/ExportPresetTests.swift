import XCTest
@testable import PixSnapCore

final class ExportPresetTests: XCTestCase {
    let retina = CGSize(width: 3200, height: 2000)

    func testOriginalKeepsTheSize() {
        XCTAssertEqual(ExportPreset.original.settings(size: retina, duration: 60).size, retina)
    }

    func test1080pFitsTheLongSide() {
        let out = ExportPreset.hd1080.settings(size: retina, duration: 60)
        XCTAssertEqual(out.size, CGSize(width: 1920, height: 1200))
        XCTAssertLessThanOrEqual(out.bitRate, 10_000_000)
    }

    func testWeChatStaysUnder25MB() {
        for duration in [10.0, 60, 180, 400] {
            let out = ExportPreset.wechat.settings(size: retina, duration: duration)
            let bytes = (out.bitRate + ExportPreset.audioBitRate) * duration / 8
            XCTAssertLessThanOrEqual(bytes, 25_000_000, "\(duration) s")
            XCTAssertEqual(Int(out.size.width) % 2, 0)
        }
        // Long recordings get smaller pictures rather than mush.
        XCTAssertEqual(ExportPreset.wechat.settings(size: retina, duration: 30).size.width, 1920)
        XCTAssertEqual(ExportPreset.wechat.settings(size: retina, duration: 300).size.width, 960)
    }
}
