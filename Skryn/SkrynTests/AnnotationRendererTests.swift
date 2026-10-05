import AppKit
import XCTest
@testable import Skryn

final class AnnotationRendererTests: XCTestCase {
    /// 200×100pt at 2x: export keeps the pixel resolution and cuts to the crop (in points)
    func testRender_fullResolutionAndCrop() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: NSSize(width: 200, height: 100))
        let renderer = AnnotationRenderer(screenshot: image)
        XCTAssertEqual(renderer.pixelsPerPoint, 2)

        let full = try XCTUnwrap(renderer.render([.arrow(from: .zero, to: CGPoint(x: 50, y: 50), color: .red)]))
        XCTAssertEqual(full.width, 400)
        XCTAssertEqual(full.height, 200)

        let crop = CGRect(x: 10, y: 10, width: 50, height: 25)
        let cropped = try XCTUnwrap(renderer.render([.crop(rect: crop)]))
        XCTAssertEqual(cropped.width, 100)
        XCTAssertEqual(cropped.height, 50)
    }

    /// A white 200×100pt screenshot at 2x
    private func whiteRenderer() throws -> AnnotationRenderer {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        return AnnotationRenderer(screenshot: NSImage(
            cgImage: try XCTUnwrap(context.makeImage()), size: NSSize(width: 200, height: 100)
        ))
    }

    /// RGBA of the exported pixel at a top-left point (2x)
    private func pixel(_ image: CGImage, atPoint point: CGPoint) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Shift the image so the wanted pixel lands on the 1×1 context (rows count from the top)
        let px = point.x * 2, py = point.y * 2
        context.draw(image, in: CGRect(x: -px, y: py - CGFloat(image.height) + 1,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return data
    }

    func testRender_marksCastASoftShadowBelowThem() throws {
        let renderer = try whiteRenderer()
        let rect = CGRect(x: 50, y: 25, width: 100, height: 50)
        let image = try XCTUnwrap(renderer.render([.rectangle(rect: rect, color: .red)]))
        let underneath = try pixel(image, atPoint: CGPoint(x: 100, y: 78))
        XCTAssertLessThan(underneath[0], 250, "shadow just below the bottom edge")
        // Offset down: darker under the bottom edge than the same distance over the top edge
        let above = try pixel(image, atPoint: CGPoint(x: 100, y: 21.5))
        let below = try pixel(image, atPoint: CGPoint(x: 100, y: 78.5))
        XCTAssertLessThan(below[1], above[1])
        let farAway = try pixel(image, atPoint: CGPoint(x: 100, y: 95))
        XCTAssertEqual(farAway[0], 255)
    }

    func testRender_highlightTintsLikeAMarker() throws {
        let renderer = try whiteRenderer()
        let image = try XCTUnwrap(renderer.render([
            .highlight(rect: CGRect(x: 20, y: 20, width: 60, height: 30), color: .yellow),
        ]))
        let inside = try pixel(image, atPoint: CGPoint(x: 50, y: 35))
        XCTAssertGreaterThan(inside[0], 230)  // red stays: the white under it shows through
        XCTAssertLessThan(inside[2], 200)     // blue is multiplied away
        XCTAssertEqual(try pixel(image, atPoint: CGPoint(x: 150, y: 80)), [255, 255, 255, 255])
    }

    func testRender_textLabelFillsBehindTheTextInItsColor() throws {
        let renderer = try whiteRenderer()
        var style = TextStyle(size: 24)
        style.background = true
        let text = Annotation.text(origin: CGPoint(x: 40, y: 30), width: 120, content: "Hi", style: style, color: .blue)
        let image = try XCTUnwrap(renderer.render([text]))
        let frame = Annotation.textFrame(origin: CGPoint(x: 40, y: 30), width: 120, content: "Hi", style: style)
        // In the label's padding, left of the text: the fill color
        let padding = try pixel(image, atPoint: CGPoint(x: frame.minX + 3, y: frame.midY))
        XCTAssertLessThan(padding[0], 80)
        XCTAssertGreaterThan(padding[2], 180)
        XCTAssertEqual(try pixel(image, atPoint: CGPoint(x: 190, y: 95)), [255, 255, 255, 255])
    }
}

final class TextStyleTests: XCTestCase {
    func testDefaultIsTheOriginalBoldSystemLook() {
        let style = TextStyle()
        XCTAssertEqual(style.size, 24)
        XCTAssertEqual(style.font, NSFont.boldSystemFont(ofSize: 24))
        XCTAssertEqual(style.labelPadding, .zero)
        XCTAssertEqual(style.textColor(on: .red), AnnotationColor.red.nsColor)
    }

    func testDesignsAndWeightChangeTheFont() {
        var style = TextStyle()
        style.design = .mono
        XCTAssertTrue(style.font.isFixedPitch)
        style.design = .serif
        XCTAssertNotEqual(style.font.fontName, TextStyle().font.fontName)
        style.design = .system
        style.bold = false
        XCTAssertEqual(style.font, NSFont.systemFont(ofSize: 24))
        XCTAssertEqual(style.font(ofSize: 48).pointSize, 48)
    }

    func testLabelPadsTheFrameButNotTheTextLayout() {
        var style = TextStyle()
        style.background = true
        let origin = CGPoint(x: 10, y: 20)
        let layout = Annotation.textBoundingRect(origin: origin, width: 200, content: "Hello", style: style)
        let frame = Annotation.textFrame(origin: origin, width: 200, content: "Hello", style: style)
        XCTAssertEqual(layout, Annotation.textBoundingRect(origin: origin, width: 200, content: "Hello", style: TextStyle()))
        XCTAssertEqual(frame, layout.insetBy(dx: -style.labelPadding.width, dy: -style.labelPadding.height))
        XCTAssertGreaterThan(style.labelPadding.width, 0)
        XCTAssertEqual(style.textColor(on: .yellow), AnnotationColor.yellow.contrastingTextColor)

        // Hit testing and handles use the padded frame
        let text = Annotation.text(origin: origin, width: 200, content: "Hello", style: style, color: .red)
        XCTAssertTrue(text.bodyContains(CGPoint(x: frame.minX + 1, y: frame.midY), hitRadius: 0))
        XCTAssertEqual(text.handles.first?.point.x ?? 0, frame.minX, accuracy: 0.001)
    }

    func testStyleSurvivesEdits() {
        var style = TextStyle()
        style.design = .rounded
        let text = Annotation.text(origin: .zero, width: 100, content: "Hi", style: style, color: .red)
        for edited in [text.withColor(.blue), text.offsetBy(dx: 5, dy: 5), text.moving(.right, to: CGPoint(x: 150, y: 0))] {
            guard case .text(_, _, _, let kept, _) = edited else { return XCTFail("not text") }
            XCTAssertEqual(kept, style)
        }
    }
}
