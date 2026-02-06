import XCTest
@testable import Skryn

final class AnnotationViewTests: XCTestCase {

    // MARK: - rectFromDrag

    private func makeView(imageSize: NSSize = NSSize(width: 200, height: 100)) -> AnnotationView {
        let image = NSImage(size: imageSize)
        return AnnotationView(frame: NSRect(origin: .zero, size: imageSize), image: image)
    }

    func testRectFromDrag_topLeftToBottomRight() {
        let view = makeView()
        let rect = view.rectFromDrag(
            origin: CGPoint(x: 10, y: 20),
            current: CGPoint(x: 50, y: 60)
        )
        XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 40, height: 40))
    }

    func testRectFromDrag_bottomRightToTopLeft() {
        let view = makeView()
        let rect = view.rectFromDrag(
            origin: CGPoint(x: 50, y: 60),
            current: CGPoint(x: 10, y: 20)
        )
        XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 40, height: 40))
    }

    func testRectFromDrag_zeroSize() {
        let view = makeView()
        let rect = view.rectFromDrag(
            origin: CGPoint(x: 30, y: 30),
            current: CGPoint(x: 30, y: 30)
        )
        XCTAssertEqual(rect, CGRect(x: 30, y: 30, width: 0, height: 0))
    }

    func testRectFromDrag_negativeDirection() {
        let view = makeView()
        let rect = view.rectFromDrag(
            origin: CGPoint(x: 100, y: 200),
            current: CGPoint(x: 10, y: 50)
        )
        XCTAssertEqual(rect, CGRect(x: 10, y: 50, width: 90, height: 150))
    }

    // MARK: - viewToScreenshot

    func testViewToScreenshot_sameScale() {
        // View frame matches screenshot size (1:1)
        let view = makeView(imageSize: NSSize(width: 200, height: 100))
        let result = view.viewToScreenshot(CGPoint(x: 50, y: 25))
        XCTAssertEqual(result.x, 50, accuracy: 0.001)
        XCTAssertEqual(result.y, 25, accuracy: 0.001)
    }

    func testViewToScreenshot_2xScale() {
        // Screenshot is 2x the view size (Retina-like)
        let image = NSImage(size: NSSize(width: 400, height: 200))
        let view = AnnotationView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), image: image)
        let result = view.viewToScreenshot(CGPoint(x: 100, y: 50))
        XCTAssertEqual(result.x, 200, accuracy: 0.001)
        XCTAssertEqual(result.y, 100, accuracy: 0.001)
    }

    func testViewToScreenshot_clampsNegative() {
        let view = makeView(imageSize: NSSize(width: 200, height: 100))
        let result = view.viewToScreenshot(CGPoint(x: -50, y: -30))
        XCTAssertEqual(result.x, 0, accuracy: 0.001)
        XCTAssertEqual(result.y, 0, accuracy: 0.001)
    }

    func testViewToScreenshot_clampsBeyondBounds() {
        let view = makeView(imageSize: NSSize(width: 200, height: 100))
        let result = view.viewToScreenshot(CGPoint(x: 300, y: 200))
        XCTAssertEqual(result.x, 200, accuracy: 0.001)
        XCTAssertEqual(result.y, 100, accuracy: 0.001)
    }

    func testViewToScreenshot_origin() {
        let view = makeView(imageSize: NSSize(width: 200, height: 100))
        let result = view.viewToScreenshot(CGPoint(x: 0, y: 0))
        XCTAssertEqual(result.x, 0, accuracy: 0.001)
        XCTAssertEqual(result.y, 0, accuracy: 0.001)
    }

    // MARK: - Crop replacement logic

    func testCropReplacement_onlyOneCropAllowed() {
        // Verify the Annotation enum structure supports this
        let crop1 = Annotation.crop(rect: CGRect(x: 0, y: 0, width: 50, height: 50))
        let crop2 = Annotation.crop(rect: CGRect(x: 10, y: 10, width: 80, height: 80))

        var annotations: [Annotation] = [
            .arrow(from: .zero, to: CGPoint(x: 10, y: 10)),
            crop1
        ]

        // Simulate addAnnotation's crop replacement logic
        if case .crop = crop2 {
            annotations.removeAll { if case .crop = $0 { return true }; return false }
        }
        annotations.append(crop2)

        let cropCount = annotations.filter { if case .crop = $0 { return true }; return false }.count
        XCTAssertEqual(cropCount, 1)
        XCTAssertEqual(annotations.count, 2) // arrow + new crop
    }

    func testCropReplacement_nonCropDoesNotRemoveExisting() {
        var annotations: [Annotation] = [
            .crop(rect: CGRect(x: 0, y: 0, width: 50, height: 50))
        ]

        let newAnnotation = Annotation.arrow(from: .zero, to: CGPoint(x: 100, y: 100))
        if case .crop = newAnnotation {
            annotations.removeAll { if case .crop = $0 { return true }; return false }
        }
        annotations.append(newAnnotation)

        let cropCount = annotations.filter { if case .crop = $0 { return true }; return false }.count
        XCTAssertEqual(cropCount, 1)
        XCTAssertEqual(annotations.count, 2) // crop + arrow
    }
}
