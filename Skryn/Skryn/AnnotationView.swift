import AppKit
import ImageIO

final class AnnotationView: NSView {
    weak var appDelegate: AppDelegate?
    private let screenshot: NSImage
    private var annotations: [Annotation] = []
    private var currentAnnotation: Annotation?
    private var dragOrigin: CGPoint = .zero
    private var dragModifiers: NSEvent.ModifierFlags = []

    /// Rect where the screenshot is drawn on screen
    private var imageRect: NSRect { bounds }

    /// Full screenshot coordinate space
    private var screenshotBounds: NSRect {
        NSRect(origin: .zero, size: screenshot.size)
    }

    private lazy var _undoManager = UndoManager()
    override var undoManager: UndoManager? { _undoManager }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, image: NSImage) {
        self.screenshot = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Converts a view-space point to screenshot coordinates
    func viewToScreenshot(_ point: CGPoint) -> CGPoint {
        let ir = imageRect
        let scale = screenshot.size.width / ir.width
        let x = (point.x - ir.origin.x) * scale
        let y = (point.y - ir.origin.y) * scale
        return CGPoint(
            x: min(max(x, 0), screenshot.size.width),
            y: min(max(y, 0), screenshot.size.height)
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let ir = imageRect

        screenshot.draw(in: ir)

        // Draw annotations in screenshot coordinate space
        NSGraphicsContext.saveGraphicsState()
        let xform = NSAffineTransform()
        xform.translateX(by: ir.origin.x, yBy: ir.origin.y)
        let s = ir.width / screenshot.size.width
        xform.scaleX(by: s, yBy: s)
        xform.concat()

        for annotation in annotations {
            draw(annotation)
        }

        if let current = currentAnnotation {
            draw(current)
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func draw(_ annotation: Annotation) {
        switch annotation {
        case .arrow(let from, let to):
            drawArrow(from: from, to: to)
        case .line(let from, let to):
            drawLine(from: from, to: to)
        case .rectangle(let rect):
            drawRectangle(rect)
        case .crop(let rect):
            drawCrop(rect)
        }
    }

    private func drawArrow(from: CGPoint, to: CGPoint) {
        let color = NSColor.red
        color.setStroke()
        color.setFill()

        let path = NSBezierPath()
        path.lineWidth = 3.0
        path.move(to: from)
        path.line(to: to)
        path.stroke()

        // Arrowhead
        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLength: CGFloat = 18.0
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

    private func drawLine(from: CGPoint, to: CGPoint) {
        NSColor.red.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 3.0
        path.move(to: from)
        path.line(to: to)
        path.stroke()
    }

    private func drawRectangle(_ rect: CGRect) {
        NSColor.red.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 3.0
        path.stroke()
    }

    private func drawCrop(_ rect: CGRect) {
        // Dim area outside crop (uses screenshotBounds since we draw in screenshot space)
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

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        dragOrigin = viewToScreenshot(viewPoint)
        dragModifiers = event.modifierFlags
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = viewToScreenshot(viewPoint)

        if dragModifiers.contains(.command) {
            currentAnnotation = .crop(rect: rectFromDrag(origin: dragOrigin, current: point))
        } else if dragModifiers.contains(.option) {
            currentAnnotation = .rectangle(rect: rectFromDrag(origin: dragOrigin, current: point))
        } else if dragModifiers.contains(.shift) {
            currentAnnotation = .line(from: dragOrigin, to: point)
        } else {
            currentAnnotation = .arrow(from: dragOrigin, to: point)
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let annotation = currentAnnotation else { return }
        currentAnnotation = nil

        // Ignore negligible drags
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = viewToScreenshot(viewPoint)
        let dx = abs(point.x - dragOrigin.x)
        let dy = abs(point.y - dragOrigin.y)
        if dx < 2 && dy < 2 { return }

        addAnnotation(annotation)
    }

    // MARK: - Key Events

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36 && event.modifierFlags.contains(.option) { // OPT+ENTER
            alternateAndClose()
            return true
        }
        if event.keyCode == 36 && event.modifierFlags.contains(.command) { // CMD+ENTER
            saveAndClose()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC — remove crop
            annotations.removeAll { if case .crop = $0 { return true }; return false }
            needsDisplay = true
            return
        }

        super.keyDown(with: event)
    }

    @objc func undo(_ sender: Any?) {
        undoManager?.undo()
        needsDisplay = true
    }

    @objc func redo(_ sender: Any?) {
        undoManager?.redo()
        needsDisplay = true
    }

    // MARK: - Annotations + Undo

    private func addAnnotation(_ annotation: Annotation) {
        if case .crop = annotation {
            annotations.removeAll { if case .crop = $0 { return true }; return false }
        }
        annotations.append(annotation)
        undoManager?.registerUndo(withTarget: self) { target in
            target.removeLastAnnotation()
        }
        needsDisplay = true
    }

    private func removeLastAnnotation() {
        guard let removed = annotations.popLast() else { return }
        undoManager?.registerUndo(withTarget: self) { target in
            target.addAnnotation(removed)
        }
        needsDisplay = true
    }

    // MARK: - Save

    private func saveAndClose() {
        guard let cgImage = compositeAsCGImage() else {
            print("AnnotationView: failed to create image")
            window?.close()
            return
        }

        appDelegate?.handleSave(cgImage: cgImage)

        window?.close()
    }

    private func alternateAndClose() {
        guard let cgImage = compositeAsCGImage() else {
            window?.close()
            return
        }

        appDelegate?.handleAlternateSave(cgImage: cgImage)

        window?.close()
    }

    private func compositeAsCGImage() -> CGImage? {
        guard let screenshotCG = screenshot.cgImage(
            forProposedRect: nil, context: nil, hints: nil
        ) else { return nil }

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

        let nsContext = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        for annotation in annotations {
            if case .crop = annotation { continue }
            draw(annotation)
        }

        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()

        guard var cgImage = ctx.makeImage() else { return nil }

        // Apply crop if present
        if let cropAnnotation = annotations.first(where: {
            if case .crop = $0 { return true }; return false
        }), case .crop(let cropRect) = cropAnnotation {
            let scaleX = CGFloat(pixelWidth) / pointSize.width
            let scaleY = CGFloat(pixelHeight) / pointSize.height
            let pixelCropRect = CGRect(
                x: cropRect.origin.x * scaleX,
                y: cropRect.origin.y * scaleY,
                width: cropRect.width * scaleX,
                height: cropRect.height * scaleY
            )
            if let cropped = cgImage.cropping(to: pixelCropRect) {
                cgImage = cropped
            }
        }

        return cgImage
    }

    // MARK: - Helpers

    func rectFromDrag(origin: CGPoint, current: CGPoint) -> CGRect {
        CGRect(
            x: min(origin.x, current.x),
            y: min(origin.y, current.y),
            width: abs(current.x - origin.x),
            height: abs(current.y - origin.y)
        )
    }
}
