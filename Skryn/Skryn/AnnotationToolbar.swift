import AppKit

/// Floating HUD under the screenshot editor: tools, color, undo/redo and the save actions.
/// A non-activating panel that never becomes key, so the editor keeps keyboard focus.
@MainActor
final class AnnotationToolbar: NSPanel {
    struct State: Equatable {
        var tool: AnnotationTool
        var color: AnnotationColor
        var canUndo: Bool
        var canRedo: Bool
    }
    static let height = HUDStyle.barHeight
    /// Space between the editor window's bottom edge and the toolbar
    static let gap: CGFloat = 10

    var onSelectTool: ((AnnotationTool) -> Void)?
    var onSelectColor: ((AnnotationColor) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onAction: ((SaveAction) -> Void)?
    var onClose: (() -> Void)?

    private var toolButtons: [(tool: AnnotationTool, button: HUDButton)] = []
    private var actionButtons: [(action: SaveAction, button: HUDButton)] = []
    private var swatches: [(color: AnnotationColor, button: ColorSwatchButton)] = []
    private lazy var undoButton = makeButton("Undo", symbol: "arrow.uturn.backward", tip: "Undo \u{2014} \u{2318}Z") {
        $0.onUndo?()
    }
    private lazy var redoButton = makeButton("Redo", symbol: "arrow.uturn.forward", tip: "Redo \u{2014} \u{21E7}\u{2318}Z") {
        $0.onRedo?()
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        isFloatingPanel = false // child windows follow the parent's level
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)
        contentView = HUDBar(views: groupViews())
        update(State(tool: .arrow, color: .red, canUndo: false, canRedo: false))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(_ state: State) {
        for (tool, button) in toolButtons {
            Self.crossfade(button, \.isSelectedTool, to: tool == state.tool)
        }
        for (color, swatch) in swatches {
            swatch.isSelectedColor = color == state.color
        }
        Self.crossfade(undoButton, \.isEnabled, to: state.canUndo)
        Self.crossfade(redoButton, \.isEnabled, to: state.canRedo)
        // Re-read each time: the key can be set in Settings while the editor is open
        let primary: SaveAction = UploadProviders.current.setupProblem == nil ? .cloud : .local
        for (action, button) in actionButtons {
            Self.crossfade(button, \.isEmphasized, to: action == primary)
            button.hint = "\(Self.title(of: action)) \u{2014} \(action.configuredModifier.label)"
        }
    }

    /// Centers the toolbar under `window` (gap below its bottom edge) and adds it as a child window,
    /// so it moves and closes with the editor. `AnnotationWindow.present` animates this in instead.
    func attach(below window: NSWindow) {
        place(below: window)
        window.addChildWindow(self, ordered: .above)
    }

    /// Sizes the toolbar and centers it under `window`, detached from any parent.
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
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(fade, forKey: "crossfade")
        button[keyPath: keyPath] = value
    }

    // MARK: - Layout

    private func groupViews() -> [NSView] {
        let close = makeButton("Close", symbol: "xmark", tip: "Close \u{2014} \u{2318}W") { $0.onClose?() }

        toolButtons = AnnotationTool.allCases.map { tool in
            (tool, makeButton(tool.title, symbol: tool.symbolName, tip: Self.toolTip(for: tool)) { $0.onSelectTool?(tool) })
        }

        // One click per color; C cycles through them from the keyboard
        swatches = AnnotationColor.allCases.map { color in
            let swatch = ColorSwatchButton(color: color)
            swatch.hint = "\(color.title) \u{2014} C cycles colors"
            swatch.handler = { [weak self] in self?.onSelectColor?(color) }
            return (color, swatch)
        }

        actionButtons = SaveAction.allCases.map { action in
            let button = makeButton(Self.title(of: action), symbol: Self.symbol(of: action), tip: nil) { $0.onAction?(action) }
            button.showsTitle = true
            return (action, button)
        }

        let groups: [[NSView]] = [
            [close], toolButtons.map(\.button), swatches.map(\.button), [undoButton, redoButton],
            actionButtons.map(\.button),
        ]
        var views: [NSView] = []
        for (index, group) in groups.enumerated() {
            if index > 0 { views.append(Self.divider()) }
            views.append(contentsOf: group)
        }
        return views
    }

    private func makeButton(
        _ title: String, symbol: String, tip: String?, handler: @escaping (AnnotationToolbar) -> Void
    ) -> HUDButton {
        let button = HUDButton(title: title, symbol: symbol)
        button.hint = tip
        button.handler = { [weak self] in
            guard let self else { return }
            handler(self)
        }
        return button
    }

    private static func divider() -> NSView {
        HUDDivider()
    }

    /// e.g. "Rectangle — R, or ⌘ Drag"; "Arrow — A, or just drag"
    static func toolTip(for tool: AnnotationTool) -> String {
        let hints = [tool.key.map { String($0).uppercased() }, tool.modifierHint ?? (tool == .arrow ? "just drag" : nil)]
        return "\(tool.title) \u{2014} " + hints.compactMap { $0 }.joined(separator: ", or ")
    }

    private static func title(of action: SaveAction) -> String {
        switch action {
        case .local: "Save"
        case .clipboard: "Copy"
        case .cloud: "Upload"
        }
    }

    private static func symbol(of action: SaveAction) -> String {
        switch action {
        case .local: "square.and.arrow.down"
        case .clipboard: "doc.on.doc"
        case .cloud: "icloud.and.arrow.up"
        }
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
