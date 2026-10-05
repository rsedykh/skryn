import XCTest
@testable import Skryn

/// Picking the mark a press means among overlapping ones (`[Annotation].hitTest`, `bodyCandidates`)
final class HitTestingTests: XCTestCase {
    private func hit(_ annotations: [Annotation], _ point: CGPoint, preferring: [Int] = [], selection: Int? = nil)
        -> AnnotationHitTestResult {
        annotations.hitTest(point, handleRadius: 10, bodyRadius: 6, preferring: preferring, selection: selection)
    }

    private func bodyIndex(_ result: AnnotationHitTestResult) -> Int? {
        if case .body(let index) = result { return index }
        return nil
    }

    func testNearestStrokeWinsOverTopmost() {
        let lower = Annotation.line(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 200, y: 50), color: .red)
        let upper = Annotation.line(from: CGPoint(x: 0, y: 56), to: CGPoint(x: 200, y: 56), color: .blue)
        // Closer to the lower (older) line: it wins even though the other is on top
        XCTAssertEqual(bodyIndex(hit([lower, upper], CGPoint(x: 100, y: 51))), 0)
        XCTAssertEqual(bodyIndex(hit([lower, upper], CGPoint(x: 100, y: 55))), 1)
    }

    func testStrokeBeatsFillAndSmallFillBeatsBigFill() {
        let blur = Annotation.blur(rect: CGRect(x: 0, y: 0, width: 400, height: 400))
        let highlight = Annotation.highlight(rect: CGRect(x: 50, y: 50, width: 60, height: 20), color: .yellow)
        let arrow = Annotation.arrow(from: CGPoint(x: 0, y: 200), to: CGPoint(x: 300, y: 200), color: .red)
        // Big fill on top doesn't swallow the arrow or the small highlight under it
        let marks = [arrow, highlight, blur]
        XCTAssertEqual(bodyIndex(hit(marks, CGPoint(x: 150, y: 202))), 0)
        XCTAssertEqual(bodyIndex(hit(marks, CGPoint(x: 60, y: 60))), 1)
        XCTAssertEqual(bodyIndex(hit(marks, CGPoint(x: 300, y: 300))), 2)
    }

    func testSelectionStaysGrabbableWhereItOverlaps() {
        let blur = Annotation.blur(rect: CGRect(x: 0, y: 0, width: 400, height: 400))
        let arrow = Annotation.arrow(from: CGPoint(x: 0, y: 200), to: CGPoint(x: 300, y: 200), color: .red)
        XCTAssertEqual(bodyIndex(hit([arrow, blur], CGPoint(x: 150, y: 200), selection: 1)), 1)
        XCTAssertEqual(bodyIndex(hit([arrow, blur], CGPoint(x: 150, y: 200))), 0)
    }

    func testVisibleHandlesWinOverOtherMarksBodies() {
        let rect = Annotation.rectangle(rect: CGRect(x: 100, y: 100, width: 100, height: 100), color: .red)
        let line = Annotation.line(from: CGPoint(x: 95, y: 0), to: CGPoint(x: 95, y: 300), color: .blue)
        // Near the rect's corner but right on the line: the hovered rect's handle wins
        guard case .handle(let index, let handle) = hit([rect, line], CGPoint(x: 96, y: 101), preferring: [0]) else {
            return XCTFail("expected a handle")
        }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(handle, .topLeft)
        XCTAssertEqual(bodyIndex(hit([rect, line], CGPoint(x: 96, y: 101))), 1)
    }

    func testCandidatesListEveryMarkUnderThePointBestFirst() {
        let blur = Annotation.blur(rect: CGRect(x: 0, y: 0, width: 400, height: 400))
        let highlight = Annotation.highlight(rect: CGRect(x: 0, y: 190, width: 300, height: 20), color: .yellow)
        let arrow = Annotation.arrow(from: CGPoint(x: 0, y: 200), to: CGPoint(x: 300, y: 200), color: .red)
        XCTAssertEqual([blur, highlight, arrow].bodyCandidates(at: CGPoint(x: 150, y: 200), tolerance: 6), [2, 1, 0])
    }

    func testRectAndEllipseInteriorsStayFreeForDrawing() {
        let rect = Annotation.rectangle(rect: CGRect(x: 0, y: 0, width: 200, height: 200), color: .red)
        let ellipse = Annotation.ellipse(rect: CGRect(x: 0, y: 0, width: 200, height: 100), color: .red)
        XCTAssertEqual(bodyIndex(hit([rect], CGPoint(x: 100, y: 100))), nil)
        XCTAssertEqual(bodyIndex(hit([ellipse], CGPoint(x: 100, y: 50))), nil)
        XCTAssertEqual(bodyIndex(hit([ellipse], CGPoint(x: 100, y: 2))), 0)
        XCTAssertEqual(bodyIndex(hit([ellipse], CGPoint(x: 203, y: 50))), 0)
    }

    func testThickStrokesAreEasierToHit() {
        let thin = Annotation.line(from: .zero, to: CGPoint(x: 200, y: 0), color: .red, width: .thin)
        let thick = Annotation.line(from: .zero, to: CGPoint(x: 200, y: 0), color: .red, width: .thick)
        XCTAssertNil(thin.hitPrecision(at: CGPoint(x: 100, y: 8), tolerance: 6))
        XCTAssertNotNil(thick.hitPrecision(at: CGPoint(x: 100, y: 8), tolerance: 6))
    }
}
