import AppKit
import ImageIO

final class AnnotationView: NSView {
    weak var appDelegate: AppDelegate?
    private let screenshot: NSImage
    private var annotations: [Annotation] = []
    private var currentAnnotation: Annotation?
    private var dragOrigin: CGPoint = .zero
    private var dragModifiers: NSEvent.ModifierFlags = []

    // Handle editing state
    private var editingIndex: Int?
    private var editingHandle: AnnotationHandle?
    private var editingOriginal: Annotation?
    private var hoveredAnnotationIndex: Int?

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
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
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

        // Draw handles for hovered annotation
        if currentAnnotation == nil, let idx = hoveredAnnotationIndex,
           idx < annotations.count {
            drawHandles(for: annotations[idx])
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawHandles(for annotation: Annotation) {
        let handleRadius: CGFloat = 6.0
        for (_, point) in annotation.handles {
            let handleRect = CGRect(
                x: point.x - handleRadius,
                y: point.y - handleRadius,
                width: handleRadius * 2,
                height: handleRadius * 2
            )
            let path = NSBezierPath(ovalIn: handleRect)
            NSColor.white.setFill()
            path.fill()
            NSColor.red.setStroke()
            path.lineWidth = 2.0
            path.stroke()
        }
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
        let screenshotPoint = viewToScreenshot(viewPoint)
        dragModifiers = event.modifierFlags

        let hasDrawModifiers = dragModifiers.contains(.shift)
            || dragModifiers.contains(.option)
            || dragModifiers.contains(.command)

        if !hasDrawModifiers, let (index, handle) = handleAt(screenshotPoint) {
            editingIndex = index
            editingHandle = handle
            editingOriginal = annotations[index]
            return
        }

        dragOrigin = screenshotPoint
        editingIndex = nil
        editingHandle = nil
        editingOriginal = nil
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = viewToScreenshot(viewPoint)

        if let idx = editingIndex, let handle = editingHandle {
            annotations[idx] = annotations[idx].moving(handle, to: point)
            needsDisplay = true
            return
        }

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
        if let idx = editingIndex, let original = editingOriginal {
            let edited = annotations[idx]
            replaceAnnotation(at: idx, with: edited, old: original)
            editingIndex = nil
            editingHandle = nil
            editingOriginal = nil
            return
        }

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

    override func mouseMoved(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let screenshotPoint = viewToScreenshot(viewPoint)

        if let (index, _) = handleAt(screenshotPoint) {
            NSCursor.crosshair.set()
            if hoveredAnnotationIndex != index {
                hoveredAnnotationIndex = index
                needsDisplay = true
            }
        } else {
            NSCursor.arrow.set()
            if hoveredAnnotationIndex != nil {
                hoveredAnnotationIndex = nil
                needsDisplay = true
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        if hoveredAnnotationIndex != nil {
            hoveredAnnotationIndex = nil
            needsDisplay = true
        }
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

    // MARK: - Hit Testing

    /// Returns the annotation index and handle at the given screenshot-space point
    func handleAt(_ point: CGPoint) -> (index: Int, handle: AnnotationHandle)? {
        let ir = imageRect
        let scale = ir.width / screenshot.size.width
        let hitRadius: CGFloat = 10.0 / scale  // 10 view points → screenshot space

        var bestIndex: Int?
        var bestHandle: AnnotationHandle?
        var bestDist = CGFloat.greatestFiniteMagnitude

        for i in stride(from: annotations.count - 1, through: 0, by: -1) {
            for (handle, handlePoint) in annotations[i].handles {
                let dist = hypot(point.x - handlePoint.x, point.y - handlePoint.y)
                if dist <= hitRadius && dist < bestDist {
                    bestDist = dist
                    bestIndex = i
                    bestHandle = handle
                }
            }
            // If we found a handle on a top annotation, stop checking lower ones
            if bestIndex == i { break }
        }

        guard let index = bestIndex, let handle = bestHandle else { return nil }
        return (index, handle)
    }

    // MARK: - Annotations + Undo

    private func replaceAnnotation(at index: Int, with new: Annotation, old: Annotation) {
        annotations[index] = new
        undoManager?.registerUndo(withTarget: self) { target in
            target.replaceAnnotation(at: index, with: old, old: new)
        }
        needsDisplay = true
    }

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

    // MARK: - Testing Support

    /// Injects annotations for unit testing `handleAt()`
    func setAnnotations(forTesting newAnnotations: [Annotation]) {
        annotations = newAnnotations
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
