import AppKit

@MainActor
enum SelectionOverlay {
    /// Drags smaller than this (in either dimension) select the whole screen.
    static let minSelectionSize: CGFloat = 8

    /// Shows a dimmed, borderless overlay over `screen` and lets the user drag a rectangle.
    /// Returns the selection in the screen's local points with a TOP-LEFT origin (the coordinate space of
    /// SCStreamConfiguration.sourceRect), or nil if the user pressed Esc.
    /// A click without dragging (or a drag smaller than ~8pt) selects the whole screen.
    static func pickArea(on screen: NSScreen) async -> CGRect? {
        let window = SelectionOverlayWindow(screen: screen)
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
        }
        NotificationCenter.default.removeObserver(resignObserver)
        window.orderOut(nil)
        window.close()
        return result
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

private final class SelectionOverlayWindow: NSWindow {
    let selectionView: SelectionView

    init(screen: NSScreen) {
        selectionView = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.crosshair.set()
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        finish(SelectionOverlay.selectionRect(from: start, to: end, in: bounds.size))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            finish(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        finish(nil)
    }

    /// Resumes the caller exactly once.
    func finish(_ rect: CGRect?) {
        let handler = onFinish
        onFinish = nil
        handler?(rect)
    }

    /// Current selection in view coordinates (bottom-left origin), clamped and rounded like the result.
    private var selectionInView: CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        let rect = CGRect(
            x: min(start.x, current.x), y: min(start.y, current.y),
            width: abs(current.x - start.x), height: abs(current.y - start.y)
        ).integral.intersection(bounds)
        return rect.isNull ? nil : rect
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        let selection = selectionInView
        if let selection {
            dim.append(NSBezierPath(rect: selection))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.25).setFill()
        dim.fill()

        guard let selection else { return }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
        drawSizeLabel(for: selection)
    }

    private func drawSizeLabel(for selection: CGRect) {
        let text = "\(Int(selection.width)) × \(Int(selection.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding: CGFloat = 4
        let labelSize = CGSize(width: textSize.width + padding * 2, height: textSize.height + padding)
        // Below the rect's bottom-left corner, or inside it if there's no room below.
        var origin = CGPoint(x: selection.minX, y: selection.minY - labelSize.height - 4)
        if origin.y < bounds.minY { origin.y = selection.minY + 4 }
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - labelSize.width)
        let labelRect = CGRect(origin: origin, size: labelSize)

        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: labelRect.minX + padding, y: labelRect.minY + padding / 2), withAttributes: attributes)
    }
}
