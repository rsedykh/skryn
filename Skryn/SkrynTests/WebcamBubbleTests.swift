import XCTest
@testable import Skryn

@MainActor
final class WebcamBubbleTests: XCTestCase {
    func testGlobalRect_flipsYOnPrimaryScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = WebcamBubble.globalRect(fromTopLeft: CGRect(x: 100, y: 50, width: 300, height: 200),
                                           screenFrame: screen)
        XCTAssertEqual(rect, CGRect(x: 100, y: 650, width: 300, height: 200))
    }

    func testGlobalRect_offsetsBySecondaryScreenOrigin() {
        let screen = CGRect(x: -1920, y: 900, width: 1920, height: 1080)
        let rect = WebcamBubble.globalRect(fromTopLeft: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                           screenFrame: screen)
        XCTAssertEqual(rect, screen)
    }

    func testInitialFrame_circleInsetFromBottomRight() {
        let area = CGRect(x: 100, y: 100, width: 800, height: 600)
        let frame = WebcamBubble.initialFrame(in: area)
        let circle = frame.insetBy(dx: WebcamBubble.shadowPadding, dy: WebcamBubble.shadowPadding)
        XCTAssertEqual(circle.width, WebcamBubble.diameter)
        XCTAssertEqual(circle.maxX, area.maxX - WebcamBubble.inset)
        XCTAssertEqual(circle.minY, area.minY + WebcamBubble.inset)
    }
}
