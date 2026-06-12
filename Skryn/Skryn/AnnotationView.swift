import AppKit
import CoreImage
import ImageIO

/// NSTextView with its own undo manager, isolated from the parent view's undo stack.
/// Prevents stale text-editing undo operations from crashing after the text view is removed.
private class IsolatedUndoTextView: NSTextView {
    private let _ownUndoManager = UndoManager()
    override var undoManager: UndoManager? { _ownUndoManager }
}

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

final class AnnotationView: NSView {
    weak var appDelegate: AppDelegate?
    private let screenshot: NSImage
    let captureDate = Date()
    private var annotations: [Annotation] = []
    private var currentAnnotation: Annotation?
    private var dragOrigin: CGPoint = .zero
    private var dragModifiers: NSEvent.ModifierFlags = []

    private enum InteractionState {
        case idle
        case editingHandle(index: Int, handle: AnnotationHandle, original: Annotation)
        case movingAnnotation(index: Int, original: Annotation, lastPoint: CGPoint)
        case editingText(textView: NSTextView, existingIndex: Int?)
    }

    private var interactionState: InteractionState = .idle
    private var hoveredAnnotationIndex: Int?
    private var isTextMode = false
    private var textFontSize: CGFloat = 24
    private var currentColor: AnnotationColor = .red

    /// Last badge placed via a digit key, for combining quick presses into one number (1, 2 → 12)
    private var lastBadge: (index: Int, time: Date)?
    private static let badgeCombineInterval: TimeInterval = 0.5

    /// Rect where the screenshot is drawn on screen
    private var screenshotRect: NSRect { bounds }

    /// Full screenshot coordinate space
    private var screenshotBounds: NSRect {
        NSRect(origin: .zero, size: screenshot.size)
    }

    private static let blurCIContext = CIContext()
    private var blurCache: [BlurCacheKey: NSImage] = [:]

    private lazy var _undoManager = UndoManager()
    override var undoManager: UndoManager? { _undoManager }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, screenshot: NSImage) {
        self.screenshot = screenshot
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
        let ir = screenshotRect
        let scale = screenshot.size.width / ir.width
        let x = (point.x - ir.origin.x) * scale
        let y = (point.y - ir.origin.y) * scale
        return CGPoint(
            x: min(max(x, 0), screenshot.size.width),
            y: min(max(y, 0), screenshot.size.height)
        )
    }

    /// Converts a screenshot-space point to view coordinates
    func screenshotToView(_ point: CGPoint) -> CGPoint {
        let ir = screenshotRect
        let scale = ir.width / screenshot.size.width
        return CGPoint(
            x: ir.origin.x + point.x * scale,
            y: ir.origin.y + point.y * scale
        )
    }

    /// Scale factor from screenshot coords to view coords
    private func screenshotToViewScale() -> CGFloat {
        screenshotRect.width / screenshot.size.width
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let ir = screenshotRect

        screenshot.draw(in: ir)

        // Draw annotations in screenshot coordinate space
        NSGraphicsContext.saveGraphicsState()
        let xform = NSAffineTransform()
        xform.translateX(by: ir.origin.x, yBy: ir.origin.y)
        let s = ir.width / screenshot.size.width
        xform.scaleX(by: s, yBy: s)
        xform.concat()

        let editingTextIdx: Int?
        let activeTV: NSTextView?
        if case .editingText(let tv, let idx) = interactionState {
            editingTextIdx = idx
            activeTV = tv
        } else {
            editingTextIdx = nil
            activeTV = nil
        }

        // First pass: blur annotations (between screenshot and other annotations)
        for (i, annotation) in annotations.enumerated() {
            if i == editingTextIdx { continue }
            if case .blur = annotation { draw(annotation) }
        }
        if let current = currentAnnotation, case .blur(let rect) = current {
            drawBlur(rect, cache: false)
        }

        // Second pass: non-blur annotations
        for (i, annotation) in annotations.enumerated() {
            if i == editingTextIdx { continue }
            if case .blur = annotation { continue }
            draw(annotation)
        }
        if let current = currentAnnotation {
            if case .blur = current {} else { draw(current) }
        }

        // Draw handles for hovered annotation (skip when actively editing text)
        if activeTV == nil, currentAnnotation == nil, let idx = hoveredAnnotationIndex,
           idx < annotations.count {
            drawHandles(for: annotations[idx])
        }

        // Draw live border around active text view during editing
        if let textView = activeTV {
            drawActiveTextBorder(textView: textView)
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawHandles(for annotation: Annotation) {
        // Draw dotted border for text annotations
        if case .text(let origin, let width, let content, let fontSize, _) = annotation {
            let padding: CGFloat = 4.0 / screenshotToViewScale()
            let baseRect = Annotation.textBoundingRect(
                origin: origin, width: width, content: content, fontSize: fontSize
            )
            let rect = baseRect.insetBy(dx: -padding, dy: 0)
            let borderPath = NSBezierPath(rect: rect)
            borderPath.lineWidth = 1.5
            let dashPattern: [CGFloat] = [4.0, 4.0]
            borderPath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
            NSColor.red.withAlphaComponent(0.5).setStroke()
            borderPath.stroke()
        }

        let handleRadius: CGFloat = 6.0
        let isText: Bool
        if case .text = annotation { isText = true } else { isText = false }
        let textPadding: CGFloat = isText ? 4.0 / screenshotToViewScale() : 0
        for (handle, point) in annotation.handles {
            var drawPoint = point
            if isText {
                drawPoint.x += (handle == .left ? -textPadding : textPadding)
            }
            let handleRect = CGRect(
                x: drawPoint.x - handleRadius,
                y: drawPoint.y - handleRadius,
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

    private func drawActiveTextBorder(textView: NSTextView) {
        let viewFrame = textView.frame
        let padding: CGFloat = 4.0
        let topLeft = viewToScreenshot(CGPoint(x: viewFrame.minX - padding, y: viewFrame.minY))
        let bottomRight = viewToScreenshot(CGPoint(x: viewFrame.maxX + padding, y: viewFrame.maxY))
        let rect = CGRect(
            x: topLeft.x, y: topLeft.y,
            width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y
        )

        let borderPath = NSBezierPath(rect: rect)
        borderPath.lineWidth = 1.5
        let dashPattern: [CGFloat] = [4.0, 4.0]
        borderPath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
        NSColor.red.withAlphaComponent(0.5).setStroke()
        borderPath.stroke()

        let handleRadius: CGFloat = 6.0
        let midY = (topLeft.y + bottomRight.y) / 2
        for x in [topLeft.x, bottomRight.x] {
            let handleRect = CGRect(
                x: x - handleRadius, y: midY - handleRadius,
                width: handleRadius * 2, height: handleRadius * 2
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
        case .arrow(let from, let to, let color):
            drawArrow(from: from, to: to, color: color.nsColor)
        case .line(let from, let to, let color):
            drawLine(from: from, to: to, color: color.nsColor)
        case .rectangle(let rect, let color):
            drawRectangle(rect, color: color.nsColor)
        case .ellipse(let rect, let color):
            drawEllipse(rect, color: color.nsColor)
        case .crop(let rect):
            drawCrop(rect)
        case .text(let origin, let width, let content, let fontSize, let color):
            drawText(origin: origin, width: width, content: content,
                     fontSize: fontSize, color: color.nsColor)
        case .blur(let rect):
            drawBlur(rect)
        case .badge(let center, let number, let color):
            drawBadge(center: center, number: number, color: color.nsColor)
        }
    }

    private func drawArrow(from: CGPoint, to: CGPoint, color: NSColor) {
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

    private func drawLine(from: CGPoint, to: CGPoint, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 3.0
        path.move(to: from)
        path.line(to: to)
        path.stroke()
    }

    private func drawRectangle(_ rect: CGRect, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 3.0
        path.stroke()
    }

    private func drawEllipse(_ rect: CGRect, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = 3.0
        path.stroke()
    }

    private func drawBadge(center: CGPoint, number: Int, color: NSColor) {
        let radius = Annotation.badgeRadius
        let circleRect = CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        )
        color.setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        let label = String(number)
        let fontSize: CGFloat = label.count > 2 ? 14 : 18
        let font = NSFont.boldSystemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (label as NSString).size(withAttributes: attrs)
        let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        (label as NSString).draw(at: origin, withAttributes: attrs)
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

    private func drawBlur(_ rect: CGRect, cache: Bool = true) {
        let cacheKey = BlurCacheKey(rect)
        if cache, let cached = blurCache[cacheKey] {
            cached.draw(in: rect)
            return
        }

        guard let screenshotCG = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

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
        let pixelSize = max(pixelRect.width, pixelRect.height) / 40
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

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let screenshotPoint = viewToScreenshot(viewPoint)
        dragModifiers = event.modifierFlags
        lastBadge = nil

        // If editing text: clicks inside the text view are handled by it;
        // clicks outside finalize editing and continue to handle/body hit testing
        if case .editingText(let textView, _) = interactionState {
            if textView.frame.contains(viewPoint) {
                return
            }
            finalizeTextEditing()
        }

        let hasDrawModifiers = dragModifiers.contains(.shift)
            || dragModifiers.contains(.option)
            || dragModifiers.contains(.command)
            || dragModifiers.contains(.control)

        // Text mode: place new text annotation
        if isTextMode && !hasDrawModifiers {
            placeTextAnnotation(at: screenshotPoint)
            return
        }

        // Exit text mode if draw modifiers pressed
        if isTextMode && hasDrawModifiers {
            isTextMode = false
            NSCursor.arrow.set()
        }

        if !hasDrawModifiers, let (index, handle) = handleAt(screenshotPoint) {
            interactionState = .editingHandle(
                index: index, handle: handle, original: annotations[index]
            )
            return
        }

        // Click on annotation body — prepare for move (if dragged) or re-edit text (if clicked)
        if !hasDrawModifiers, let idx = annotationBodyAt(screenshotPoint) {
            interactionState = .movingAnnotation(
                index: idx, original: annotations[idx], lastPoint: screenshotPoint
            )
            return
        }

        dragOrigin = screenshotPoint
        interactionState = .idle
    }

    override func mouseDragged(with event: NSEvent) {
        if case .editingText = interactionState { return }

        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = viewToScreenshot(viewPoint)

        if case .movingAnnotation(let idx, let original, let lastPoint) = interactionState {
            guard idx < annotations.count else { interactionState = .idle; return }
            let dx = point.x - lastPoint.x
            let dy = point.y - lastPoint.y
            annotations[idx] = annotations[idx].offsetBy(dx: dx, dy: dy)
            interactionState = .movingAnnotation(index: idx, original: original, lastPoint: point)
            needsDisplay = true
            return
        }

        if case .editingHandle(let idx, let handle, _) = interactionState {
            guard idx < annotations.count else { interactionState = .idle; return }
            annotations[idx] = annotations[idx].moving(handle, to: point)
            needsDisplay = true
            return
        }

        let dragRect = rectFromDrag(origin: dragOrigin, current: point)
        if dragModifiers.contains(.command) && dragModifiers.contains(.shift) {
            currentAnnotation = .ellipse(rect: dragRect, color: currentColor)
        } else if dragModifiers.contains(.option) {
            currentAnnotation = .crop(rect: dragRect)
        } else if dragModifiers.contains(.command) {
            currentAnnotation = .rectangle(rect: dragRect, color: currentColor)
        } else if dragModifiers.contains(.control) {
            currentAnnotation = .blur(rect: dragRect)
        } else if dragModifiers.contains(.shift) {
            currentAnnotation = .line(from: dragOrigin, to: point, color: currentColor)
        } else {
            currentAnnotation = .arrow(from: dragOrigin, to: point, color: currentColor)
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .editingText = interactionState { return }

        if case .movingAnnotation(let idx, let original, _) = interactionState {
            interactionState = .idle
            guard idx < annotations.count else { return }

            let moved = annotations[idx] != original
            if !moved {
                // Click on text → re-edit; click on other types → no-op
                if case .text = annotations[idx] {
                    startEditingTextAnnotation(at: idx)
                }
                return
            }

            // It was a drag — finalize move with undo
            let edited = annotations[idx]
            replaceAnnotation(at: idx, with: edited, old: original)
            return
        }

        if case .editingHandle(let idx, _, let original) = interactionState {
            interactionState = .idle
            guard idx < annotations.count else { return }
            let edited = annotations[idx]
            replaceAnnotation(at: idx, with: edited, old: original)
            return
        }

        guard let annotation = currentAnnotation else { return }
        currentAnnotation = nil

        // Ignore negligible drags
        let point = viewToScreenshot(convert(event.locationInWindow, from: nil))
        if abs(point.x - dragOrigin.x) < 2, abs(point.y - dragOrigin.y) < 2 { return }

        addAnnotation(annotation)
    }

    override func mouseMoved(with event: NSEvent) {
        if case .editingText = interactionState { return }

        if isTextMode {
            NSCursor.iBeam.set()
            if hoveredAnnotationIndex != nil {
                hoveredAnnotationIndex = nil
                needsDisplay = true
            }
            return
        }

        let viewPoint = convert(event.locationInWindow, from: nil)
        let screenshotPoint = viewToScreenshot(viewPoint)

        let hit = hitTestAnnotations(at: screenshotPoint)

        switch hit {
        case .handle(let index, let handle):
            let isTextEdge = (handle == .left || handle == .right)
            (isTextEdge ? NSCursor.resizeLeftRight : NSCursor.crosshair).set()
            if hoveredAnnotationIndex != index {
                hoveredAnnotationIndex = index
                needsDisplay = true
            }
        case .body(let index):
            NSCursor.openHand.set()
            if hoveredAnnotationIndex != index {
                hoveredAnnotationIndex = index
                needsDisplay = true
            }
        case .none:
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
        if case .editingText = interactionState {
            // Font size: Cmd+= / Cmd++ to increase, Cmd+- to decrease
            if event.modifierFlags.contains(.command) {
                if event.keyCode == 24 { // = / + key
                    adjustFontSize(delta: 2)
                    return true
                }
                if event.keyCode == 27 { // - key
                    adjustFontSize(delta: -2)
                    return true
                }
            }
        }
        if event.keyCode == 36, let action = SaveAction.action(for: event.modifierFlags) {
            finalizeTextEditing()
            performAction(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // When text view is active, let it handle all keys
        if case .editingText = interactionState { return }

        if event.keyCode == 53 { // ESC
            handleEscape()
            return
        }

        // Delete / Forward Delete — remove hovered annotation
        if event.keyCode == 51 || event.keyCode == 117 {
            if let idx = hoveredAnnotationIndex {
                removeAnnotation(at: idx)
                hoveredAnnotationIndex = nil
            }
            return
        }

        let noModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == []
        if noModifiers, handleUnmodifiedKey(event.keyCode) { return }

        super.keyDown(with: event)
    }

    private func handleEscape() {
        if isTextMode {
            isTextMode = false
            NSCursor.arrow.set()
            return
        }
        for i in stride(from: annotations.count - 1, through: 0, by: -1) {
            if case .crop = annotations[i] { removeAnnotation(at: i) }
        }
    }

    /// Handles single-key shortcuts (no modifiers). Returns true if the key was consumed.
    private func handleUnmodifiedKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 32: // U — insert UTC timestamp at cursor
            insertTimestamp()
            return true
        case 17: // T — toggle text mode
            isTextMode.toggle()
            (isTextMode ? NSCursor.iBeam : NSCursor.arrow).set()
            return true
        case 8: // C — toggle color (red/blue)
            toggleColor()
            return true
        default:
            // Digit keys — place numbered badge at cursor
            if let digit = Self.digitKeyCodes[keyCode] {
                placeBadge(digit: digit)
                return true
            }
            return false
        }
    }

    /// Layout-independent key codes for the digit row, 1 through 0
    private static let digitKeyCodes: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0
    ]

    /// Places a numbered badge at the cursor. A digit pressed shortly after the
    /// previous one extends that badge's number instead (1, 2 → 12).
    private func placeBadge(digit: Int) {
        let now = Date()
        if let last = lastBadge,
           now.timeIntervalSince(last.time) < Self.badgeCombineInterval,
           last.index < annotations.count,
           case .badge(let center, let number, let color) = annotations[last.index],
           number < 10 {
            let combined = Annotation.badge(center: center, number: number * 10 + digit, color: color)
            replaceAnnotation(at: last.index, with: combined, old: annotations[last.index])
            lastBadge = (last.index, now)
            return
        }

        guard let window = window else { return }
        let viewPoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let screenshotPoint = viewToScreenshot(viewPoint)
        addAnnotation(.badge(center: screenshotPoint, number: digit, color: currentColor))
        lastBadge = (annotations.count - 1, now)
    }

    /// Toggles the hovered annotation's color, or the drawing color when nothing is hovered
    private func toggleColor() {
        if let idx = hoveredAnnotationIndex, idx < annotations.count,
           let color = annotations[idx].color {
            currentColor = color.toggled
            replaceAnnotation(at: idx, with: annotations[idx].withColor(currentColor),
                              old: annotations[idx])
            return
        }
        currentColor = currentColor.toggled
    }

    @objc func undo(_ sender: Any?) {
        undoManager?.undo()
        needsDisplay = true
    }

    @objc func redo(_ sender: Any?) {
        undoManager?.redo()
        needsDisplay = true
    }

    // MARK: - Text Annotation

    /// Returns the index of an annotation whose body contains the given screenshot-space point
    func annotationBodyAt(_ point: CGPoint) -> Int? {
        if case .body(let index) = hitTestAnnotations(at: point) {
            return index
        }
        return nil
    }

    /// Returns the index of a text annotation at the given screenshot-space point
    func textAnnotationAt(_ point: CGPoint) -> Int? {
        for i in stride(from: annotations.count - 1, through: 0, by: -1) {
            guard case .text = annotations[i],
                  annotations[i].bodyContains(point, hitRadius: 0) else { continue }
            return i
        }
        return nil
    }

    private func placeTextAnnotation(at screenshotPoint: CGPoint) {
        let scale = screenshotToViewScale()
        let viewOrigin = screenshotToView(screenshotPoint)
        let viewWidth = 300 * scale
        let viewFontSize = textFontSize * scale

        let frame = CGRect(x: viewOrigin.x, y: viewOrigin.y, width: viewWidth, height: viewFontSize * 1.5)
        let textView = createTextView(frame: frame, fontSize: viewFontSize)
        addSubview(textView)
        interactionState = .editingText(textView: textView, existingIndex: nil)
        window?.makeFirstResponder(textView)
    }

    private func startEditingTextAnnotation(at index: Int) {
        guard case .text(let origin, let width, let content, let fontSize, let color) = annotations[index]
        else { return }
        currentColor = color
        let scale = screenshotToViewScale()
        let viewOrigin = screenshotToView(origin)
        let viewWidth = width * scale
        let viewFontSize = fontSize * scale

        let rect = Annotation.textBoundingRect(
            origin: origin, width: width, content: content, fontSize: fontSize
        )
        let viewHeight = rect.height * scale

        let frame = CGRect(x: viewOrigin.x, y: viewOrigin.y, width: viewWidth, height: viewHeight)
        let textView = createTextView(frame: frame, fontSize: viewFontSize)
        textView.string = content
        addSubview(textView)
        interactionState = .editingText(textView: textView, existingIndex: index)
        textFontSize = fontSize
        window?.makeFirstResponder(textView)
        needsDisplay = true
    }

    private func createTextView(frame: CGRect, fontSize: CGFloat) -> NSTextView {
        let textView = IsolatedUndoTextView(frame: frame)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.maxSize = NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude)

        let font = NSFont.boldSystemFont(ofSize: fontSize)
        let textColor = currentColor.nsColor
        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.typingAttributes = [.font: font, .foregroundColor: textColor]

        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        textView.delegate = self
        return textView
    }

    func finalizeTextEditing() {
        guard case .editingText(let textView, let existingIndex) = interactionState else { return }
        let content = textView.string
        let viewFrame = textView.frame

        textView.removeFromSuperview()
        interactionState = .idle
        window?.makeFirstResponder(self)

        // Convert view frame back to screenshot coords
        let scale = screenshotToViewScale()
        let screenshotOrigin = viewToScreenshot(CGPoint(x: viewFrame.minX, y: viewFrame.minY))
        let screenshotWidth = viewFrame.width / scale

        if let idx = existingIndex {
            if content.isEmpty {
                removeAnnotation(at: idx)
            } else {
                let newAnnotation = Annotation.text(
                    origin: screenshotOrigin, width: screenshotWidth,
                    content: content, fontSize: textFontSize, color: currentColor
                )
                let old = annotations[idx]
                replaceAnnotation(at: idx, with: newAnnotation, old: old)
            }
        } else {
            if !content.isEmpty {
                let annotation = Annotation.text(
                    origin: screenshotOrigin, width: screenshotWidth,
                    content: content, fontSize: textFontSize, color: currentColor
                )
                addAnnotation(annotation)
            }
        }

        isTextMode = false
        NSCursor.arrow.set()
        needsDisplay = true
    }

    private func insertTimestamp() {
        guard let window = window else { return }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let viewPoint = convert(windowPoint, from: nil)
        let screenshotPoint = viewToScreenshot(viewPoint)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let timestamp = formatter.string(from: captureDate)

        let font = NSFont.boldSystemFont(ofSize: textFontSize)
        let textWidth = (timestamp as NSString).size(withAttributes: [.font: font]).width + 4

        let annotation = Annotation.text(
            origin: screenshotPoint, width: textWidth,
            content: timestamp, fontSize: textFontSize, color: currentColor
        )
        addAnnotation(annotation)
        needsDisplay = true
    }

    private func adjustFontSize(delta: CGFloat) {
        let newSize = max(textFontSize + delta, 8)
        textFontSize = newSize
        guard case .editingText(let textView, _) = interactionState else { return }
        let scale = screenshotToViewScale()
        let viewFontSize = newSize * scale
        let font = NSFont.boldSystemFont(ofSize: viewFontSize)
        textView.font = font
        textView.typingAttributes = [.font: font, .foregroundColor: currentColor.nsColor]
        // Re-apply font to all existing text
        if !textView.string.isEmpty {
            let range = NSRange(location: 0, length: (textView.string as NSString).length)
            textView.textStorage?.addAttribute(.font, value: font, range: range)
        }
        needsDisplay = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            finalizeTextEditing()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: - Hit Testing

    /// Single-pass hit test: checks handles first, then body, for each annotation top-to-bottom
    private func hitTestAnnotations(at point: CGPoint) -> AnnotationHitTestResult {
        let ir = screenshotRect
        let scale = ir.width / screenshot.size.width
        let handleHitRadius: CGFloat = 10.0 / scale
        let bodyHitRadius: CGFloat = 5.0 / scale

        for i in stride(from: annotations.count - 1, through: 0, by: -1) {
            // Check handles first
            var bestHandle: AnnotationHandle?
            var bestDist = CGFloat.greatestFiniteMagnitude
            for (handle, handlePoint) in annotations[i].handles {
                let dist = hypot(point.x - handlePoint.x, point.y - handlePoint.y)
                if dist <= handleHitRadius && dist < bestDist {
                    bestDist = dist
                    bestHandle = handle
                }
            }
            if let handle = bestHandle {
                return .handle(index: i, handle: handle)
            }
            // Check body
            if annotations[i].bodyContains(point, hitRadius: bodyHitRadius) {
                return .body(index: i)
            }
        }
        return .none
    }

    /// Returns the annotation index and handle at the given screenshot-space point
    func handleAt(_ point: CGPoint) -> (index: Int, handle: AnnotationHandle)? {
        if case .handle(let index, let handle) = hitTestAnnotations(at: point) {
            return (index, handle)
        }
        return nil
    }

    // MARK: - Annotations + Undo

    private func invalidateBlurCache() {
        blurCache.removeAll()
    }

    private func replaceAnnotation(at index: Int, with new: Annotation, old: Annotation) {
        guard index < annotations.count else { return }
        annotations[index] = new
        invalidateBlurCache()
        undoManager?.registerUndo(withTarget: self) { target in
            target.replaceAnnotation(at: index, with: old, old: new)
        }
        needsDisplay = true
    }

    private func addAnnotation(_ annotation: Annotation) {
        if case .crop = annotation {
            undoManager?.beginUndoGrouping()
            for i in stride(from: annotations.count - 1, through: 0, by: -1) {
                if case .crop = annotations[i] { removeAnnotation(at: i) }
            }
        }
        annotations.append(annotation)
        invalidateBlurCache()
        undoManager?.registerUndo(withTarget: self) { target in
            target.removeLastAnnotation()
        }
        if case .crop = annotation {
            undoManager?.endUndoGrouping()
        }
        needsDisplay = true
    }

    private func removeAnnotation(at index: Int) {
        guard index < annotations.count else { return }
        let removed = annotations.remove(at: index)
        invalidateBlurCache()
        undoManager?.registerUndo(withTarget: self) { target in
            target.insertAnnotation(removed, at: index)
        }
        needsDisplay = true
    }

    private func insertAnnotation(_ annotation: Annotation, at index: Int) {
        guard index <= annotations.count else { return }
        annotations.insert(annotation, at: index)
        invalidateBlurCache()
        undoManager?.registerUndo(withTarget: self) { target in
            target.removeAnnotation(at: index)
        }
        needsDisplay = true
    }

    private func removeLastAnnotation() {
        guard let removed = annotations.popLast() else { return }
        invalidateBlurCache()
        undoManager?.registerUndo(withTarget: self) { target in
            target.addAnnotation(removed)
        }
        needsDisplay = true
    }

    // MARK: - Save

    private func performAction(_ action: SaveAction) {
        guard let cgImage = compositeAsCGImage() else {
            window?.close()
            return
        }

        let succeeded = appDelegate?.handleAction(action, cgImage: cgImage, captureDate: captureDate) ?? true
        if succeeded {
            window?.close()
        }
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

        // First pass: blur annotations (between screenshot and other annotations)
        for annotation in annotations {
            if case .blur = annotation { draw(annotation) }
        }

        // Second pass: non-blur, non-crop annotations
        for annotation in annotations {
            if case .crop = annotation { continue }
            if case .blur = annotation { continue }
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

// MARK: - NSTextViewDelegate

extension AnnotationView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(insertNewline(_:)) {
            if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            finalizeTextEditing()
            return true
        }
        if selector == #selector(cancelOperation(_:)) {
            finalizeTextEditing()
            return true
        }
        return false
    }
}
