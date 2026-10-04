import XCTest
@testable import Skryn

final class AnnotationViewTests: XCTestCase {

    // MARK: - rectFromDrag

    private func makeView(imageSize: NSSize = NSSize(width: 200, height: 100)) -> AnnotationView {
        let image = NSImage(size: imageSize)
        return AnnotationView(frame: NSRect(origin: .zero, size: imageSize), screenshot: image)
    }

    private func withModifierDefaults(_ values: [String: String], _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let keys = ["modifierLocal", "modifierClipboard", "modifierCloud"]
        let savedValues = keys.map { ($0, defaults.object(forKey: $0)) }

        for key in keys {
            if let value = values[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defer {
            for (key, value) in savedValues {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        body()
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
        let view = AnnotationView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), screenshot: image)
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

    // MARK: - Annotation.moving

    func testMoving_rectangleTopLeft() {
        let annotation = Annotation.rectangle(rect: CGRect(x: 10, y: 20, width: 80, height: 60), color: .red)
        let moved = annotation.moving(.topLeft, to: CGPoint(x: 5, y: 10))
        if case .rectangle(let rect, _) = moved {
            XCTAssertEqual(rect.origin.x, 5, accuracy: 0.001)
            XCTAssertEqual(rect.origin.y, 10, accuracy: 0.001)
            XCTAssertEqual(rect.width, 85, accuracy: 0.001)
            XCTAssertEqual(rect.height, 70, accuracy: 0.001)
        } else {
            XCTFail("Expected rectangle annotation")
        }
    }

    func testMoving_rectangleTopRight() {
        let annotation = Annotation.rectangle(rect: CGRect(x: 10, y: 20, width: 80, height: 60), color: .red)
        // Anchor is bottomLeft (10, 80)
        let moved = annotation.moving(.topRight, to: CGPoint(x: 100, y: 15))
        if case .rectangle(let rect, _) = moved {
            XCTAssertEqual(rect.origin.x, 10, accuracy: 0.001)
            XCTAssertEqual(rect.origin.y, 15, accuracy: 0.001)
            XCTAssertEqual(rect.width, 90, accuracy: 0.001)
            XCTAssertEqual(rect.height, 65, accuracy: 0.001)
        } else {
            XCTFail("Expected rectangle annotation")
        }
    }

    func testMoving_rectangleBottomLeft() {
        let annotation = Annotation.rectangle(rect: CGRect(x: 10, y: 20, width: 80, height: 60), color: .red)
        // Anchor is topRight (90, 20)
        let moved = annotation.moving(.bottomLeft, to: CGPoint(x: 0, y: 90))
        if case .rectangle(let rect, _) = moved {
            XCTAssertEqual(rect.origin.x, 0, accuracy: 0.001)
            XCTAssertEqual(rect.origin.y, 20, accuracy: 0.001)
            XCTAssertEqual(rect.width, 90, accuracy: 0.001)
            XCTAssertEqual(rect.height, 70, accuracy: 0.001)
        } else {
            XCTFail("Expected rectangle annotation")
        }
    }

    func testMoving_rectangleBottomRight() {
        let annotation = Annotation.rectangle(rect: CGRect(x: 10, y: 20, width: 80, height: 60), color: .red)
        // Anchor is topLeft (10, 20)
        let moved = annotation.moving(.bottomRight, to: CGPoint(x: 95, y: 85))
        if case .rectangle(let rect, _) = moved {
            XCTAssertEqual(rect.origin.x, 10, accuracy: 0.001)
            XCTAssertEqual(rect.origin.y, 20, accuracy: 0.001)
            XCTAssertEqual(rect.width, 85, accuracy: 0.001)
            XCTAssertEqual(rect.height, 65, accuracy: 0.001)
        } else {
            XCTFail("Expected rectangle annotation")
        }
    }

    func testMoving_rectangleFlipsPastOppositeCorner() {
        let annotation = Annotation.rectangle(rect: CGRect(x: 10, y: 20, width: 80, height: 60), color: .red)
        // Drag topLeft past bottomRight — rect should flip correctly
        let moved = annotation.moving(.topLeft, to: CGPoint(x: 100, y: 90))
        if case .rectangle(let rect, _) = moved {
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
            .arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 80, y: 60), color: .red)
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
            .arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 80, y: 60), color: .red)
        ])
        let result = view.handleAt(CGPoint(x: 12, y: 22))
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.index, 0)
        if case .from = result?.handle {} else { XCTFail("Expected .from handle") }
    }

    func testHandleAt_missesWhenFarFromHandle() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 80, y: 60), color: .red)
        ])
        // Click far from both endpoints
        let result = view.handleAt(CGPoint(x: 50, y: 50))
        XCTAssertNil(result)
    }

    func testHandleAt_hitsRectangleCorner() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .rectangle(rect: CGRect(x: 20, y: 20, width: 60, height: 40), color: .red)
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
            .arrow(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 90, y: 90), color: .red),
            .arrow(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 10, y: 10), color: .red)
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
            .arrow(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 30, y: 50), color: .red)
        ])
        // Closer to "to" (30,50) than "from" (10,50)
        let result = view.handleAt(CGPoint(x: 27, y: 50))
        XCTAssertNotNil(result)
        if case .to = result?.handle {} else { XCTFail("Expected .to handle") }
    }

    // MARK: - Text annotation handles

    func testHandles_textReturnsTwoMidpoints() {
        let annotation = Annotation.text(
            origin: CGPoint(x: 50, y: 100), width: 300, content: "Hello", fontSize: 24, color: .red
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
            origin: CGPoint(x: 50, y: 100), width: 300, content: "Hello", fontSize: 24, color: .red
        )
        let moved = annotation.moving(.right, to: CGPoint(x: 400, y: 120))
        if case .text(let origin, let width, _, _, _) = moved {
            XCTAssertEqual(origin.x, 50, accuracy: 0.001)
            XCTAssertEqual(width, 350, accuracy: 0.001) // 400 - 50
        } else {
            XCTFail("Expected text annotation")
        }
    }

    func testMoving_textLeftHandle() {
        let annotation = Annotation.text(
            origin: CGPoint(x: 50, y: 100), width: 300, content: "Hello", fontSize: 24, color: .red
        )
        // Right edge is at 350. Move left handle to x=100
        let moved = annotation.moving(.left, to: CGPoint(x: 100, y: 120))
        if case .text(let origin, let width, _, _, _) = moved {
            XCTAssertEqual(origin.x, 100, accuracy: 0.001)
            XCTAssertEqual(width, 250, accuracy: 0.001) // 350 - 100
        } else {
            XCTFail("Expected text annotation")
        }
    }

    func testMoving_textMinimumWidth() {
        let annotation = Annotation.text(
            origin: CGPoint(x: 50, y: 100), width: 300, content: "Hello", fontSize: 24, color: .red
        )
        // Move right handle very close to origin
        let moved = annotation.moving(.right, to: CGPoint(x: 55, y: 120))
        if case .text(_, let width, _, _, _) = moved {
            XCTAssertEqual(width, 20, accuracy: 0.001) // clamped to minimum
        } else {
            XCTFail("Expected text annotation")
        }
    }

    // MARK: - Text body hit testing

    func testAnnotationBodyAt_text_hitsTextBounds() {
        let view = makeView(imageSize: NSSize(width: 800, height: 600))
        view.setAnnotations(forTesting: [
            .text(origin: CGPoint(x: 100, y: 100), width: 300, content: "Hello", fontSize: 24, color: .red)
        ])
        let result = view.annotationBodyAt(CGPoint(x: 150, y: 110))
        XCTAssertEqual(result, 0)
    }

    func testAnnotationBodyAt_text_missesOutsideBounds() {
        let view = makeView(imageSize: NSSize(width: 800, height: 600))
        view.setAnnotations(forTesting: [
            .text(origin: CGPoint(x: 100, y: 100), width: 300, content: "Hello", fontSize: 24, color: .red)
        ])
        let result = view.annotationBodyAt(CGPoint(x: 50, y: 50))
        XCTAssertNil(result)
    }

    func testAnnotationBodyAt_text_prefersTopmostText() {
        let view = makeView(imageSize: NSSize(width: 800, height: 600))
        view.setAnnotations(forTesting: [
            .text(origin: CGPoint(x: 100, y: 100), width: 300, content: "First", fontSize: 24, color: .red),
            .text(origin: CGPoint(x: 100, y: 100), width: 300, content: "Second", fontSize: 24, color: .red)
        ])
        // Both overlap at (150, 110) — topmost (index 1) should win
        let result = view.annotationBodyAt(CGPoint(x: 150, y: 110))
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

    // MARK: - steppedFontSize

    func testSteppedFontSize_stepsAlongScale() {
        XCTAssertEqual(Annotation.steppedFontSize(24, larger: true), 32)
        XCTAssertEqual(Annotation.steppedFontSize(24, larger: false), 20)
    }

    func testSteppedFontSize_clampsAtEnds() {
        XCTAssertEqual(Annotation.steppedFontSize(128, larger: true), 128)
        XCTAssertEqual(Annotation.steppedFontSize(12, larger: false), 12)
    }

    func testSteppedFontSize_offScaleSnapsToNeighbor() {
        XCTAssertEqual(Annotation.steppedFontSize(26, larger: true), 32)
        XCTAssertEqual(Annotation.steppedFontSize(26, larger: false), 24)
    }

    // MARK: - annotationBodyAt hit testing

    func testAnnotationBodyAt_hitsArrowLine() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .arrow(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 100, y: 50), color: .red)
        ])
        // Point on the line
        let result = view.annotationBodyAt(CGPoint(x: 50, y: 50))
        XCTAssertEqual(result, 0)
    }

    func testAnnotationBodyAt_missesArrowFarAway() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 10), color: .red)
        ])
        let result = view.annotationBodyAt(CGPoint(x: 50, y: 80))
        XCTAssertNil(result)
    }

    func testAnnotationBodyAt_hitsRectangleEdge() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .rectangle(rect: CGRect(x: 20, y: 20, width: 60, height: 40), color: .red)
        ])
        // Near the left edge (x = 20), between corner handles
        XCTAssertEqual(view.annotationBodyAt(CGPoint(x: 22, y: 40)), 0)
        // Just outside the top edge (y = 20)
        XCTAssertEqual(view.annotationBodyAt(CGPoint(x: 50, y: 17)), 0)
    }

    func testAnnotationBodyAt_missesRectangleInterior() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .rectangle(rect: CGRect(x: 20, y: 20, width: 60, height: 40), color: .red)
        ])
        XCTAssertNil(view.annotationBodyAt(CGPoint(x: 50, y: 40)))
    }

    func testAnnotationBodyAt_missesCropInterior() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .crop(rect: CGRect(x: 20, y: 20, width: 160, height: 60))
        ])
        XCTAssertNil(view.annotationBodyAt(CGPoint(x: 100, y: 50)))
        XCTAssertEqual(view.annotationBodyAt(CGPoint(x: 100, y: 79)), 0)
    }

    func testAnnotationBodyAt_arrowInsideRectangleIsReachable() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .arrow(from: CGPoint(x: 30, y: 40), to: CGPoint(x: 70, y: 40), color: .red),
            .rectangle(rect: CGRect(x: 20, y: 20, width: 60, height: 40), color: .red)
        ])
        // Rectangle is topmost, but its interior no longer shadows the arrow
        XCTAssertEqual(view.annotationBodyAt(CGPoint(x: 50, y: 40)), 0)
    }

    func testAnnotationBodyAt_prefersTopmostAnnotation() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .rectangle(rect: CGRect(x: 20, y: 20, width: 60, height: 40), color: .red),
            .rectangle(rect: CGRect(x: 20, y: 20, width: 60, height: 40), color: .blue)
        ])
        let result = view.annotationBodyAt(CGPoint(x: 21, y: 40))
        XCTAssertEqual(result, 1)
    }

    // MARK: - Blur annotation

    func testMoving_blurTopLeft() {
        let annotation = Annotation.blur(rect: CGRect(x: 10, y: 20, width: 80, height: 60))
        let moved = annotation.moving(.topLeft, to: CGPoint(x: 5, y: 10))
        if case .blur(let rect) = moved {
            XCTAssertEqual(rect.origin.x, 5, accuracy: 0.001)
            XCTAssertEqual(rect.origin.y, 10, accuracy: 0.001)
            XCTAssertEqual(rect.width, 85, accuracy: 0.001)
            XCTAssertEqual(rect.height, 70, accuracy: 0.001)
        } else {
            XCTFail("Expected blur annotation")
        }
    }

    func testOffsetBy_blur() {
        let annotation = Annotation.blur(rect: CGRect(x: 10, y: 20, width: 80, height: 60))
        let moved = annotation.offsetBy(dx: 5, dy: -10)
        if case .blur(let rect) = moved {
            XCTAssertEqual(rect.origin.x, 15, accuracy: 0.001)
            XCTAssertEqual(rect.origin.y, 10, accuracy: 0.001)
            XCTAssertEqual(rect.width, 80, accuracy: 0.001)
            XCTAssertEqual(rect.height, 60, accuracy: 0.001)
        } else {
            XCTFail("Expected blur annotation")
        }
    }

    func testHandleAt_blur() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .blur(rect: CGRect(x: 20, y: 20, width: 60, height: 40))
        ])
        // Click near bottomRight (80, 60)
        let result = view.handleAt(CGPoint(x: 79, y: 59))
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.index, 0)
        if case .bottomRight = result?.handle {} else {
            XCTFail("Expected .bottomRight handle")
        }
    }

    func testAnnotationBodyAt_blur() {
        let view = makeView()
        view.setAnnotations(forTesting: [
            .blur(rect: CGRect(x: 20, y: 20, width: 60, height: 40))
        ])
        let result = view.annotationBodyAt(CGPoint(x: 50, y: 40))
        XCTAssertEqual(result, 0)
    }

    // MARK: - Ellipse annotation

    func testMoving_ellipseBottomRight() {
        let annotation = Annotation.ellipse(rect: CGRect(x: 10, y: 20, width: 80, height: 60), color: .red)
        let moved = annotation.moving(.bottomRight, to: CGPoint(x: 100, y: 90))
        if case .ellipse(let rect, let color) = moved {
            XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 90, height: 70))
            XCTAssertEqual(color, .red)
        } else {
            XCTFail("Expected ellipse annotation")
        }
    }

    func testEllipse_handlesAreFourCorners() {
        let annotation = Annotation.ellipse(rect: CGRect(x: 10, y: 20, width: 80, height: 60), color: .red)
        XCTAssertEqual(annotation.handles.count, 4)
    }

    func testBodyContains_ellipseOutlineHits() {
        let annotation = Annotation.ellipse(rect: CGRect(x: 20, y: 20, width: 60, height: 40), color: .red)
        // Leftmost point of the outline, and just inside/outside it
        XCTAssertTrue(annotation.bodyContains(CGPoint(x: 20, y: 40), hitRadius: 5))
        XCTAssertTrue(annotation.bodyContains(CGPoint(x: 23, y: 40), hitRadius: 5))
        XCTAssertTrue(annotation.bodyContains(CGPoint(x: 17, y: 40), hitRadius: 5))
    }

    func testBodyContains_ellipseCenterMisses() {
        let annotation = Annotation.ellipse(rect: CGRect(x: 20, y: 20, width: 60, height: 40), color: .red)
        XCTAssertFalse(annotation.bodyContains(CGPoint(x: 50, y: 40), hitRadius: 5))
    }

    func testBodyContains_ellipseCornerMisses() {
        // Rect corner is outside the inscribed ellipse
        let annotation = Annotation.ellipse(rect: CGRect(x: 20, y: 20, width: 60, height: 40), color: .red)
        XCTAssertFalse(annotation.bodyContains(CGPoint(x: 21, y: 21), hitRadius: 0))
    }

    func testOffsetBy_ellipse() {
        let annotation = Annotation.ellipse(rect: CGRect(x: 10, y: 20, width: 80, height: 60), color: .blue)
        let moved = annotation.offsetBy(dx: 5, dy: -10)
        if case .ellipse(let rect, let color) = moved {
            XCTAssertEqual(rect, CGRect(x: 15, y: 10, width: 80, height: 60))
            XCTAssertEqual(color, .blue)
        } else {
            XCTFail("Expected ellipse annotation")
        }
    }

    // MARK: - Badge annotation

    func testBadge_hasNoHandles() {
        let annotation = Annotation.badge(center: CGPoint(x: 50, y: 50), number: 3, color: .red)
        XCTAssertTrue(annotation.handles.isEmpty)
    }

    func testBadge_movingHandleIsNoOp() {
        let annotation = Annotation.badge(center: CGPoint(x: 50, y: 50), number: 3, color: .red)
        XCTAssertEqual(annotation.moving(.topLeft, to: CGPoint(x: 0, y: 0)), annotation)
    }

    func testBodyContains_badgeInsideRadius() {
        let annotation = Annotation.badge(center: CGPoint(x: 50, y: 50), number: 3, color: .red)
        XCTAssertTrue(annotation.bodyContains(CGPoint(x: 50 + Annotation.badgeRadius, y: 50), hitRadius: 0))
        XCTAssertFalse(annotation.bodyContains(
            CGPoint(x: 50 + Annotation.badgeRadius + 1, y: 50), hitRadius: 0
        ))
    }

    func testOffsetBy_badge() {
        let annotation = Annotation.badge(center: CGPoint(x: 50, y: 50), number: 12, color: .blue)
        let moved = annotation.offsetBy(dx: 10, dy: -5)
        XCTAssertEqual(moved, .badge(center: CGPoint(x: 60, y: 45), number: 12, color: .blue))
    }

    // MARK: - Color

    func testAnnotationColor_toggled() {
        XCTAssertEqual(AnnotationColor.red.toggled, .blue)
        XCTAssertEqual(AnnotationColor.blue.toggled, .red)
    }

    func testWithColor_changesColorBearingTypes() {
        let arrow = Annotation.arrow(from: .zero, to: CGPoint(x: 10, y: 10), color: .red)
        XCTAssertEqual(arrow.withColor(.blue).color, .blue)

        let badge = Annotation.badge(center: .zero, number: 1, color: .red)
        XCTAssertEqual(badge.withColor(.blue).color, .blue)

        let text = Annotation.text(origin: .zero, width: 100, content: "Hi", fontSize: 24, color: .red)
        XCTAssertEqual(text.withColor(.blue).color, .blue)
    }

    func testWithColor_colorlessTypesUnchanged() {
        let crop = Annotation.crop(rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertNil(crop.color)
        XCTAssertEqual(crop.withColor(.blue), crop)

        let blur = Annotation.blur(rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertNil(blur.color)
        XCTAssertEqual(blur.withColor(.blue), blur)
    }

    // MARK: - SaveAction modifier mapping

    func testSaveActionMapping_defaultModifiers() {
        withModifierDefaults([:]) {
            XCTAssertEqual(SaveAction.action(for: .command), .clipboard)
            XCTAssertEqual(SaveAction.action(for: .option), .local)
            XCTAssertEqual(SaveAction.action(for: .control), .cloud)
        }
    }

    func testSaveActionMapping_customModifiers() {
        withModifierDefaults([
            "modifierLocal": "opt",
            "modifierClipboard": "ctrl",
            "modifierCloud": "cmd"
        ]) {
            XCTAssertEqual(SaveAction.action(for: .option), .local)
            XCTAssertEqual(SaveAction.action(for: .control), .clipboard)
            XCTAssertEqual(SaveAction.action(for: .command), .cloud)
        }
    }

    func testSaveActionMapping_multipleModifiers_returnsNil() {
        withModifierDefaults([:]) {
            let combined: NSEvent.ModifierFlags = [.command, .option]
            XCTAssertNil(SaveAction.action(for: combined))
        }
    }
}

// MARK: - Screen recording geometry

@MainActor
final class ScreenRecordingGeometryTests: XCTestCase {
    private let screen = CGSize(width: 1000, height: 800)

    func testSelectionRect_flipsToTopLeftOrigin() {
        let rect = SelectionOverlay.selectionRect(
            from: NSPoint(x: 10, y: 790), to: NSPoint(x: 110, y: 690), in: screen
        )
        XCTAssertEqual(rect, CGRect(x: 10, y: 10, width: 100, height: 100))
    }

    func testSelectionRect_reversedDrag_sameRect() {
        let rect = SelectionOverlay.selectionRect(
            from: NSPoint(x: 110, y: 690), to: NSPoint(x: 10, y: 790), in: screen
        )
        XCTAssertEqual(rect, CGRect(x: 10, y: 10, width: 100, height: 100))
    }

    func testSelectionRect_tinyDrag_selectsWholeScreen() {
        let rect = SelectionOverlay.selectionRect(from: NSPoint(x: 5, y: 5), to: NSPoint(x: 7, y: 7), in: screen)
        XCTAssertEqual(rect, CGRect(origin: .zero, size: screen))
    }

    func testSelectionRect_clampsToScreen() {
        let rect = SelectionOverlay.selectionRect(
            from: NSPoint(x: -50, y: -50), to: NSPoint(x: 100, y: 100), in: screen
        )
        XCTAssertEqual(rect, CGRect(x: 0, y: 700, width: 100, height: 100))
    }

    @available(macOS 15.0, *)
    func testOutputPixelSize_scalesAndRoundsToEven() throws {
        let size = ScreenRecorder.outputPixelSize(for: CGRect(x: 0, y: 0, width: 101.5, height: 51), scale: 2)
        XCTAssertEqual(size.width, 202)
        XCTAssertEqual(size.height, 102)

        let odd = ScreenRecorder.outputPixelSize(for: CGRect(x: 0, y: 0, width: 101, height: 51), scale: 1)
        XCTAssertEqual(odd.width, 100)
        XCTAssertEqual(odd.height, 50)
    }
}
