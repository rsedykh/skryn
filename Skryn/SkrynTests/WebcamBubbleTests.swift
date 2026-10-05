import XCTest
@testable import Skryn

@MainActor
final class WebcamBubbleTests: XCTestCase {
    func testInitialFrame_circleInsetFromBottomRight() {
        let area = CGRect(x: 100, y: 100, width: 800, height: 600)
        let frame = WebcamBubble.initialFrame(in: area)
        let circle = frame.insetBy(dx: WebcamBubble.shadowPadding, dy: WebcamBubble.shadowPadding)
        XCTAssertEqual(circle.width, WebcamBubble.diameter)
        XCTAssertEqual(circle.maxX, area.maxX - WebcamBubble.inset)
        XCTAssertEqual(circle.minY, area.minY + WebcamBubble.inset)
    }
}
