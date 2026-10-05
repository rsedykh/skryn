import AppKit

/// Notion-style format bar over the text being typed: typeface, size, bold, and a filled label. It
/// floats just above the text box (below it when the box is at the top of the editor), never becomes
/// key, and drives `editor`, so the text keeps focus while you click it.
@MainActor
final class TextFormatBar: HUDPanel {
    private weak var editor: AnnotationView?
    private var designButtons: [(design: TextDesign, button: TextDesignButton)] = []
    private let sizeLabel = NSTextField(labelWithString: "")
    private lazy var smallerButton = makeButton("Smaller", symbol: "minus", tip: "Smaller \u{2014} \u{2318}\u{2212}") {
        $0.stepTextSize(larger: false)
    }
    private lazy var largerButton = makeButton("Larger", symbol: "plus", tip: "Larger \u{2014} \u{2318}=") {
        $0.stepTextSize(larger: true)
    }
    private lazy var boldButton = makeButton("Bold", symbol: "bold", tip: "Bold \u{2014} \u{2318}B") {
        $0.updateTextStyle { $0.bold.toggle() }
    }
    private lazy var labelButton = makeButton("Label", symbol: "character.textbox", tip: "Filled label behind the text") {
        $0.updateTextStyle { $0.background.toggle() }
    }
    /// Bumped on every show, so a hide finishing late doesn't order out a bar shown again since
    private var generation = 0
    private static let gap: CGFloat = 10

    init(editor: AnnotationView) {
        self.editor = editor
        super.init()
        isFloatingPanel = false  // a child window follows the editor's level
        becomesKeyOnlyIfNeeded = true
        isMovable = false

        designButtons = TextDesign.allCases.map { design in
            let button = TextDesignButton(design: design)
            button.handler = { [weak self] in self?.editor?.updateTextStyle { $0.design = design } }
            return (design, button)
        }
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sizeLabel.textColor = .white
        sizeLabel.alignment = .center
        sizeLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true
        sizeLabel.setAccessibilityLabel("Text size")

        contentView = HUDBar(groups: [
            designButtons.map(\.button), [smallerButton, sizeLabel, largerButton], [boldButton, labelButton],
        ])
        refresh()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Follows the editor's text style
    func refresh() {
        guard let style = editor?.textStyle else { return }
        for (design, button) in designButtons { button.isSelected = design == style.design }
        sizeLabel.stringValue = "\(Int(style.size))"
        smallerButton.isEnabled = style.size > (Annotation.textFontSizes.first ?? 0)
        largerButton.isEnabled = style.size < (Annotation.textFontSizes.last ?? .infinity)
        boldButton.isSelectedTool = style.bold
        labelButton.isSelectedTool = style.background
    }

    /// Shows the bar over `textView`'s box, or moves it there if it's already up.
    func show(over textView: NSTextView) {
        guard let editorWindow = textView.window, let content = contentView else { return }
        refresh()
        let size = content.fittingSize
        let box = editorWindow.convertToScreen(textView.convert(textView.bounds, to: nil))
        let bounds = editorWindow.frame
        var origin = NSPoint(x: box.minX, y: box.maxY + Self.gap)
        // No room above the box inside the editor: go under it instead
        if origin.y + size.height > bounds.maxY - 6 { origin.y = box.minY - Self.gap - size.height }
        origin.x = min(max(origin.x, bounds.minX + 6), bounds.maxX - size.width - 6)
        let frame = NSRect(origin: origin, size: size).integral

        generation += 1
        if isVisible && alphaValue > 0 {
            setFrame(frame, display: true)
            return
        }
        setFrame(frame, display: false)
        editorWindow.addChildWindow(self, ordered: .above)
        HUDMotion.show(self, travel: .up, distance: 6, scale: 0.98)
    }

    func hide() {
        guard isVisible else { return }
        HUDHint.shared.hide()
        parent?.removeChildWindow(self)
        let shown = generation
        HUDMotion.hide(self, travel: .up, distance: 4) { [weak self] in
            guard let self, generation == shown else { return }
            orderOut(nil)
        }
    }

    private func makeButton(
        _ title: String, symbol: String, tip: String, handler: @escaping (AnnotationView) -> Void
    ) -> HUDButton {
        let button = HUDButton(title: title, symbol: symbol)
        button.hint = tip
        button.handler = { [weak self] in
            guard let editor = self?.editor else { return }
            handler(editor)
        }
        return button
    }
}

/// "Aa" set in one typeface design: white on a tile when it's the text's design, dimmed otherwise.
private final class TextDesignButton: HUDHintButton {
    private let design: TextDesign
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            setAccessibilityValue(isSelected ? "Selected" : nil)
            HUDMotion.crossfade(self)
            refresh()
        }
    }

    init(design: TextDesign) {
        self.design = design
        super.init(frame: .zero)
        title = ""
        isBordered = false
        hint = design.title
        setAccessibilityLabel(design.title)
        wantsLayer = true
        layer?.cornerRadius = HUDStyle.buttonRadius
        widthAnchor.constraint(equalToConstant: HUDStyle.buttonSize).isActive = true
        heightAnchor.constraint(equalToConstant: HUDStyle.buttonSize).isActive = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func refresh() {
        layer?.backgroundColor = isSelected ? HUDStyle.selectedFill.cgColor : nil
        needsDisplay = true
    }

    override func hoverChanged() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let font = TextStyle(size: 14, design: design, bold: false).font
        let color = isSelected || isHovered ? NSColor.white : HUDStyle.dimmed
        let text = NSAttributedString(string: "Aa", attributes: [.font: font, .foregroundColor: color])
        let size = text.size()
        // Caps centered on the middle (flipped: the line's top is ascender above the baseline)
        let baseline = bounds.midY + font.capHeight / 2
        text.draw(at: NSPoint(x: round(bounds.midX - size.width / 2), y: round(baseline - font.ascender)))
    }
}
