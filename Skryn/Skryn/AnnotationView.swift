import AppKit
import Carbon.HIToolbox

final class AnnotationView: NSView {
    /// Save / Copy / Upload with the rendered screenshot (the window decides whether to close)
    var onAction: (SaveAction, RenderedScreenshot) -> Void = { _, _ in }
    private let screenshot: NSImage
    private let renderer: AnnotationRenderer
    let captureDate = Date()
    var annotations: [Annotation] = []
    var currentAnnotation: Annotation?
    private var dragOrigin: CGPoint = .zero
    private var dragModifiers: NSEvent.ModifierFlags = []

    enum InteractionState {
        case idle
        case editingHandle(index: Int, handle: AnnotationHandle, original: Annotation)
        case movingAnnotation(index: Int, original: Annotation, lastPoint: CGPoint)
        case editingText(textView: NSTextView, existingIndex: Int?)
        /// Space held at mouse-down: the drag pans the zoomed canvas
        case panning(lastPoint: CGPoint)
    }

    var interactionState: InteractionState = .idle

    /// Index of the annotation currently being moved or resized, if any
    private var draggedAnnotationIndex: Int? {
        switch interactionState {
        case .editingHandle(let index, _, _), .movingAnnotation(let index, _, _): return index
        case .idle, .editingText, .panning: return nil
        }
    }
    var hoveredAnnotationIndex: Int?
    /// The annotation clicked or just drawn: it keeps its handles, and Delete, the arrow keys, ⌘D,
    /// C, [ ], the palette and the width control act on it. Cleared by clicking empty canvas, Esc, and undo/redo.
    var selectedIndex: Int? {
        didSet {
            guard selectedIndex != oldValue else { return }
            needsDisplay = true
            onStateChange?()
        }
    }
    /// The selected annotation, if the index is still valid
    var selectedAnnotation: Annotation? {
        guard let selectedIndex, selectedIndex < annotations.count else { return nil }
        return annotations[selectedIndex]
    }
    /// The color the palette shows: the selection's, else the drawing color
    var displayedColor: AnnotationColor { selectedAnnotation?.color ?? drawingColor }
    /// The line weight the width control shows: the selection's, else the drawing width
    var displayedWidth: StrokeWidth { selectedAnnotation?.strokeWidth ?? drawingWidth }
    /// Line weight of new arrows, lines and shapes; the toolbar sets it, [ and ] step it
    var drawingWidth: StrokeWidth = .medium {
        didSet { onStateChange?() }
    }
    var textFontSize: CGFloat = 24
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
    var lastBadge: (index: Int, time: Date)?

    /// Zoom and pan; fit (zoom 1) draws the screenshot over the whole view
    private var viewport: CanvasViewport
    /// Rect where the screenshot is drawn on screen
    private var screenshotRect: NSRect { viewport.imageRect }
    /// Space is down: drags pan instead of drawing
    private var isSpaceHeld = false

    private lazy var _undoManager = UndoManager()
    override var undoManager: UndoManager? { _undoManager }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, screenshot: NSImage) {
        self.screenshot = screenshot
        renderer = AnnotationRenderer(screenshot: screenshot)
        viewport = CanvasViewport(viewSize: frame.size, imageSize: screenshot.size)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        // Edge of the screenshot, visible over dark and light content alike (on screen only, not exported)
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        updateTrackingAreas()
    }

    // MARK: - Hint

    /// A quiet pill over the top of the canvas for the first few editors, gone with the first mark
    private var hint: NSView?
    private static let hintShows = 5

    /// The editor window calls this (tests create views without counting as an editor shown)
    func showHintIfNew() {
        let shown = UserDefaults.standard.integer(forKey: Defaults.editorHintCount)
        guard shown < Self.hintShows, bounds.width > 360 else { return }
        UserDefaults.standard.set(shown + 1, forKey: Defaults.editorHintCount)

        let pill = EditorHint.make()
        addSubview(pill)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.topAnchor.constraint(equalTo: topAnchor, constant: 14),
        ])
        hint = pill
    }

    func dismissHint() {
        guard let hint else { return }
        self.hint = nil
        HUDMotion.fade(hint, visible: false)
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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        viewport.viewSize = newSize
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
    func screenshotToViewScale() -> CGFloat {
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

        renderer.chromeScale = 1 / viewport.zoom
        var activeTV: NSTextView?
        var editingTextIdx: Int?
        if case .editingText(let textView, let idx) = interactionState {
            (activeTV, editingTextIdx) = (textView, idx)
        }
        renderer.draw(
            annotations, current: currentAnnotation, skipping: editingTextIdx, uncachedIndex: draggedAnnotationIndex
        )

        // Handles of the selected and hovered annotations (none while drawing or editing text)
        if activeTV == nil, currentAnnotation == nil {
            let padding = 4.0 / screenshotToViewScale()
            for idx in Set([selectedIndex, hoveredAnnotationIndex].compactMap { $0 }) where idx < annotations.count {
                renderer.drawHandles(for: annotations[idx], textPadding: padding)
            }
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
        if isSpaceHeld {
            interactionState = .panning(lastPoint: viewPoint)
            NSCursor.closedHand.set()
            return
        }

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
            selectedIndex = index
            interactionState = .editingHandle(
                index: index, handle: handle, original: annotations[index]
            )
            return
        }

        // Click on annotation body — select it, then move (if dragged) or re-edit text (if clicked)
        if !hasDrawModifiers, let idx = annotationBodyAt(screenshotPoint) {
            selectedIndex = idx
            interactionState = .movingAnnotation(
                index: idx, original: annotations[idx], lastPoint: screenshotPoint
            )
            return
        }

        selectedIndex = nil
        dragOrigin = screenshotPoint
        interactionState = .idle

        if !hasDrawModifiers, selectedTool.isClickTool {
            if selectedTool == .text {
                placeTextAnnotation(at: screenshotPoint)
            } else {
                addAnnotation(.badge(center: screenshotPoint, number: nextBadgeNumber(), color: drawingColor))
                selectedIndex = annotations.count - 1
            }
        }
    }

    /// Shift pressed during a drag that didn't start with it (a Shift start picks the line tool)
    private func constrainsDrag(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.shift) && !dragModifiers.contains(.shift)
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

        if case .panning(let last) = interactionState {
            changeViewport { $0.pan(by: CGVector(dx: viewPoint.x - last.x, dy: viewPoint.y - last.y)) }
            interactionState = .panning(lastPoint: viewPoint)
            return
        }

        if case .movingAnnotation(let idx, let original, let lastPoint) = interactionState {
            guard idx < annotations.count else { interactionState = .idle; return }
            let dx = point.x - lastPoint.x
            let dy = point.y - lastPoint.y
            annotations[idx] = annotations[idx].offsetBy(dx: dx, dy: dy)
            interactionState = .movingAnnotation(index: idx, original: original, lastPoint: point)
            needsDisplay = true
            return
        }

        if case .editingHandle(let idx, let handle, let original) = interactionState {
            guard idx < annotations.count else { interactionState = .idle; return }
            var target = point
            if constrainsDrag(event), let opposite = handle.opposite,
               let anchor = original.handles.first(where: { $0.handle == opposite })?.point {
                target = AnnotationTool.constrained(point, from: anchor, angular: handle == .from || handle == .to)
            }
            annotations[idx] = annotations[idx].moving(handle, to: target)
            needsDisplay = true
            return
        }

        let tool = AnnotationTool(modifiers: dragModifiers) ?? selectedTool
        let end = constrainsDrag(event)
            ? AnnotationTool.constrained(point, from: dragOrigin, angular: tool.constrainsAngle) : point
        currentAnnotation = tool.annotation(from: dragOrigin, to: end, color: drawingColor, width: drawingWidth)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .editingText = interactionState { return }
        if case .panning = interactionState {
            interactionState = .idle
            (isSpaceHeld ? NSCursor.openHand : NSCursor.arrow).set()
            return
        }

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
        selectedIndex = annotations.count - 1
    }

    override func mouseMoved(with event: NSEvent) {
        if case .editingText = interactionState { return }
        if isSpaceHeld { return }

        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    /// Re-evaluates hover after the annotation list changes without mouse movement (undo, redo, delete)
    func refreshHover() {
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
            // Empty canvas: what a click or drag here does
            (selectedTool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
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
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let step = Self.zoomKeys[Int(event.keyCode)] {
            zoomStep(step)
            return true
        }
        if Int(event.keyCode) == kVK_ANSI_D, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           !isEditingText {
            duplicateSelection()
            return true
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

        if Int(event.keyCode) == kVK_Space {
            if !isSpaceHeld, viewport.isZoomed {
                isSpaceHeld = true
                NSCursor.openHand.set()
            }
            return
        }

        // Delete / Forward Delete — remove the selected annotation, else the hovered one
        if [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)) {
            if let idx = selectedAnnotation != nil ? selectedIndex : hoveredAnnotationIndex {
                removeAnnotation(at: idx)
                selectedIndex = nil
                hoveredAnnotationIndex = nil
                refreshHover()
            }
            return
        }

        // Arrow keys nudge the selection 1pt, 10pt with Shift
        if let offset = Self.nudgeOffsets[Int(event.keyCode)], let selectedIndex, let annotation = selectedAnnotation {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            replaceAnnotation(at: selectedIndex, with: annotation.offsetBy(dx: offset.dx * step, dy: offset.dy * step),
                              old: annotation)
            return
        }

        let noModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == []
        if noModifiers, handleUnmodifiedKey(event.keyCode) { return }

        super.keyDown(with: event)
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
        selectedIndex = nil  // indices may have shifted
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
        selectedIndex = nil  // indices may have shifted
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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            finalizeTextEditing()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: - Zoom and pan

    override func keyUp(with event: NSEvent) {
        guard Int(event.keyCode) == kVK_Space, isSpaceHeld else { return super.keyUp(with: event) }
        isSpaceHeld = false
        if case .panning = interactionState { return }  // mouseUp restores the cursor
        refreshHover()
    }

    /// ⌘= zooms in, ⌘- out, ⌘0 back to fit (while typing text, ⌘= / ⌘- resize the font instead)
    private static let zoomKeys: [Int: CGFloat] = [kVK_ANSI_Equal: 1.5, kVK_ANSI_Minus: 1 / 1.5, kVK_ANSI_0: 0]

    /// Multiplies the zoom by `factor` around the pointer (the center if it's outside); 0 resets to fit
    private func zoomStep(_ factor: CGFloat) {
        let pointer = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        let anchor = pointer.flatMap { bounds.contains($0) ? $0 : nil } ?? CGPoint(x: bounds.midX, y: bounds.midY)
        changeViewport { factor == 0 ? $0.reset() : $0.zoom(to: $0.zoom * factor, around: anchor) }
    }

    override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        changeViewport { $0.zoom(to: $0.zoom * (1 + event.magnification), around: anchor) }
    }

    /// Two-finger scroll pans while zoomed in; at the fit there's nothing to scroll
    override func scrollWheel(with event: NSEvent) {
        guard viewport.isZoomed else { return super.scrollWheel(with: event) }
        let lineScale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10  // mouse wheels move in lines
        changeViewport {
            $0.pan(by: CGVector(dx: event.scrollingDeltaX * lineScale, dy: event.scrollingDeltaY * lineScale))
        }
    }

    /// Applies a zoom or pan. An open text editor is committed first: its frame is in view space.
    private func changeViewport(_ change: (inout CanvasViewport) -> Void) {
        var next = viewport
        change(&next)
        guard next != viewport else { return }
        finalizeTextEditing()
        viewport = next
        if !viewport.isZoomed { isSpaceHeld = false }
        needsDisplay = true
        if case .panning = interactionState { return }
        refreshHover()
    }

    // MARK: - Hit Testing

    /// Handles first, then body, for each annotation top to bottom; radii are 10pt / 5pt on screen
    func hitTestAnnotations(at point: CGPoint) -> AnnotationHitTestResult {
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

    func pruneBlurCache() {
        renderer.pruneBlurCache(keeping: annotations)
    }

    func replaceAnnotation(at index: Int, with new: Annotation, old: Annotation) {
        guard index < annotations.count else { return }
        annotations[index] = new
        pruneBlurCache()
        undoManager?.registerUndo(withTarget: self) { target in
            target.replaceAnnotation(at: index, with: old, old: new)
        }
        needsDisplay = true
    }

    func addAnnotation(_ annotation: Annotation) {
        if case .crop = annotation {
            undoManager?.beginUndoGrouping()
            for i in stride(from: annotations.count - 1, through: 0, by: -1) {
                if case .crop = annotations[i] { removeAnnotation(at: i) }
            }
        }
        dismissHint()
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

    func removeAnnotation(at index: Int) {
        guard index < annotations.count else { return }
        let removed = annotations.remove(at: index)
        pruneBlurCache()
        undoManager?.registerUndo(withTarget: self) { target in
            target.insertAnnotation(removed, at: index)
        }
        needsDisplay = true
    }

    func insertAnnotation(_ annotation: Annotation, at index: Int) {
        guard index <= annotations.count else { return }
        annotations.insert(annotation, at: index)
        pruneBlurCache()
        undoManager?.registerUndo(withTarget: self) { target in
            target.removeAnnotation(at: index)
        }
        needsDisplay = true
    }

    func removeLastAnnotation() {
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

    /// Marks that closing without saving would lose: every annotation, plus new text still being typed
    var unsavedMarkCount: Int {
        if case .editingText(let textView, .none) = interactionState, !textView.string.isEmpty {
            return annotations.count + 1
        }
        return annotations.count
    }

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
