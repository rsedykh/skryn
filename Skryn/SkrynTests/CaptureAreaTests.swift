import XCTest
@testable import Skryn

final class CaptureAreaTests: XCTestCase {

    func testGlobalFrame_mainScreen_flipsY() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = CGRect(x: 100, y: 50, width: 400, height: 300)
        XCTAssertEqual(CaptureArea.globalFrame(of: rect, onScreenAt: screen), CGRect(x: 100, y: 550, width: 400, height: 300))
    }

    func testGlobalFrame_mainScreen_fullScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = CGRect(origin: .zero, size: screen.size)
        XCTAssertEqual(CaptureArea.globalFrame(of: rect, onScreenAt: screen), screen)
    }

    func testGlobalFrame_offsetSecondScreen() {
        // A second display to the left of and below the main one.
        let screen = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let rect = CGRect(x: 20, y: 80, width: 600, height: 400)
        XCTAssertEqual(
            CaptureArea.globalFrame(of: rect, onScreenAt: screen),
            CGRect(x: -1900, y: 300, width: 600, height: 400)
        )
    }

    func testGlobalFrame_secondScreenAbove() {
        let screen = CGRect(x: 1440, y: 900, width: 2560, height: 1440)
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(
            CaptureArea.globalFrame(of: rect, onScreenAt: screen),
            CGRect(x: 1440, y: 2240, width: 100, height: 100)
        )
    }
}
