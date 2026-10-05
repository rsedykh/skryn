import AppKit
import CoreImage
import ImageIO

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

    /// Index of the annotation currently being moved or resized, if any
    private var draggedAnnotationIndex: Int? {
        switch interactionState {
        case .editingHandle(let index, _, _), .movingAnnotation(let index, _, _): return index
        case .idle, .editingText: return nil
        }
    }
    private var hoveredAnnotationIndex: Int?
    private var textFontSize: CGFloat = 24
    private var currentColor: AnnotationColor = .red {
        didSet { onStateChange?() }
    }

    /// What a plain drag or click does; modifier-drags pick their own tool whatever is selected
    var selectedTool: AnnotationTool = .arrow {
        didSet { onStateChange?() }
    }
    /// Called when the tool or drawing color changes, so the toolbar can follow
    var onStateChange: (() -> Void)?
    var drawingColor: AnnotationColor { currentColor }

    /// Last badge placed via a digit key, for combining quick presses into one number (1, 2 → 12)
    private var lastBadge: (index: Int, time: Date)?
    private static let badgeCombineInterval: TimeInterval = 0.5

    /// Rect where the screenshot is drawn on screen
    private var screenshotRect: NSRect { bounds }

    /// Full screenshot coordinate space
    private var screenshotBounds: NSRect {
        NSRect(origin: .zero, size: screenshot.size)
    }

    private lazy var screenshotCG: CGImage? = screenshot.cgImage(
        forProposedRect: nil, context: nil, hints: nil
    )

    private static let blurCIContext = CIContext()
    private var blurCache: [BlurCacheKey: NSImage] = [:]
    /// Smallest pixellation block, in screenshot points, so small regions stay unreadable
    private static let minBlurBlockSize: CGFloat = 10

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
        // Edge of the screenshot, visible over dark and light content alike (on screen only, not exported)
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
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

        var activeTV: NSTextView?
        var editingTextIdx: Int?
        if case .editingText(let textView, let idx) = interactionState {
            (activeTV, editingTextIdx) = (textView, idx)
        }
        drawAnnotationPasses(skipping: editingTextIdx)

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

    /// Blurs first (between the screenshot and the rest), then everything else; the annotation being
    /// edited as text is skipped (its text view draws it). A blur being dragged is rendered uncached
    /// so intermediate frames don't pile up in the cache.
    private func drawAnnotationPasses(skipping editingIndex: Int?) {
        let draggedIdx = draggedAnnotationIndex
        for (i, annotation) in annotations.enumerated() where i != editingIndex {
            if case .blur(let rect) = annotation { drawBlur(rect, cache: i != draggedIdx) }
        }
        if let current = currentAnnotation, case .blur(let rect) = current {
            drawBlur(rect, cache: false)
        }
        for (i, annotation) in annotations.enumerated() where i != editingIndex {
            if case .blur = annotation { continue }
            draw(annotation)
        }
        if let current = currentAnnotation {
            if case .blur = current {} else { draw(current) }
        }
    }

    private func drawHandles(for annotation: Annotation) {
        // Text gets a dotted border, with its edge handles pushed out by the padding
        var textPadding: CGFloat = 0
        if case .text(let origin, let width, let content, let fontSize, _) = annotation {
            textPadding = 4.0 / screenshotToViewScale()
            let baseRect = Annotation.textBoundingRect(
                origin: origin, width: width, content: content, fontSize: fontSize
            )
            drawDashedBorder(baseRect.insetBy(dx: -textPadding, dy: 0))
        }

        for (handle, point) in annotation.handles {
            var drawPoint = point
            if textPadding > 0 {
                drawPoint.x += (handle == .left ? -textPadding : textPadding)
            }
            drawHandle(at: drawPoint)
        }
    }

    private func drawActiveTextBorder(textView: NSTextView) {
        let viewFrame = textView.frame
        let padding: CGFloat = 4.0
        let topLeft = viewToScreenshot(CGPoint(x: viewFrame.minX - padding, y: viewFrame.minY))
        let bottomRight = viewToScreenshot(CGPoint(x: viewFrame.maxX + padding, y: viewFrame.maxY))
        drawDashedBorder(CGRect(
            x: topLeft.x, y: topLeft.y,
            width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y
        ))

        let midY = (topLeft.y + bottomRight.y) / 2
        drawHandle(at: CGPoint(x: topLeft.x, y: midY))
        drawHandle(at: CGPoint(x: bottomRight.x, y: midY))
    }

    private func drawDashedBorder(_ rect: CGRect) {
        let borderPath = NSBezierPath(rect: rect)
        borderPath.lineWidth = 1.5
        let dashPattern: [CGFloat] = [4.0, 4.0]
        borderPath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
        NSColor.red.withAlphaComponent(0.5).setStroke()
        borderPath.stroke()
    }

    private func drawHandle(at point: CGPoint) {
        let handleRadius: CGFloat = 6.0
        let path = NSBezierPath(ovalIn: CGRect(
            x: point.x - handleRadius, y: point.y - handleRadius,
            width: handleRadius * 2, height: handleRadius * 2
        ))
        NSColor.white.setFill()
        path.fill()
        NSColor.red.setStroke()
        path.lineWidth = 2.0
        path.stroke()
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
            drawBadge(center: center, number: number, color: color)
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

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let screenshotPoint = viewToScreenshot(viewPoint)
        dragModifiers = event.modifierFlags
        lastBadge = nil

        let hasDrawModifiers = dragModifiers.contains(.shift)
            || dragModifiers.contains(.option)
            || dragModifiers.contains(.command)
            || dragModifiers.contains(.control)

        // If editing text: clicks inside the text view are handled by it.
        // A plain click elsewhere moves a new, still-empty text box there (T, then click);
        // any other click outside finalizes editing and continues to handle/body hit testing.
        if case .editingText(let textView, let existingIndex) = interactionState {
            if textView.frame.contains(viewPoint) {
                return
            }
            if existingIndex == nil, textView.string.isEmpty, !hasDrawModifiers {
                textView.setFrameOrigin(screenshotToView(screenshotPoint))
                needsDisplay = true
                return
            }
            finalizeTextEditing()
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

        if !hasDrawModifiers, selectedTool.isClickTool {
            if selectedTool == .text {
                placeTextAnnotation(at: screenshotPoint)
            } else {
                addAnnotation(.badge(center: screenshotPoint, number: nextBadgeNumber(), color: currentColor))
            }
        }
    }

    /// One more than the highest number on the screenshot, so clicking with the Number tool counts up
    private func nextBadgeNumber() -> Int {
        let numbers = annotations.compactMap { annotation -> Int? in
            if case .badge(_, let number, _) = annotation { return number }
            return nil
        }
        return min((numbers.max() ?? 0) + 1, 99)
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

        let tool = AnnotationTool(modifiers: dragModifiers) ?? selectedTool
        currentAnnotation = dragAnnotation(tool, from: dragOrigin, to: point)
        needsDisplay = true
    }

    /// The annotation a drag with `tool` draws; nil for tools placed by clicking.
    private func dragAnnotation(_ tool: AnnotationTool, from start: CGPoint, to end: CGPoint) -> Annotation? {
        let rect = rectFromDrag(origin: start, current: end)
        switch tool {
        case .arrow: return .arrow(from: start, to: end, color: currentColor)
        case .line: return .line(from: start, to: end, color: currentColor)
        case .rectangle: return .rectangle(rect: rect, color: currentColor)
        case .ellipse: return .ellipse(rect: rect, color: currentColor)
        case .blur: return .blur(rect: rect)
        case .crop: return .crop(rect: rect)
        case .text, .badge: return nil
        }
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

        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    /// Re-evaluates hover after the annotation list changes without mouse movement (undo, redo, delete)
    private func refreshHover() {
        guard let window else { return }
        if case .editingText = interactionState { return }
        updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func updateHover(at viewPoint: CGPoint) {
        guard bounds.contains(viewPoint) else {
            setHoveredIndex(nil)
            return
        }

        switch hitTestAnnotations(at: viewToScreenshot(viewPoint)) {
        case .handle(let index, let handle):
            let isTextEdge = (handle == .left || handle == .right)
            (isTextEdge ? NSCursor.resizeLeftRight : NSCursor.crosshair).set()
            setHoveredIndex(index)
        case .body(let index):
            NSCursor.openHand.set()
            setHoveredIndex(index)
        case .none:
            NSCursor.arrow.set()
            setHoveredIndex(nil)
        }
    }

    private func setHoveredIndex(_ index: Int?) {
        guard hoveredAnnotationIndex != index else { return }
        hoveredAnnotationIndex = index
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        setHoveredIndex(nil)
    }

    // MARK: - Key Events

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if case .editingText = interactionState {
            // Font size: Cmd+= / Cmd++ to increase, Cmd+- to decrease
            if event.modifierFlags.contains(.command) {
                if event.keyCode == 24 { // = / + key
                    adjustFontSize(larger: true)
                    return true
                }
                if event.keyCode == 27 { // - key
                    adjustFontSize(larger: false)
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
                refreshHover()
            }
            return
        }

        let noModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == []
        if noModifiers, handleUnmodifiedKey(event.keyCode) { return }

        super.keyDown(with: event)
    }

    private func handleEscape() {
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
        case 17: // T — start typing text at cursor
            startTextAtCursor(keyCode: keyCode)
            return true
        case 8: // C — toggle color (red/blue)
            toggleColor()
            return true
        default:
            if let tool = Self.toolKeyCodes[keyCode] {
                selectedTool = tool
                return true
            }
            // Digit keys — place numbered badge at cursor
            if let digit = Self.digitKeyCodes[keyCode] {
                placeBadge(digit: digit)
                return true
            }
            return false
        }
    }

    /// Layout-independent key codes that pick a tool, matching `AnnotationTool.key` (A, L, R, O, B, X)
    private static let toolKeyCodes: [UInt16: AnnotationTool] = [
        0: .arrow, 37: .line, 15: .rectangle, 31: .ellipse, 11: .blur, 7: .crop
    ]

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

    /// Moves the hovered annotation to the next palette color, or the drawing color when nothing is hovered
    private func toggleColor() {
        if let idx = hoveredAnnotationIndex, idx < annotations.count,
           let color = annotations[idx].color {
            currentColor = color.next
            replaceAnnotation(at: idx, with: annotations[idx].withColor(currentColor),
                              old: annotations[idx])
            return
        }
        currentColor = currentColor.next
    }

    /// The toolbar's palette: sets the drawing color (not a hovered annotation's).
    func setDrawingColor(_ color: AnnotationColor) {
        currentColor = color
    }

    /// The toolbar's Save / Copy / Upload buttons, same as modifier+Return.
    func perform(_ action: SaveAction) {
        finalizeTextEditing()
        performAction(action)
    }

    // NSTextView doesn't implement undo:/redo:, so while a text view is being edited
    // these actions reach us through the responder chain — route them to its own manager.
    @objc func undo(_ sender: Any?) {
        if case .editingText(let textView, _) = interactionState {
            textView.undoManager?.undo()
            return
        }
        undoManager?.undo()
        lastBadge = nil
        needsDisplay = true
        refreshHover()
    }

    @objc func redo(_ sender: Any?) {
        if case .editingText(let textView, _) = interactionState {
            textView.undoManager?.redo()
            return
        }
        undoManager?.redo()
        lastBadge = nil
        needsDisplay = true
        refreshHover()
    }

    // MARK: - Text Annotation

    /// Returns the index of an annotation whose body contains the given screenshot-space point
    func annotationBodyAt(_ point: CGPoint) -> Int? {
        if case .body(let index) = hitTestAnnotations(at: point) {
            return index
        }
        return nil
    }

    /// Opens a text editor at the cursor. Over an existing text annotation, edits that one instead.
    private func startTextAtCursor(keyCode: UInt16) {
        guard let window else { return }
        let point = viewToScreenshot(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        let index: Int?
        switch hitTestAnnotations(at: point) {
        case .handle(let i, _), .body(let i): index = i
        case .none: index = nil
        }
        if let index, case .text = annotations[index] {
            startEditingTextAnnotation(at: index)
        } else {
            placeTextAnnotation(at: point)
        }
        if case .editingText(let textView as IsolatedUndoTextView, _) = interactionState {
            textView.swallowsRepeatOfKeyCode = keyCode
        }
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

        NSCursor.arrow.set()
        needsDisplay = true
    }

    private func insertTimestamp() {
        guard let window = window else { return }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let viewPoint = convert(windowPoint, from: nil)
        let screenshotPoint = viewToScreenshot(viewPoint)

        let timestamp = Self.utcTimestampFormatter.string(from: captureDate)

        let font = NSFont.boldSystemFont(ofSize: textFontSize)
        let textWidth = (timestamp as NSString).size(withAttributes: [.font: font]).width + 4

        let annotation = Annotation.text(
            origin: screenshotPoint, width: textWidth,
            content: timestamp, fontSize: textFontSize, color: currentColor
        )
        addAnnotation(annotation)
        needsDisplay = true
    }

    private static let utcTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return formatter
    }()

    private func adjustFontSize(larger: Bool) {
        let newSize = Annotation.steppedFontSize(textFontSize, larger: larger)
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

    /// Drops cached blur images whose rect no longer belongs to any blur annotation.
    /// Blur output depends only on the screenshot and the rect, so entries stay valid otherwise.
    private func pruneBlurCache() {
        let liveKeys = Set(annotations.compactMap { annotation -> BlurCacheKey? in
            if case .blur(let rect) = annotation { return BlurCacheKey(rect) }
            return nil
        })
        blurCache = blurCache.filter { liveKeys.contains($0.key) }
    }

    private func replaceAnnotation(at index: Int, with new: Annotation, old: Annotation) {
        guard index < annotations.count else { return }
        annotations[index] = new
        pruneBlurCache()
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
        pruneBlurCache()
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
        pruneBlurCache()
        undoManager?.registerUndo(withTarget: self) { target in
            target.insertAnnotation(removed, at: index)
        }
        needsDisplay = true
    }

    private func insertAnnotation(_ annotation: Annotation, at index: Int) {
        guard index <= annotations.count else { return }
        annotations.insert(annotation, at: index)
        pruneBlurCache()
        undoManager?.registerUndo(withTarget: self) { target in
            target.removeAnnotation(at: index)
        }
        needsDisplay = true
    }

    private func removeLastAnnotation() {
        guard let removed = annotations.popLast() else { return }
        pruneBlurCache()
        undoManager?.registerUndo(withTarget: self) { target in
            target.addAnnotation(removed)
        }
        needsDisplay = true
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

extension AnnotationView {
    // MARK: - Save

    private func performAction(_ action: SaveAction) {
        guard let cgImage = compositeAsCGImage() else {
            // Keep the window (and the edits) instead of closing with nothing saved
            NSSound.beep()
            StatusHUD.show("Couldn't render the screenshot", detail: "Try again", style: .failure)
            return
        }

        // Pixels per point, so 1x output can be sized in points
        let scale = CGFloat(screenshotCG?.width ?? cgImage.width) / max(screenshot.size.width, 1)
        let succeeded = appDelegate?.handleAction(
            action, cgImage: cgImage, pixelsPerPoint: scale, captureDate: captureDate
        ) ?? true
        if succeeded {
            window?.close()
        }
    }

    private func compositeAsCGImage() -> CGImage? {
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

        guard let cgImage = ctx.makeImage() else { return nil }
        return cropped(cgImage, pointSize: pointSize)
    }

    /// `image` cut to the crop annotation, if there is one (crop is in points; the image in pixels).
    private func cropped(_ image: CGImage, pointSize: CGSize) -> CGImage {
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
}

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
