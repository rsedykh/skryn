import XCTest
@testable import Skryn

final class CanvasViewportTests: XCTestCase {
    private func viewport() -> CanvasViewport {
        CanvasViewport(viewSize: CGSize(width: 400, height: 200), imageSize: CGSize(width: 800, height: 400))
    }

    func testFitFillsTheView() {
        let fit = viewport()
        XCTAssertEqual(fit.scale, 0.5)
        XCTAssertEqual(fit.imageRect, CGRect(x: 0, y: 0, width: 400, height: 200))
        XCTAssertFalse(fit.isZoomed)
    }

    func testZoomKeepsThePointUnderTheAnchor() {
        var zoomed = viewport()
        let anchor = CGPoint(x: 100, y: 50)
        zoomed.zoom(to: 2, around: anchor)
        XCTAssertEqual(zoomed.scale, 1)
        // Image point (200, 100) was under the anchor at the fit and still is
        XCTAssertEqual(zoomed.imageRect.minX + 200 * zoomed.scale, anchor.x)
        XCTAssertEqual(zoomed.imageRect.minY + 100 * zoomed.scale, anchor.y)
    }

    func testZoomIsClampedFromFitToMax() {
        var zoomed = viewport()
        zoomed.zoom(to: 0.3, around: .zero)
        XCTAssertEqual(zoomed.zoom, 1)
        zoomed.zoom(to: 100, around: .zero)
        XCTAssertEqual(zoomed.zoom, CanvasViewport.maxZoom)
    }

    func testPanStopsAtTheImageEdges() {
        var zoomed = viewport()
        zoomed.zoom(to: 2, around: .zero)
        zoomed.pan(by: CGVector(dx: 50, dy: 50))  // already at the top-left edge
        XCTAssertEqual(zoomed.imageRect.origin, .zero)
        zoomed.pan(by: CGVector(dx: -10_000, dy: -10_000))
        XCTAssertEqual(zoomed.imageRect.maxX, 400)
        XCTAssertEqual(zoomed.imageRect.maxY, 200)
        zoomed.reset()
        XCTAssertEqual(zoomed, viewport())
    }

    func testUnsavedMarksCountAnnotations() {
        let image = NSImage(size: NSSize(width: 100, height: 100))
        let view = AnnotationView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), screenshot: image)
        XCTAssertEqual(view.unsavedMarkCount, 0)
        view.setAnnotations(forTesting: [.badge(center: .zero, number: 1, color: .red), .crop(rect: .zero)])
        XCTAssertEqual(view.unsavedMarkCount, 2)
    }
}

final class DragConstraintTests: XCTestCase {
    func testAngularSnapsToNearest45KeepingLength() {
        let anchor = CGPoint(x: 10, y: 10)
        XCTAssertEqual(AnnotationTool.constrained(CGPoint(x: 110, y: 18), from: anchor, angular: true).y, 10)
        let diagonal = AnnotationTool.constrained(CGPoint(x: 80, y: 70), from: anchor, angular: true)
        XCTAssertEqual(diagonal.x - anchor.x, diagonal.y - anchor.y)
        XCTAssertEqual(hypot(diagonal.x - anchor.x, diagonal.y - anchor.y), hypot(70, 60), accuracy: 1)
        XCTAssertEqual(AnnotationTool.constrained(CGPoint(x: 13, y: -90), from: anchor, angular: true).x, 10)
    }

    func testBoxesBecomeSquaresOnTheLongerSideInTheDragDirection() {
        let anchor = CGPoint(x: 100, y: 100)
        XCTAssertEqual(AnnotationTool.constrained(CGPoint(x: 160, y: 120), from: anchor, angular: false),
                       CGPoint(x: 160, y: 160))
        XCTAssertEqual(AnnotationTool.constrained(CGPoint(x: 70, y: 20), from: anchor, angular: false),
                       CGPoint(x: 20, y: 20))
    }

    func testOppositeHandlesPairUp() {
        let pairs: [(AnnotationHandle, AnnotationHandle)] = [(.from, .to), (.topLeft, .bottomRight), (.topRight, .bottomLeft)]
        for (a, b) in pairs {
            XCTAssertEqual(a.opposite, b)
            XCTAssertEqual(b.opposite, a)
        }
        XCTAssertNil(AnnotationHandle.left.opposite)
        XCTAssertTrue(AnnotationTool.arrow.constrainsAngle)
        XCTAssertFalse(AnnotationTool.rectangle.constrainsAngle)
    }
}
