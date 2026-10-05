import AppKit

/// Floating HUD under the screenshot editor: tools, color, undo/redo and the save actions. It drives
/// `editor` and follows its state (tool, color, undo availability). A non-activating panel that never
/// becomes key, so the editor keeps keyboard focus.
@MainActor
final class AnnotationToolbar: HUDPanel {
    struct State: Equatable {
        var tool: AnnotationTool
        var color: AnnotationColor
        var width: StrokeWidth
        var canUndo: Bool
        var canRedo: Bool
    }
    static let height = HUDStyle.barHeight
    /// Space between the editor window's bottom edge and the toolbar
    static let gap: CGFloat = 10

    private weak var editor: AnnotationView?
    private var toolButtons: [(tool: AnnotationTool, button: HUDButton)] = []
    private var actionButtons: [(action: SaveAction, button: HUDButton)] = []
    private var swatches: [(color: AnnotationColor, button: ColorSwatchButton)] = []
    private var widthButtons: [(width: StrokeWidth, button: HUDButton)] = []
    private lazy var undoButton = makeButton("Undo", symbol: "arrow.uturn.backward", tip: "Undo \u{2014} \u{2318}Z") {
        $0.undo(nil)
    }
    private lazy var redoButton = makeButton("Redo", symbol: "arrow.uturn.forward", tip: "Redo \u{2014} \u{21E7}\u{2318}Z") {
        $0.redo(nil)
    }

    init(editor: AnnotationView) {
        self.editor = editor
        super.init()
        setContentSize(NSSize(width: 400, height: Self.height))
        isFloatingPanel = false // child windows follow the parent's level
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        contentView = HUDBar(groups: groups())
        editor.onStateChange = { [weak self] in self?.refresh() }
        // Undo availability changes with every edit (checkpoint), undo, and redo
        for name in [Notification.Name.NSUndoManagerCheckpoint, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: name, object: editor.undoManager)
        }
        refresh()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    @objc private func refresh() {
        guard let editor else { return }
        update(State(
            tool: editor.selectedTool, color: editor.displayedColor, width: editor.displayedWidth,
            canUndo: editor.undoManager?.canUndo ?? false, canRedo: editor.undoManager?.canRedo ?? false
        ))
    }

    func update(_ state: State) {
        for (tool, button) in toolButtons {
            Self.crossfade(button, \.isSelectedTool, to: tool == state.tool)
        }
        for (color, swatch) in swatches {
            swatch.isSelectedColor = color == state.color
        }
        for (width, button) in widthButtons {
            Self.crossfade(button, \.isSelectedTool, to: width == state.width)
        }
        Self.crossfade(undoButton, \.isEnabled, to: state.canUndo)
        Self.crossfade(redoButton, \.isEnabled, to: state.canRedo)
        let primary = SaveAction.primary
        for (action, button) in actionButtons {
            Self.crossfade(button, \.isEmphasized, to: action == primary)
            button.hint = "\(action.title) \u{2014} \(action.configuredModifier.label)"
        }
    }

    /// Sizes the toolbar and centers it under `window` (gap below its bottom edge), detached from any parent.
    /// `AnnotationWindow.present` animates it in from there and then attaches it as a child window.
    func place(below window: NSWindow) {
        parent?.removeChildWindow(self)
        let width = ceil(contentView?.fittingSize.width ?? frame.width)
        setFrame(NSRect(
            x: round(window.frame.midX - width / 2), y: window.frame.minY - Self.gap - Self.height,
            width: width, height: Self.height
        ), display: true)
    }

    /// Sets a button state with a quick crossfade (background and tint together) instead of a jump.
    private static func crossfade(_ button: HUDButton, _ keyPath: ReferenceWritableKeyPath<HUDButton, Bool>, to value: Bool) {
        guard button[keyPath: keyPath] != value else { return }
        HUDMotion.crossfade(button)
        button[keyPath: keyPath] = value
    }

    // MARK: - Layout

    private func groups() -> [[NSView]] {
        let close = makeButton("Close", symbol: "xmark", tip: "Close \u{2014} \u{2318}W") { $0.window?.close() }

        toolButtons = AnnotationTool.allCases.map { tool in
            (tool, makeButton(tool.title, symbol: tool.symbolName, tip: Self.toolTip(for: tool)) { $0.selectedTool = tool })
        }

        // One click per color; C cycles through them from the keyboard
        swatches = AnnotationColor.allCases.map { color in
            let swatch = ColorSwatchButton(color: color)
            swatch.hint = "\(color.title) \u{2014} C cycles colors"
            swatch.handler = { [weak self] in self?.editor?.applyColor(color) }
            return (color, swatch)
        }

        // Line weight of arrows, lines and shapes; [ and ] step it from the keyboard
        widthButtons = StrokeWidth.allCases.map { width in
            let button = makeButton(width.title, symbol: "line.diagonal", tip: "\(width.title) line \u{2014} [ thinner, ] thicker") {
                $0.applyWidth(width)
            }
            button.image = Self.lineImage(for: width)
            return (width, button)
        }

        actionButtons = SaveAction.allCases.map { action in
            let button = makeButton(action.title, symbol: action.symbolName, tip: nil) { $0.perform(action) }
            button.showsTitle = true
            return (action, button)
        }

        return [
            [close], toolButtons.map(\.button), swatches.map(\.button), widthButtons.map(\.button),
            [undoButton, redoButton],
            actionButtons.map(\.button),
        ]
    }

    /// A short horizontal stroke at `width`'s weight, tinted like the other icons
    private static func lineImage(for width: StrokeWidth) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let path = NSBezierPath()
            path.lineWidth = width.points
            path.lineCapStyle = .round
            path.move(to: CGPoint(x: rect.minX + 2, y: rect.midY))
            path.line(to: CGPoint(x: rect.maxX - 2, y: rect.midY))
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "\(width.title) line"
        return image
    }

    /// A toolbar button that acts on the editor
    private func makeButton(
        _ title: String, symbol: String, tip: String?, handler: @escaping (AnnotationView) -> Void
    ) -> HUDButton {
        let button = HUDButton(title: title, symbol: symbol)
        button.hint = tip
        button.handler = { [weak self] in
            guard let editor = self?.editor else { return }
            handler(editor)
        }
        return button
    }

    /// e.g. "Rectangle — R, or ⌘ Drag"; "Arrow — A, or just drag"
    static func toolTip(for tool: AnnotationTool) -> String {
        let hints = [tool.selectionKey?.label, tool.modifierHint ?? (tool == .arrow ? "just drag" : nil)]
        return "\(tool.title) \u{2014} " + hints.compactMap { $0 }.joined(separator: ", or ")
    }
}

/// One palette color: a filled circle, ringed in white when it's the drawing color. The ring grows out
/// of the dot when selected and sinks back into it when not, so switching colors reads as one motion.
private final class ColorSwatchButton: HUDHintButton {
    let color: AnnotationColor
    var isSelectedColor = false {
        didSet {
            guard isSelectedColor != oldValue else { return }
            setAccessibilityValue(isSelectedColor ? "Selected" : nil)
            animateRing()
        }
    }
    private let ring = CAShapeLayer()
    private static let dotDiameter: CGFloat = 14
    private static let ringDiameter: CGFloat = 21
    /// Ring scale when hidden: tucked just inside the dot
    private static let tuckedScale = dotDiameter / ringDiameter * 0.85

    init(color: AnnotationColor) {
        self.color = color
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setAccessibilityLabel(color.title)
        wantsLayer = true
        ring.fillColor = nil
        ring.strokeColor = NSColor.white.cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        ring.transform = CATransform3DMakeScale(Self.tuckedScale, Self.tuckedScale, 1)
        layer?.addSublayer(ring)
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: HUDStyle.buttonSize).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = Self.ringDiameter
        ring.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        CATransaction.commit()
    }

    private func animateRing() {
        let scale = isSelectedColor || HUDMotion.reduceMotion ? 1 : Self.tuckedScale
        CATransaction.begin()
        CATransaction.setAnimationDuration(isSelectedColor ? 0.24 : 0.16)
        CATransaction.setAnimationTimingFunction(isSelectedColor ? HUDMotion.enterTiming : HUDMotion.exitTiming)
        ring.opacity = isSelectedColor ? 1 : 0
        ring.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let half = Self.dotDiameter / 2
        let dot = NSBezierPath(ovalIn: NSRect(x: bounds.midX - half, y: bounds.midY - half, width: 2 * half, height: 2 * half))
        color.nsColor.setFill()
        dot.fill()
        // A faint edge keeps black visible on the dark bar
        NSColor.white.withAlphaComponent(0.3).setStroke()
        dot.lineWidth = 1
        dot.stroke()
    }
}
