import AppKit
import Carbon.HIToolbox

final class AnnotationView: NSView {
    /// Save / Copy / Upload with the rendered screenshot (the window decides whether to close)
    var onAction: (SaveAction, RenderedScreenshot) -> Void = { _, _ in }
    private let screenshot: NSImage
    private let renderer: AnnotationRenderer
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
    /// Color of new annotations; the toolbar's palette sets it, C cycles it
    var drawingColor: AnnotationColor = .red {
        didSet { onStateChange?() }
    }

    /// What a plain drag or click does; modifier-drags pick their own tool whatever is selected
    var selectedTool: AnnotationTool = .arrow {
        didSet { onStateChange?() }
    }
    /// Called when the tool or drawing color changes, so the toolbar can follow
    var onStateChange: (() -> Void)?

    /// Last badge placed via a digit key, for combining quick presses into one number (1, 2 → 12)
    private var lastBadge: (index: Int, time: Date)?
    private static let badgeCombineInterval: TimeInterval = 0.5

    /// Rect where the screenshot is drawn on screen
    private var screenshotRect: NSRect { bounds }

    private lazy var _undoManager = UndoManager()
    override var undoManager: UndoManager? { _undoManager }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, screenshot: NSImage) {
        self.screenshot = screenshot
        renderer = AnnotationRenderer(screenshot: screenshot)
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
        renderer.draw(
            annotations, current: currentAnnotation, skipping: editingTextIdx, uncachedIndex: draggedAnnotationIndex
        )

        // Draw handles for hovered annotation (skip when actively editing text)
        if activeTV == nil, currentAnnotation == nil, let idx = hoveredAnnotationIndex,
           idx < annotations.count {
            renderer.drawHandles(for: annotations[idx], textPadding: 4.0 / screenshotToViewScale())
        }

        // Draw live border around active text view during editing
        if let textView = activeTV {
            drawActiveTextBorder(textView: textView)
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawActiveTextBorder(textView: NSTextView) {
        let viewFrame = textView.frame
        let padding: CGFloat = 4.0
        let topLeft = viewToScreenshot(CGPoint(x: viewFrame.minX - padding, y: viewFrame.minY))
        let bottomRight = viewToScreenshot(CGPoint(x: viewFrame.maxX + padding, y: viewFrame.maxY))
        renderer.drawActiveTextBorder(CGRect(
            x: topLeft.x, y: topLeft.y,
            width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y
        ))
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let screenshotPoint = viewToScreenshot(viewPoint)
        dragModifiers = event.modifierFlags
        lastBadge = nil

        let hasDrawModifiers = AnnotationTool(modifiers: dragModifiers) != nil

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
                addAnnotation(.badge(center: screenshotPoint, number: nextBadgeNumber(), color: drawingColor))
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
        currentAnnotation = tool.annotation(from: dragOrigin, to: point, color: drawingColor)
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
                if Int(event.keyCode) == kVK_ANSI_Equal { // = / + key
                    adjustFontSize(larger: true)
                    return true
                }
                if Int(event.keyCode) == kVK_ANSI_Minus {
                    adjustFontSize(larger: false)
                    return true
                }
            }
        }
        if Int(event.keyCode) == kVK_Return, let action = SaveAction.action(for: event.modifierFlags) {
            perform(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // When text view is active, let it handle all keys
        if case .editingText = interactionState { return }

        if Int(event.keyCode) == kVK_Escape {
            handleEscape()
            return
        }

        // Delete / Forward Delete — remove hovered annotation
        if [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)) {
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
        switch Int(keyCode) {
        case kVK_ANSI_U: // insert UTC timestamp at cursor
            insertTimestamp()
        case kVK_ANSI_T: // start typing text at cursor
            startTextAtCursor(keyCode: keyCode)
        case kVK_ANSI_C: // next palette color
            cycleColor()
        default:
            if let tool = AnnotationTool(keyCode: keyCode) {
                selectedTool = tool
            } else if let digit = Self.digitKeyCodes[Int(keyCode)] {
                placeBadge(digit: digit)  // numbered badge at cursor
            } else {
                return false
            }
        }
        return true
    }

    /// Layout-independent key codes for the digit row, 1 through 0
    private static let digitKeyCodes: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9, kVK_ANSI_0: 0,
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
        addAnnotation(.badge(center: screenshotPoint, number: digit, color: drawingColor))
        lastBadge = (annotations.count - 1, now)
    }

    /// Moves the hovered annotation to the next palette color, or the drawing color when nothing is hovered
    private func cycleColor() {
        if let idx = hoveredAnnotationIndex, idx < annotations.count,
           let color = annotations[idx].color {
            drawingColor = color.next
            replaceAnnotation(at: idx, with: annotations[idx].withColor(drawingColor),
                              old: annotations[idx])
            return
        }
        drawingColor = drawingColor.next
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
        drawingColor = color
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
        let textColor = drawingColor.nsColor
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
                    content: content, fontSize: textFontSize, color: drawingColor
                )
                let old = annotations[idx]
                replaceAnnotation(at: idx, with: newAnnotation, old: old)
            }
        } else {
            if !content.isEmpty {
                let annotation = Annotation.text(
                    origin: screenshotOrigin, width: screenshotWidth,
                    content: content, fontSize: textFontSize, color: drawingColor
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
            content: timestamp, fontSize: textFontSize, color: drawingColor
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
        textView.typingAttributes = [.font: font, .foregroundColor: drawingColor.nsColor]
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

    /// Handles first, then body, for each annotation top to bottom; radii are 10pt / 5pt on screen
    private func hitTestAnnotations(at point: CGPoint) -> AnnotationHitTestResult {
        let scale = screenshotToViewScale()
        return annotations.hitTest(point, handleRadius: 10.0 / scale, bodyRadius: 5.0 / scale)
    }

    /// Returns the annotation index and handle at the given screenshot-space point
    func handleAt(_ point: CGPoint) -> (index: Int, handle: AnnotationHandle)? {
        if case .handle(let index, let handle) = hitTestAnnotations(at: point) {
            return (index, handle)
        }
        return nil
    }

    // MARK: - Annotations + Undo

    private func pruneBlurCache() {
        renderer.pruneBlurCache(keeping: annotations)
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

    // MARK: - Save

    /// Save / Copy / Upload (the toolbar's buttons, modifier+Return)
    func perform(_ action: SaveAction) {
        finalizeTextEditing()
        guard let cgImage = renderer.render(annotations) else {
            // Keep the window (and the edits) instead of closing with nothing saved
            NSSound.beep()
            StatusHUD.show("Couldn't render the screenshot", detail: "Try again", style: .failure)
            return
        }
        let shot = RenderedScreenshot(cgImage: cgImage, pixelsPerPoint: renderer.pixelsPerPoint, captureDate: captureDate)
        onAction(action, shot)
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
