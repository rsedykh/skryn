import AppKit

@MainActor
enum SelectionOverlay {
    /// Drags smaller than this (in either dimension) select the whole screen.
    static let minSelectionSize: CGFloat = 8

    /// Shows a dimmed, borderless overlay over `screen` and lets the user drag a rectangle; nil if the user
    /// pressed Esc. A click without dragging (or a drag smaller than ~8pt) selects the whole screen.
    /// `fullScreenVerb` finishes the hint ("Click to record the full screen"); `accessory` (the recording
    /// switch bar) sits at the bottom of the screen and swallows its own clicks.
    /// Returns once the overlay has faded out and left the screen, so a capture never includes it.
    static func pickArea(on screen: NSScreen, fullScreenVerb: String, accessory: NSView? = nil) async -> CaptureArea? {
        let hint = "Drag to select an area \u{00B7} Click to \(fullScreenVerb) the full screen \u{00B7} Esc to cancel"
        let window = SelectionOverlayWindow(screen: screen, hint: hint, accessory: accessory)
        // Losing key status (Cmd+Tab, a click on another display) cancels, since Esc can't reach us anymore
        let resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { window.selectionView.finish(nil) }
        }
        let result: CGRect? = await withCheckedContinuation { continuation in
            window.selectionView.onFinish = { continuation.resume(returning: $0) }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(window.selectionView)
            window.selectionView.animateIn()
        }
        NotificationCenter.default.removeObserver(resignObserver)
        window.orderOut(nil)
        window.close()
        return result.map { CaptureArea(screen: screen, rect: $0) }
    }

    /// Converts two drag points in view coordinates (bottom-left origin) into a top-left-origin rect,
    /// clamped to the screen and rounded to integral points. Returns the full screen for tiny drags.
    static func selectionRect(from start: NSPoint, to end: NSPoint, in screenSize: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: screenSize)
        let viewRect = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        ).intersection(bounds)
        guard !viewRect.isNull,
              viewRect.width >= minSelectionSize, viewRect.height >= minSelectionSize else { return bounds }
        let flipped = CGRect(
            x: viewRect.minX, y: screenSize.height - viewRect.maxY,
            width: viewRect.width, height: viewRect.height
        )
        return flipped.integral.intersection(bounds)
    }
}

private final class SelectionOverlayWindow: OverlayPanel {
    let selectionView: SelectionView

    init(screen: NSScreen, hint: String, accessory: NSView?) {
        // The accessory sits above the Dock, like the ⇧⌘5 bar
        let barInset = max(screen.visibleFrame.minY - screen.frame.minY, 0) + 32
        selectionView = SelectionView(
            frame: NSRect(origin: .zero, size: screen.frame.size), hint: hint, accessory: accessory,
            barBottomInset: barInset
        )
        // Above the menu bar and Dock, but below pop-up menus so the device menus aren't hidden behind us
        super.init(frame: screen.frame, level: NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1))
        contentView = selectionView
        onEscape = { [weak selectionView] in selectionView?.finish(nil) }
    }

    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onFinish: (@MainActor @Sendable (CGRect?) -> Void)?
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var isFinishing = false
    private var showsSize = false
    private let shade = SelectionShade()
    private let hint: HintPill
    private let sizePill = SizePill()
    private let accessory: NSView?
    private let barBottomInset: CGFloat
    private var hintCenterY: NSLayoutConstraint?
    private var barBottom: NSLayoutConstraint?

    /// How far the hint and the accessory travel while they appear
    private static let hintRise: CGFloat = 6
    private static let barRise: CGFloat = 12

    init(frame: NSRect, hint hintText: String, accessory: NSView?, barBottomInset: CGFloat) {
        hint = HintPill(text: hintText)
        self.accessory = accessory
        self.barBottomInset = barBottomInset
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self, userInfo: nil
        ))
        shade.frame = bounds
        shade.autoresizingMask = [.width, .height]
        addSubview(shade)
        addSubview(sizePill)
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        let hintCenterY = hint.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([hint.centerXAnchor.constraint(equalTo: centerXAnchor), hintCenterY])
        self.hintCenterY = hintCenterY
        guard let accessory else { return }
        accessory.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accessory)
        let barBottom = accessory.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -barBottomInset)
        NSLayoutConstraint.activate([accessory.centerXAnchor.constraint(equalTo: centerXAnchor), barBottom])
        self.barBottom = barBottom
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    // MARK: - Motion

    /// The dim fades in, then the hint rises into place and the accessory rises in from below.
    func animateIn() {
        let travel = !HUDMotion.reduceMotion
        hint.alphaValue = 0
        hintCenterY?.constant = travel ? Self.hintRise : 0
        accessory?.alphaValue = 0
        barBottom?.constant = -barBottomInset + (travel ? Self.barRise : 0)
        layoutSubtreeIfNeeded()
        shade.alphaValue = 0
        HUDMotion.fade(shade, visible: true)
        afterDelay(0.05) { view in
            guard view.dragStart == nil else { return }  // the drag already started: the hint stays away
            view.hint.animator().alphaValue = 1
            view.hintCenterY?.animator().constant = 0
        }
        afterDelay(0.08) { view in
            view.accessory?.animator().alphaValue = 1
            view.barBottom?.animator().constant = -view.barBottomInset
        }
    }

    /// Runs `changes` in an enter-timed animation group after `delay`, unless the overlay is finishing.
    private func afterDelay(_ delay: TimeInterval, _ changes: @escaping @MainActor (SelectionView) -> Void) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !self.isFinishing else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = HUDMotion.enterDuration
                context.timingFunction = HUDMotion.enterTiming
                changes(self)
            }, completionHandler: nil)
        }
    }

    /// Fades everything out (the accessory sinks a little), then resumes the caller exactly once.
    func finish(_ rect: CGRect?) {
        guard let handler = onFinish else { return }
        onFinish = nil
        isFinishing = true
        HUDHint.shared.hide()
        guard let window, window.isVisible else { handler(rect); return }
        window.ignoresMouseEvents = true
        if !HUDMotion.reduceMotion, let barBottom {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = HUDMotion.exitDuration
                context.timingFunction = HUDMotion.exitTiming
                barBottom.animator().constant = -barBottomInset + Self.barRise / 2
            }
        }
        HUDMotion.hide(window) {
            window.orderOut(nil)
            handler(rect)
        }
    }

    // MARK: - Input

    override func mouseDown(with event: NSEvent) {
        guard !isFinishing else { return }
        NSCursor.crosshair.set()
        HUDMotion.fade(hint, visible: false, duration: 0.12)
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        updateSelection()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil, !isFinishing else { return }
        dragCurrent = convert(event.locationInWindow, from: nil)
        updateSelection()
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        finish(SelectionOverlay.selectionRect(from: start, to: end, in: bounds.size))
    }

    /// Current selection in view coordinates (bottom-left origin), clamped and rounded like the result.
    /// Nil while it's below `minSelectionSize`, since releasing then picks the whole screen.
    private var selectionInView: CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        let rect = CGRect(
            x: min(start.x, current.x), y: min(start.y, current.y),
            width: abs(current.x - start.x), height: abs(current.y - start.y)
        ).integral.intersection(bounds)
        let minSize = SelectionOverlay.minSelectionSize
        return rect.isNull || rect.width < minSize || rect.height < minSize ? nil : rect
    }

    /// Follows the pointer directly (no easing lag); only the size pill fades in and out.
    private func updateSelection() {
        let selection = selectionInView
        shade.show(selection)
        if let selection { sizePill.show(selection, in: bounds) }
        guard (selection != nil) != showsSize else { return }
        showsSize = selection != nil
        HUDMotion.fade(sizePill, visible: showsSize, duration: 0.12)
    }
}

/// The dim around the selection and its border, drawn with shape layers so dragging never redraws the view.
private final class SelectionShade: NSView {
    private let dim = CAShapeLayer()
    private let border = CAShapeLayer()
    private let handles = CAShapeLayer()
    private var selection: CGRect?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        dim.fillColor = NSColor.black.withAlphaComponent(0.42).cgColor
        dim.fillRule = .evenOdd
        border.fillColor = nil
        border.strokeColor = NSColor.white.cgColor
        border.lineWidth = 1.5
        handles.fillColor = NSColor.white.cgColor
        for layer in [border, handles] {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.4
            layer.shadowRadius = 3
            layer.shadowOffset = .zero
        }
        for sublayer in [dim, border, handles] { layer?.addSublayer(sublayer) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        show(selection)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [dim, border, handles] { layer.contentsScale = scale }
    }

    func show(_ selection: CGRect?) {
        self.selection = selection
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [dim, border, handles] { layer.frame = bounds }
        let dimPath = CGMutablePath()
        dimPath.addRect(bounds)
        if let selection { dimPath.addRect(selection) }
        dim.path = dimPath
        border.path = selection.map { CGPath(rect: $0.insetBy(dx: 0.75, dy: 0.75), transform: nil) }
        handles.path = selection.flatMap(Self.handlesPath)
        CATransaction.commit()
    }

    /// Small dots on the corners, so the selection reads as a frame; left out when it's too small for them.
    private static func handlesPath(for rect: CGRect) -> CGPath? {
        guard min(rect.width, rect.height) >= 32 else { return nil }
        let path = CGMutablePath()
        let inner = rect.insetBy(dx: 0.75, dy: 0.75)
        for corner in [CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY),
                       CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY)] {
            path.addEllipse(in: CGRect(x: corner.x - 3.5, y: corner.y - 3.5, width: 7, height: 7))
        }
        return path
    }
}

/// HUD-surface pill that stays readable on any background. Mouse events pass through to the selection view.
private final class HintPill: NSView {
    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        HUDStyle.paintSurface(layer, radius: 17)
        let label = NSTextField(labelWithAttributedString: Self.styled(text))
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// White phrases with dimmed separator dots between them
    private static func styled(_ text: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let result = NSMutableAttributedString()
        for (index, part) in text.components(separatedBy: " \u{00B7} ").enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "  \u{00B7}  ", attributes: [
                    .font: font, .foregroundColor: HUDStyle.disabled,
                ]))
            }
            result.append(NSAttributedString(string: part, attributes: [.font: font, .foregroundColor: NSColor.white]))
        }
        return result
    }
}

/// "640 × 480" in a tiny HUD pill just outside the selection's corner.
private final class SizePill: NSView {
    private let label = NSTextField(labelWithString: "")
    private static let height: CGFloat = 20
    private static let gap: CGFloat = 6

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        HUDStyle.paintSurface(layer, radius: 6)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        addSubview(label)
        alphaValue = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Below the bottom-left corner; above the top-left one when the screen edge is in the way,
    /// inside the selection when neither fits. Always kept on screen.
    func show(_ selection: CGRect, in bounds: CGRect) {
        label.stringValue = "\(Int(selection.width)) \u{00D7} \(Int(selection.height))"
        let text = label.intrinsicContentSize
        let size = CGSize(width: ceil(text.width) + 14, height: Self.height)
        var origin = CGPoint(x: selection.minX, y: selection.minY - size.height - Self.gap)
        if origin.y < bounds.minY + Self.gap { origin.y = selection.maxY + Self.gap }
        if origin.y + size.height > bounds.maxY - Self.gap { origin.y = selection.minY + Self.gap }
        origin.x = min(max(origin.x, bounds.minX + Self.gap), bounds.maxX - size.width - Self.gap)
        frame = NSRect(origin: origin, size: size)
        label.frame = NSRect(x: 7, y: round((size.height - text.height) / 2), width: ceil(text.width), height: text.height)
    }
}
