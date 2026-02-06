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

    func testMoving_lineFromEndpoint() {
        let annotation = Annotation.line(
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 100, y: 100)
        )
        let moved = annotation.moving(.from, to: CGPoint(x: 25, y: 30))
        if case .line(let from, let to) = moved {
            XCTAssertEqual(from, CGPoint(x: 25, y: 30))
            XCTAssertEqual(to, CGPoint(x: 100, y: 100))
        } else {
            XCTFail("Expected line annotation")
        }
    }

    func testMoving_lineToEndpoint() {
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

    func testMoving_rectangleTopLeft() {
        let annotation = Annotation.rectangle(rect: CGRect(x: 10, y: 20, width: 80, height: 60))
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

    func testMoving_rectangleTopRight() {
        let annotation = Annotation.rectangle(rect: CGRect(x: 10, y: 20, width: 80, height: 60))
        // Anchor is bottomLeft (10, 80)
        let moved = annotation.moving(.topRight, to: CGPoint(x: 100, y: 15))
        if case .rectangle(let rect) = moved {
            XCTAssertEqual(rect.origin.x, 10, accuracy: 0.001)
            XCTAssertEqual(rect.origin.y, 15, accuracy: 0.001)
            XCTAssertEqual(rect.width, 90, accuracy: 0.001)
            XCTAssertEqual(rect.height, 65, accuracy: 0.001)
        } else {
            XCTFail("Expected rectangle annotation")
        }
    }

    func testMoving_rectangleBottomLeft() {
        let annotation = Annotation.rectangle(rect: CGRect(x: 10, y: 20, width: 80, height: 60))
        // Anchor is topRight (90, 20)
        let moved = annotation.moving(.bottomLeft, to: CGPoint(x: 0, y: 90))
        if case .rectangle(let rect) = moved {
            XCTAssertEqual(rect.origin.x, 0, accuracy: 0.001)
            XCTAssertEqual(rect.origin.y, 20, accuracy: 0.001)
            XCTAssertEqual(rect.width, 90, accuracy: 0.001)
            XCTAssertEqual(rect.height, 70, accuracy: 0.001)
        } else {
            XCTFail("Expected rectangle annotation")
        }
    }

    func testMoving_rectangleBottomRight() {
        let annotation = Annotation.rectangle(rect: CGRect(x: 10, y: 20, width: 80, height: 60))
        // Anchor is topLeft (10, 20)
        let moved = annotation.moving(.bottomRight, to: CGPoint(x: 95, y: 85))
        if case .rectangle(let rect) = moved {
            XCTAssertEqual(rect.origin.x, 10, accuracy: 0.001)
            XCTAssertEqual(rect.origin.y, 20, accuracy: 0.001)
            XCTAssertEqual(rect.width, 85, accuracy: 0.001)
            XCTAssertEqual(rect.height, 65, accuracy: 0.001)
        } else {
            XCTFail("Expected rectangle annotation")
        }
    }

    func testMoving_rectangleFlipsPastOppositeCorner() {
        let annotation = Annotation.rectangle(rect: CGRect(x: 10, y: 20, width: 80, height: 60))
        // Drag topLeft past bottomRight — rect should flip correctly
        let moved = annotation.moving(.topLeft, to: CGPoint(x: 100, y: 90))
        if case .rectangle(let rect) = moved {
            XCTAssertEqual(rect.origin.x, 90, accuracy: 0.001)
            XCTAssertEqual(rect.origin.y, 80, accuracy: 0.001)
            XCTAssertEqual(rect.width, 10, accuracy: 0.001)
            XCTAssertEqual(rect.height, 10, accuracy: 0.001)
        } else {
            XCTFail("Expected rectangle annotation")
        }
    }

    func testMoving_cropCorner() {
        let annotation = Annotation.crop(rect: CGRect(x: 0, y: 0, width: 100, height: 50))
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

    func testHandleAt_returnsNilWhenNoAnnotations() {
        let view = makeView()
        let result = view.handleAt(CGPoint(x: 50, y: 50))
        XCTAssertNil(result)
    }

    func testHandleAt_hitsArrowToEndpoint() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 80, y: 60))
        ])
        // Click near the "to" endpoint (within 10pt radius at 1:1 scale)
        let result = view.handleAt(CGPoint(x: 78, y: 58))
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.index, 0)
        if case .to = result?.handle {} else { XCTFail("Expected .to handle") }
    }

    func testHandleAt_hitsArrowFromEndpoint() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 80, y: 60))
        ])
        let result = view.handleAt(CGPoint(x: 12, y: 22))
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.index, 0)
        if case .from = result?.handle {} else { XCTFail("Expected .from handle") }
    }

    func testHandleAt_missesWhenFarFromHandle() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 80, y: 60))
        ])
        // Click far from both endpoints
        let result = view.handleAt(CGPoint(x: 50, y: 50))
        XCTAssertNil(result)
    }

    func testHandleAt_hitsRectangleCorner() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .rectangle(rect: CGRect(x: 20, y: 20, width: 60, height: 40))
        ])
        // Click near bottomRight (80, 60)
        let result = view.handleAt(CGPoint(x: 79, y: 59))
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.index, 0)
        if case .bottomRight = result?.handle {} else {
            XCTFail("Expected .bottomRight handle")
        }
    }

    func testHandleAt_prefersTopmostAnnotation() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .arrow(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 90, y: 90)),
            .arrow(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 10, y: 10))
        ])
        // Both annotations share the "from" point (50,50)
        // Topmost (index 1) should win
        let result = view.handleAt(CGPoint(x: 50, y: 50))
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.index, 1)
    }

    func testHandleAt_picksNearestHandleOnSameAnnotation() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .arrow(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 30, y: 50))
        ])
        // Closer to "to" (30,50) than "from" (10,50)
        let result = view.handleAt(CGPoint(x: 27, y: 50))
        XCTAssertNotNil(result)
        if case .to = result?.handle {} else { XCTFail("Expected .to handle") }
    }

    // MARK: - Text annotation handles

    func testHandles_textReturnsTwoMidpoints() {
        let annotation = Annotation.text(
            origin: CGPoint(x: 50, y: 100), width: 300, content: "Hello", fontSize: 24
        )
        let handles = annotation.handles
        XCTAssertEqual(handles.count, 2)

        let rect = Annotation.textBoundingRect(
            origin: CGPoint(x: 50, y: 100), width: 300, content: "Hello", fontSize: 24
        )
        XCTAssertEqual(handles[0].point.x, rect.minX, accuracy: 0.001)
        XCTAssertEqual(handles[0].point.y, rect.midY, accuracy: 0.001)
        XCTAssertEqual(handles[1].point.x, rect.maxX, accuracy: 0.001)
        XCTAssertEqual(handles[1].point.y, rect.midY, accuracy: 0.001)

        if case .left = handles[0].handle {} else { XCTFail("Expected .left handle") }
        if case .right = handles[1].handle {} else { XCTFail("Expected .right handle") }
    }

    func testMoving_textRightHandle() {
        let annotation = Annotation.text(
            origin: CGPoint(x: 50, y: 100), width: 300, content: "Hello", fontSize: 24
        )
        let moved = annotation.moving(.right, to: CGPoint(x: 400, y: 120))
        if case .text(let origin, let width, _, _) = moved {
            XCTAssertEqual(origin.x, 50, accuracy: 0.001)
            XCTAssertEqual(width, 350, accuracy: 0.001) // 400 - 50
        } else {
            XCTFail("Expected text annotation")
        }
    }

    func testMoving_textLeftHandle() {
        let annotation = Annotation.text(
            origin: CGPoint(x: 50, y: 100), width: 300, content: "Hello", fontSize: 24
        )
        // Right edge is at 350. Move left handle to x=100
        let moved = annotation.moving(.left, to: CGPoint(x: 100, y: 120))
        if case .text(let origin, let width, _, _) = moved {
            XCTAssertEqual(origin.x, 100, accuracy: 0.001)
            XCTAssertEqual(width, 250, accuracy: 0.001) // 350 - 100
        } else {
            XCTFail("Expected text annotation")
        }
    }

    func testMoving_textMinimumWidth() {
        let annotation = Annotation.text(
            origin: CGPoint(x: 50, y: 100), width: 300, content: "Hello", fontSize: 24
        )
        // Move right handle very close to origin
        let moved = annotation.moving(.right, to: CGPoint(x: 55, y: 120))
        if case .text(_, let width, _, _) = moved {
            XCTAssertEqual(width, 20, accuracy: 0.001) // clamped to minimum
        } else {
            XCTFail("Expected text annotation")
        }
    }

    // MARK: - textAnnotationAt hit testing

    func testTextAnnotationAt_hitsTextBounds() {
        let view = makeView(imageSize: NSSize(width: 800, height: 600))
        view.setAnnotations(forTesting: [
            .text(origin: CGPoint(x: 100, y: 100), width: 300, content: "Hello", fontSize: 24)
        ])
        let result = view.textAnnotationAt(CGPoint(x: 150, y: 110))
        XCTAssertEqual(result, 0)
    }

    func testTextAnnotationAt_missesOutsideBounds() {
        let view = makeView(imageSize: NSSize(width: 800, height: 600))
        view.setAnnotations(forTesting: [
            .text(origin: CGPoint(x: 100, y: 100), width: 300, content: "Hello", fontSize: 24)
        ])
        let result = view.textAnnotationAt(CGPoint(x: 50, y: 50))
        XCTAssertNil(result)
    }

    func testTextAnnotationAt_prefersTopmostText() {
        let view = makeView(imageSize: NSSize(width: 800, height: 600))
        view.setAnnotations(forTesting: [
            .text(origin: CGPoint(x: 100, y: 100), width: 300, content: "First", fontSize: 24),
            .text(origin: CGPoint(x: 100, y: 100), width: 300, content: "Second", fontSize: 24)
        ])
        // Both overlap at (150, 110) — topmost (index 1) should win
        let result = view.textAnnotationAt(CGPoint(x: 150, y: 110))
        XCTAssertEqual(result, 1)
    }

    // MARK: - textBoundingRect

    func testTextBoundingRect_nonEmpty() {
        let rect = Annotation.textBoundingRect(
            origin: CGPoint(x: 10, y: 20), width: 200, content: "Hello World", fontSize: 24
        )
        XCTAssertGreaterThan(rect.height, 0)
        XCTAssertEqual(rect.origin.x, 10, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 20, accuracy: 0.001)
        XCTAssertEqual(rect.width, 200, accuracy: 0.001)
    }

    func testTextBoundingRect_empty() {
        let rect = Annotation.textBoundingRect(
            origin: CGPoint(x: 10, y: 20), width: 200, content: "", fontSize: 24
        )
        // Minimum height = fontSize * 1.5 = 36
        XCTAssertGreaterThanOrEqual(rect.height, 36)
    }

    // MARK: - Annotation.offsetBy

    func testOffsetBy_arrow() {
        let a = Annotation.arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 50, y: 60))
        let moved = a.offsetBy(dx: 5, dy: -10)
        if case .arrow(let from, let to) = moved {
            XCTAssertEqual(from, CGPoint(x: 15, y: 10))
            XCTAssertEqual(to, CGPoint(x: 55, y: 50))
        } else { XCTFail("Expected arrow") }
    }

    func testOffsetBy_rectangle() {
        let a = Annotation.rectangle(rect: CGRect(x: 10, y: 20, width: 80, height: 60))
        let moved = a.offsetBy(dx: -5, dy: 15)
        if case .rectangle(let rect) = moved {
            XCTAssertEqual(rect, CGRect(x: 5, y: 35, width: 80, height: 60))
        } else { XCTFail("Expected rectangle") }
    }

    // MARK: - annotationBodyAt hit testing

    func testAnnotationBodyAt_hitsArrowLine() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .arrow(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 100, y: 50))
        ])
        // Point on the line
        let result = view.annotationBodyAt(CGPoint(x: 50, y: 50))
        XCTAssertEqual(result, 0)
    }

    func testAnnotationBodyAt_missesArrowFarAway() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 10))
        ])
        let result = view.annotationBodyAt(CGPoint(x: 50, y: 80))
        XCTAssertNil(result)
    }

    func testAnnotationBodyAt_hitsRectangleInterior() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .rectangle(rect: CGRect(x: 20, y: 20, width: 60, height: 40))
        ])
        let result = view.annotationBodyAt(CGPoint(x: 50, y: 40))
        XCTAssertEqual(result, 0)
    }

    func testAnnotationBodyAt_prefersTopmostAnnotation() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .rectangle(rect: CGRect(x: 20, y: 20, width: 60, height: 40)),
            .rectangle(rect: CGRect(x: 30, y: 30, width: 40, height: 20))
        ])
        let result = view.annotationBodyAt(CGPoint(x: 50, y: 40))
        XCTAssertEqual(result, 1)
    }
}
