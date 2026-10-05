import AppKit
import CoreImage

/// A finished screenshot, ready for Save / Copy / Upload.
struct RenderedScreenshot {
    let cgImage: CGImage
    /// Pixels per point, so 1x output can be sized in points
    let pixelsPerPoint: CGFloat
    let captureDate: Date
}

/// Draws annotations in screenshot point space (top-left origin), both on screen (`AnnotationView`
/// sets up the transform) and into the exported bitmap. Owns the blur cache.
final class AnnotationRenderer {
    let screenshot: NSImage
    let screenshotCG: CGImage?

    private static let blurCIContext = CIContext()
    private var blurCache: [BlurCacheKey: NSImage] = [:]
    /// Editing chrome (handles, dashed borders) is drawn this much smaller, so it keeps its on-screen
    /// size when the editor is zoomed in (1 / zoom)
    var chromeScale: CGFloat = 1
    /// Smallest pixellation block, in screenshot points, so small regions stay unreadable
    private static let minBlurBlockSize: CGFloat = 10

    init(screenshot: NSImage) {
        self.screenshot = screenshot
        screenshotCG = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private var screenshotBounds: CGRect { CGRect(origin: .zero, size: screenshot.size) }

    /// Pixels per point of the screenshot
    var pixelsPerPoint: CGFloat {
        CGFloat(screenshotCG?.width ?? 0) / max(screenshot.size.width, 1)
    }

    // MARK: - Layering

    /// Blurs first (between the screenshot and the rest), then highlights, then everything else, with
    /// `current` (the annotation being drawn) last in its layer. `skipping` is left out (a text view draws it); the blur at `uncachedIndex`
    /// (being dragged) and `current` render uncached so intermediate frames don't pile up in the cache.
    /// Export leaves crop out: it's applied by cutting the image instead.
    func draw(
        _ annotations: [Annotation], current: Annotation? = nil, skipping: Int? = nil,
        uncachedIndex: Int? = nil, includeCrop: Bool = true
    ) {
        var layers = annotations.enumerated()
            .filter { $0.offset != skipping }
            .map { (annotation: $0.element, cached: $0.offset != uncachedIndex) }
        if let current { layers.append((current, false)) }

        for layer in layers {
            if case .blur(let rect) = layer.annotation { drawBlur(rect, cache: layer.cached) }
        }
        for layer in layers {
            if case .highlight(let rect, let color) = layer.annotation { drawHighlight(rect, color: color) }
        }
        for layer in layers {
            switch layer.annotation {
            case .blur, .highlight: continue
            case .crop where !includeCrop: continue
            default: draw(layer.annotation)
            }
        }
    }

    // MARK: - Export

    /// The screenshot with `annotations` drawn at full pixel resolution, cut to the crop if there is one.
    func render(_ annotations: [Annotation]) -> CGImage? {
        guard let screenshotCG else { return nil }

        let pixelWidth = screenshotCG.width
        let pixelHeight = screenshotCG.height
        let pointSize = screenshot.size
        let colorSpace = screenshotCG.colorSpace ?? CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Draw screenshot at full pixel resolution (bottom-left origin, no transform)
        ctx.draw(screenshotCG, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        // Transform to top-left origin in point coordinates for annotations
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
        ctx.scaleBy(
            x: CGFloat(pixelWidth) / pointSize.width,
            y: -CGFloat(pixelHeight) / pointSize.height
        )

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw(annotations, includeCrop: false)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()

        guard let cgImage = ctx.makeImage() else { return nil }
        return cropped(cgImage, to: annotations, pointSize: pointSize)
    }

    /// `image` cut to the crop annotation, if there is one (crop is in points; the image in pixels).
    private func cropped(_ image: CGImage, to annotations: [Annotation], pointSize: CGSize) -> CGImage {
        let cropRect = annotations.lazy.compactMap { annotation -> CGRect? in
            if case .crop(let rect) = annotation { return rect }
            return nil
        }.first
        guard let cropRect else { return image }
        let scaleX = CGFloat(image.width) / pointSize.width
        let scaleY = CGFloat(image.height) / pointSize.height
        let pixelCropRect = CGRect(
            x: cropRect.origin.x * scaleX, y: cropRect.origin.y * scaleY,
            width: cropRect.width * scaleX, height: cropRect.height * scaleY
        )
        return image.cropping(to: pixelCropRect) ?? image
    }

    // MARK: - Blur cache

    /// Drops cached blur images whose rect no longer belongs to any blur annotation.
    /// Blur output depends only on the screenshot and the rect, so entries stay valid otherwise.
    func pruneBlurCache(keeping annotations: [Annotation]) {
        let liveKeys = Set(annotations.compactMap { annotation -> BlurCacheKey? in
            if case .blur(let rect) = annotation { return BlurCacheKey(rect) }
            return nil
        })
        blurCache = blurCache.filter { liveKeys.contains($0.key) }
    }

    // MARK: - Editing chrome (on screen only)

    /// Handles of the hovered annotation; text also gets a dotted border, with its edge handles pushed
    /// out by `textPadding` (in screenshot points).
    func drawHandles(for annotation: Annotation, textPadding: CGFloat) {
        var padding: CGFloat = 0
        if case .text(let origin, let width, let content, let fontSize, _) = annotation {
            padding = textPadding
            let baseRect = Annotation.textBoundingRect(
                origin: origin, width: width, content: content, fontSize: fontSize
            )
            drawDashedBorder(baseRect.insetBy(dx: -padding, dy: 0))
        }
        // Badges have no handles: a dashed ring shows they're selected / grabbable
        if case .badge(let center, _, _) = annotation {
            let radius = Annotation.badgeRadius + 4 * chromeScale
            drawDashedBorder(NSBezierPath(ovalIn: CGRect(
                x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2
            )))
        }

        for (handle, point) in annotation.handles {
            var drawPoint = point
            if padding > 0 {
                drawPoint.x += (handle == .left ? -padding : padding)
            }
            drawHandle(at: drawPoint)
        }
    }

    /// Live border around the text view being edited, with its two width handles
    func drawActiveTextBorder(_ rect: CGRect) {
        drawDashedBorder(rect)
        drawHandle(at: CGPoint(x: rect.minX, y: rect.midY))
        drawHandle(at: CGPoint(x: rect.maxX, y: rect.midY))
    }

    private func drawDashedBorder(_ rect: CGRect) {
        drawDashedBorder(NSBezierPath(rect: rect))
    }

    /// Editing chrome is in the system accent color, so it never reads as part of a (red) annotation
    private func drawDashedBorder(_ borderPath: NSBezierPath) {
        borderPath.lineWidth = 1.5 * chromeScale
        let dashPattern: [CGFloat] = [4.0 * chromeScale, 4.0 * chromeScale]
        borderPath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
        NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
        borderPath.stroke()
    }

    private func drawHandle(at point: CGPoint) {
        let handleRadius = 6.0 * chromeScale
        let path = NSBezierPath(ovalIn: CGRect(
            x: point.x - handleRadius, y: point.y - handleRadius,
            width: handleRadius * 2, height: handleRadius * 2
        ))
        NSColor.white.setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2.0 * chromeScale
        path.stroke()
    }

    // MARK: - Annotations

    /// Marks drawn over a soft shadow, so they stay legible on busy screenshots
    private static func castsShadow(_ annotation: Annotation) -> Bool {
        switch annotation {
        case .arrow, .line, .rectangle, .ellipse, .text, .badge: true
        case .highlight, .crop, .blur: false
        }
    }

    private func draw(_ annotation: Annotation) {
        guard Self.castsShadow(annotation), let ctx = NSGraphicsContext.current?.cgContext else {
            return drawMark(annotation)
        }
        // Shadow offset and blur are in device space: map 1pt down and 3pt of blur through the
        // current transform, so screen and export (different scales and flips) look the same.
        let ctm = ctx.ctm
        let scale = sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: 1).applying(ctm), blur: 3 * scale,
            color: NSColor.black.withAlphaComponent(0.35).cgColor
        )
        // One layer per mark, so an arrow's line and head cast a single shadow
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        drawMark(annotation)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private func drawMark(_ annotation: Annotation) {
        switch annotation {
        case .arrow(let from, let to, let color, let width):
            drawArrow(from: from, to: to, color: color.nsColor, width: width)
        case .line(let from, let to, let color, let width):
            drawLine(from: from, to: to, color: color.nsColor, width: width)
        case .rectangle(let rect, let color, let width):
            drawRectangle(rect, color: color.nsColor, width: width)
        case .ellipse(let rect, let color, let width):
            drawEllipse(rect, color: color.nsColor, width: width)
        case .highlight(let rect, let color):
            drawHighlight(rect, color: color)
        case .crop(let rect):
            drawCrop(rect)
        case .text(let origin, let width, let content, let fontSize, let color):
            drawText(origin: origin, width: width, content: content,
                     fontSize: fontSize, color: color.nsColor)
        case .blur(let rect):
            drawBlur(rect)
        case .badge(let center, let number, let color):
            drawBadge(center: center, number: number, color: color)
        }
    }

    private func drawArrow(from: CGPoint, to: CGPoint, color: NSColor, width: StrokeWidth) {
        color.setStroke()
        color.setFill()

        let path = NSBezierPath()
        path.lineWidth = width.points
        path.move(to: from)
        path.line(to: to)
        path.stroke()

        // Arrowhead
        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLength = width.arrowHeadLength
        let headAngle: CGFloat = .pi / 6

        let p1 = CGPoint(
            x: to.x - headLength * cos(angle - headAngle),
            y: to.y - headLength * sin(angle - headAngle)
        )
        let p2 = CGPoint(
            x: to.x - headLength * cos(angle + headAngle),
            y: to.y - headLength * sin(angle + headAngle)
        )

        let head = NSBezierPath()
        head.move(to: to)
        head.line(to: p1)
        head.line(to: p2)
        head.close()
        head.fill()
    }

    private func drawLine(from: CGPoint, to: CGPoint, color: NSColor, width: StrokeWidth) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = width.points
        path.move(to: from)
        path.line(to: to)
        path.stroke()
    }

    private func drawRectangle(_ rect: CGRect, color: NSColor, width: StrokeWidth) {
        color.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = width.points
        path.stroke()
    }

    private func drawEllipse(_ rect: CGRect, color: NSColor, width: StrokeWidth) {
        color.setStroke()
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = width.points
        path.stroke()
    }

    /// A marker stroke: the color multiplied into the screenshot, so text under it stays readable
    private func drawHighlight(_ rect: CGRect, color: AnnotationColor) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.compositingOperation = .multiply
        color.nsColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(rect: rect).fill()
        context.restoreGraphicsState()
    }

    private func drawBadge(center: CGPoint, number: Int, color: AnnotationColor) {
        let radius = Annotation.badgeRadius
        let circleRect = CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        )
        color.nsColor.setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        let label = String(number)
        let fontSize: CGFloat = label.count > 2 ? 14 : 18
        let font = NSFont.boldSystemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.contrastingTextColor]
        let size = (label as NSString).size(withAttributes: attrs)
        let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        (label as NSString).draw(at: origin, withAttributes: attrs)
    }

    private func drawCrop(_ rect: CGRect) {
        // Dim area outside crop (in screenshot space, like everything here)
        let overlay = NSBezierPath(rect: screenshotBounds)
        overlay.appendRect(rect)
        overlay.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        overlay.fill()

        // White border around crop
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2.0
        border.stroke()
    }

    private func drawBlur(_ rect: CGRect, cache: Bool = true) {
        let cacheKey = BlurCacheKey(rect)
        if cache, let cached = blurCache[cacheKey] {
            cached.draw(in: rect)
            return
        }

        guard let screenshotCG else { return }

        let pointSize = screenshot.size
        let scaleX = CGFloat(screenshotCG.width) / pointSize.width
        let scaleY = CGFloat(screenshotCG.height) / pointSize.height

        // CGImage.cropping(to:) uses the same top-left image coordinates as the captured screenshot.
        let pixelRect = CGRect(
            x: rect.origin.x * scaleX,
            y: rect.origin.y * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integral

        guard pixelRect.width > 0, pixelRect.height > 0,
              let cropped = screenshotCG.cropping(to: pixelRect)
        else { return }

        let ciImage = CIImage(cgImage: cropped)
        let pixelSize = max(max(pixelRect.width, pixelRect.height) / 40, Self.minBlurBlockSize * scaleX)
        let blurred = ciImage
            .applyingFilter("CIPhotoEffectMono")
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: pixelSize])
            .cropped(to: ciImage.extent)

        guard let blurredCG = Self.blurCIContext.createCGImage(blurred, from: blurred.extent)
        else { return }

        let blurredNSImage = NSImage(cgImage: blurredCG, size: rect.size)
        if cache { blurCache[cacheKey] = blurredNSImage }
        blurredNSImage.draw(in: rect)
    }

    private func drawText(origin: CGPoint, width: CGFloat, content: String,
                          fontSize: CGFloat, color: NSColor) {
        let font = NSFont.boldSystemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let rect = Annotation.textBoundingRect(
            origin: origin, width: width, content: content, fontSize: fontSize
        )
        (content as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                   attributes: attrs)
    }
}

/// Blur cache key: a rect, made hashable
private struct BlurCacheKey: Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.width)
        height = Double(rect.height)
    }
}
