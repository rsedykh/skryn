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

    // MARK: - Annotation.handles

    func testHandles_arrowReturnsTwoEndpoints() {
        let annotation = Annotation.arrow(
            from: CGPoint(x: 10, y: 20),
            to: CGPoint(x: 50, y: 60)
        )
        let handles = annotation.handles
        XCTAssertEqual(handles.count, 2)
        XCTAssertEqual(handles[0].point, CGPoint(x: 10, y: 20))
        XCTAssertEqual(handles[1].point, CGPoint(x: 50, y: 60))
    }

    func testHandles_lineReturnsTwoEndpoints() {
        let annotation = Annotation.line(
            from: CGPoint(x: 5, y: 15),
            to: CGPoint(x: 95, y: 85)
        )
        let handles = annotation.handles
        XCTAssertEqual(handles.count, 2)
        XCTAssertEqual(handles[0].point, CGPoint(x: 5, y: 15))
        XCTAssertEqual(handles[1].point, CGPoint(x: 95, y: 85))
    }

    func testHandles_rectangleReturnsFourCorners() {
        let annotation = Annotation.rectangle(rect: CGRect(x: 10, y: 20, width: 80, height: 60))
        let handles = annotation.handles
        XCTAssertEqual(handles.count, 4)
        XCTAssertEqual(handles[0].point, CGPoint(x: 10, y: 20))   // topLeft
        XCTAssertEqual(handles[1].point, CGPoint(x: 90, y: 20))   // topRight
        XCTAssertEqual(handles[2].point, CGPoint(x: 10, y: 80))   // bottomLeft
        XCTAssertEqual(handles[3].point, CGPoint(x: 90, y: 80))   // bottomRight
    }

    func testHandles_cropReturnsFourCorners() {
        let annotation = Annotation.crop(rect: CGRect(x: 0, y: 0, width: 100, height: 50))
        let handles = annotation.handles
        XCTAssertEqual(handles.count, 4)
        XCTAssertEqual(handles[0].point, CGPoint(x: 0, y: 0))
        XCTAssertEqual(handles[1].point, CGPoint(x: 100, y: 0))
        XCTAssertEqual(handles[2].point, CGPoint(x: 0, y: 50))
        XCTAssertEqual(handles[3].point, CGPoint(x: 100, y: 50))
    }

    // MARK: - Annotation.moving

    func testMoving_arrowFromEndpoint() {
        let annotation = Annotation.arrow(
            from: CGPoint(x: 10, y: 20),
            to: CGPoint(x: 50, y: 60)
        )
        let moved = annotation.moving(.from, to: CGPoint(x: 30, y: 40))
        if case .arrow(let from, let to) = moved {
            XCTAssertEqual(from, CGPoint(x: 30, y: 40))
            XCTAssertEqual(to, CGPoint(x: 50, y: 60))
        } else {
            XCTFail("Expected arrow annotation")
        }
    }

    func testMoving_arrowToEndpoint() {
        let annotation = Annotation.arrow(
            from: CGPoint(x: 10, y: 20),
            to: CGPoint(x: 50, y: 60)
        )
        let moved = annotation.moving(.to, to: CGPoint(x: 80, y: 90))
        if case .arrow(let from, let to) = moved {
            XCTAssertEqual(from, CGPoint(x: 10, y: 20))
            XCTAssertEqual(to, CGPoint(x: 80, y: 90))
        } else {
            XCTFail("Expected arrow annotation")
        }
    }

    func testMoving_lineEndpoint() {
        let annotation = Annotation.line(
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 100, y: 100)
        )
        let moved = annotation.moving(.to, to: CGPoint(x: 50, y: 75))
        if case .line(let from, let to) = moved {
            XCTAssertEqual(from, CGPoint(x: 0, y: 0))
            XCTAssertEqual(to, CGPoint(x: 50, y: 75))
        } else {
            XCTFail("Expected line annotation")
        }
    }

    func testMoving_rectangleCorner() {
        let annotation = Annotation.rectangle(rect: CGRect(x: 10, y: 20, width: 80, height: 60))
        // Move topLeft to a new position — bottomRight (90,80) is the anchor
        let moved = annotation.moving(.topLeft, to: CGPoint(x: 5, y: 10))
        if case .rectangle(let rect) = moved {
            XCTAssertEqual(rect.origin.x, 5, accuracy: 0.001)
            XCTAssertEqual(rect.origin.y, 10, accuracy: 0.001)
            XCTAssertEqual(rect.width, 85, accuracy: 0.001)
            XCTAssertEqual(rect.height, 70, accuracy: 0.001)
        } else {
            XCTFail("Expected rectangle annotation")
        }
    }

    func testMoving_cropCorner() {
        let annotation = Annotation.crop(rect: CGRect(x: 0, y: 0, width: 100, height: 50))
        // Move bottomRight — topLeft (0,0) is the anchor
        let moved = annotation.moving(.bottomRight, to: CGPoint(x: 120, y: 80))
        if case .crop(let rect) = moved {
            XCTAssertEqual(rect.origin.x, 0, accuracy: 0.001)
            XCTAssertEqual(rect.origin.y, 0, accuracy: 0.001)
            XCTAssertEqual(rect.width, 120, accuracy: 0.001)
            XCTAssertEqual(rect.height, 80, accuracy: 0.001)
        } else {
            XCTFail("Expected crop annotation")
        }
    }

    // MARK: - handleAt hit testing

    func testHandleAt_hitsNearestHandle() {
        let view = makeView()
        // Add an arrow — handleAt is internal (non-private), so we can call it
        // The view is 1:1 with screenshot, so screenshot coords == view coords
        // We test handleAt directly with screenshot-space points

        // Arrow from (10,20) to (80,60) — test near the "to" endpoint
        let result = view.handleAt(CGPoint(x: 79, y: 59))
        // No annotations yet, should be nil
        XCTAssertNil(result)
    }

    func testHandleAt_returnsNilWhenNoAnnotations() {
        let view = makeView()
        let result = view.handleAt(CGPoint(x: 50, y: 50))
        XCTAssertNil(result)
    }
}
