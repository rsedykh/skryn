import AppKit

/// Top-left origin: content pinned to the top stays put while the window's height changes.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Settings look

/// Metrics, colors and builders for the grouped Settings look (also used by About and the Dropbox guide).
@MainActor
enum SettingsStyle {
    static let windowWidth: CGFloat = 480
    static let cardWidth: CGFloat = windowWidth - 40
    static let cardPadding: CGFloat = 12
    /// The width of a card's rows (wrapping captions use it)
    static let rowWidth: CGFloat = cardWidth - 2 * cardPadding
    static let rowHeight: CGFloat = 36

    static let cardFill = dynamic(light: NSColor(white: 0, alpha: 0.035), dark: NSColor(white: 1, alpha: 0.05))
    static let cardBorder = dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.07))

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    static func makeSwitch() -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = .small
        return control
    }

    /// A titled section: icon and title, the form in a rounded card, and an optional footnote.
    static func section(
        _ title: String, symbol: String, tint: NSColor, form: SettingsForm, footer: String? = nil
    ) -> NSView {
        let card = RoundedFillView(fill: cardFill, border: cardBorder, radius: 10)
        card.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: card.topAnchor, constant: 2),
            form.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -2),
            form.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: cardPadding),
            form.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -cardPadding),
        ])
        let stack = NSStackView(views: [header(title, symbol: symbol, tint: tint), card])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        if let footer {
            let note = NSStackView(views: [SettingsForm.caption(footer)])
            note.edgeInsets = NSEdgeInsets(top: 0, left: cardPadding, bottom: 0, right: cardPadding)
            stack.addArrangedSubview(note)
            stack.setCustomSpacing(6, after: card)
        }
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// A vertical scroll view whose document is `content` (pinned top-left, so it keeps its place while
    /// the window's height animates), inset by `insets`; with `width`, centered at that width instead.
    /// `adjustsInsets` lets the scroll view clear a transparent titlebar on its own.
    static func scrollingDocument(
        _ content: NSView, insets: NSEdgeInsets = NSEdgeInsets(), width: CGFloat? = nil, adjustsInsets: Bool = true
    ) -> NSScrollView {
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = adjustsInsets
        scroll.documentView = document
        let horizontal = width.map {
            [content.centerXAnchor.constraint(equalTo: document.centerXAnchor),
             content.widthAnchor.constraint(equalToConstant: $0)]
        } ?? [
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -insets.right),
        ]
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -insets.bottom),
        ] + horizontal)
        return scroll
    }

    /// A System Settings-style tinted icon tile beside a semibold title.
    static func header(_ title: String, symbol: String, tint: NSColor) -> NSView {
        let tile = RoundedFillView(fill: tint, radius: 5)
        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        glyph.contentTintColor = .white
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 20),
            tile.heightAnchor.constraint(equalToConstant: 20),
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let stack = NSStackView(views: [tile, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 0)
        return stack
    }
}

/// A layer-backed rounded rectangle whose fill and hairline follow light and dark mode.
final class RoundedFillView: NSView {
    private let fill: NSColor
    private let border: NSColor?

    init(fill: NSColor, border: NSColor? = nil, radius: CGFloat) {
        self.fill = fill
        self.border = border
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = border?.cgColor
        }
        layer?.borderWidth = border == nil ? 0 : 1 / (window?.backingScaleFactor ?? 2)  // one pixel
    }
}

/// A grouped list of Settings rows, System Settings style: the label leads, its control trails, hairlines
/// between rows. It sits in a card (`SettingsStyle.section`); an upload provider's Settings view is one too,
/// hosted in the Upload card, so its rows look like the rest.
class SettingsForm: NSStackView {
    private(set) var rows: [SettingsRow] = []
    /// Keep the bound controls (`addSwitch` …) in step with their settings
    fileprivate var bindings: [SettingsBinding] = []
    /// Draws a hairline above the first row too: set for a form that continues another form's card
    var separatesFirstRow = false {
        didSet { rows.first?.showsSeparator = separatesFirstRow }
    }

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `label` on the leading edge, `control` on the trailing one.
    @discardableResult
    func addRow(_ label: String, _ control: NSView) -> SettingsRow {
        add(SettingsRow(label: label, control: control))
    }

    /// A row whose single view spans the width (a caption, a link, a hosted view).
    @discardableResult
    func addFullWidthRow(_ view: NSView, padding: CGFloat = 8) -> SettingsRow {
        add(SettingsRow(label: nil, control: view, padding: padding))
    }

    /// A quiet note tucked under the row above it (no hairline between them).
    @discardableResult
    func addCaption(_ caption: NSTextField) -> SettingsRow {
        let inset = NSStackView(views: [caption])
        inset.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        let row = addFullWidthRow(inset, padding: 0)
        row.showsSeparator = false
        return row
    }

    private func add(_ row: SettingsRow) -> SettingsRow {
        row.showsSeparator = !rows.isEmpty || separatesFirstRow
        rows.append(row)
        addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        return row
    }

    static func hstack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    /// Secondary wrapping text, as wide as a card's rows.
    static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = SettingsStyle.rowWidth
        return label
    }
}

/// One row of a `SettingsForm`: a hairline on top, then a leading label lined up with the first line of its
/// trailing control (or one full-width view). Rows can slide shut and open again (`isRevealed`).
final class SettingsRow: NSView {
    let label: NSTextField?
    let control: NSView
    private let separator = NSBox()
    private lazy var collapsed = heightAnchor.constraint(equalToConstant: 0)

    var showsSeparator = true {
        didSet { separator.isHidden = !showsSeparator }
    }

    /// Shut, the row fades and has no height; the move itself animates when the window relayouts.
    var isRevealed = true {
        didSet {
            guard isRevealed != oldValue else { return }
            collapsed.isActive = !isRevealed
            let alpha: CGFloat = isRevealed ? 1 : 0
            if isRevealed { isHidden = false }
            if window?.isVisible == true { animator().alphaValue = alpha } else { alphaValue = alpha }
            guard !isRevealed else { return }
            // Hidden once faded, so Tab and VoiceOver skip the collapsed controls
            DispatchQueue.main.asyncAfter(deadline: .now() + HUDMotion.enterDuration + 0.05) { [weak self] in
                guard let self, !self.isRevealed else { return }
                self.isHidden = true
            }
        }
    }

    init(label text: String?, control: NSView, padding: CGFloat = 6) {
        label = text.map { NSTextField(labelWithString: $0) }
        self.control = control
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true  // a shut row clips its content
        separator.boxType = .separator
        for view in [separator, control] + [label].compactMap({ $0 }) {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            control.centerYAnchor.constraint(equalTo: centerYAnchor).withPriority(.init(999)),
            control.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: padding).withPriority(.init(999)),
            heightAnchor.constraint(equalToConstant: 0).withPriority(.defaultLow),  // otherwise as short as it fits
        ] + (label.map { layout($0, beside: control, text: text ?? "") } ?? fullWidth(control)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func layout(_ label: NSTextField, beside control: NSView, text: String) -> [NSLayoutConstraint] {
        label.setContentCompressionResistancePriority(.required, for: .horizontal)  // never "Upload to Uploadc…"
        label.lineBreakMode = .byTruncatingTail
        if let button = control as? NSButton {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        if control is NSSwitch { control.setAccessibilityLabel(text) }
        // The label lines up with the first control of a row of several (e.g. the shortcut, not its reset button)
        let anchor = (control as? NSStackView)?.arrangedSubviews.first { $0 is NSControl } ?? control
        let alignment = anchor is NSSwitch
            ? label.centerYAnchor.constraint(equalTo: anchor.centerYAnchor)
            : label.firstBaselineAnchor.constraint(equalTo: anchor.firstBaselineAnchor)
        return [
            alignment,
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsStyle.rowHeight).withPriority(.init(999)),
        ]
    }

    /// Leading-aligned; stretched to the row's width only when it has no width of its own (a host view).
    private func fullWidth(_ view: NSView) -> [NSLayoutConstraint] {
        [
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            view.widthAnchor.constraint(equalTo: widthAnchor).withPriority(.init(249)),
        ]
    }
}

// MARK: - Bound controls

extension SettingsForm {
    /// A switch that edits `path` of `S.current`.
    @discardableResult
    func addSwitch<S: StoredSettings>(_ label: String, _ path: WritableKeyPath<S, Bool>) -> SettingsRow {
        let control = SettingsStyle.makeSwitch()
        bind(control, to: S.self, sync: { control.state = S.current[keyPath: path] ? .on : .off }, apply: {
            var settings = S.current
            settings[keyPath: path] = control.state == .on
            S.current = settings
        })
        return addRow(label, control)
    }

    /// A menu of `options` that edits `path` of `S.current`.
    @discardableResult
    func addPopup<S: StoredSettings, Value: Equatable>(
        _ label: String, _ path: WritableKeyPath<S, Value>, options: [(value: Value, title: String)]
    ) -> SettingsRow {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: options.map(\.title))
        bind(popup, to: S.self, sync: {
            popup.selectItem(at: options.firstIndex { $0.value == S.current[keyPath: path] } ?? 0)
        }, apply: {
            guard options.indices.contains(popup.indexOfSelectedItem) else { return }
            var settings = S.current
            settings[keyPath: path] = options[popup.indexOfSelectedItem].value
            S.current = settings
        })
        return addRow(label, popup)
    }

    /// A menu of `defaultTitle` (nil) and `choices()` (re-read on every sync, as devices come and go) that
    /// edits `path` of `S.current`; enabled only while `enabledBy` is on.
    /// ponytail: a saved choice that's gone (an unplugged device) shows the default; its ID stays until changed.
    @discardableResult
    func addChoice<S: StoredSettings>(
        _ label: String, _ path: WritableKeyPath<S, String?>, defaultTitle: String,
        choices: @escaping () -> [(id: String, title: String)], enabledBy: KeyPath<S, Bool>
    ) -> SettingsRow {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        bind(popup, to: S.self, sync: {
            let settings = S.current
            popup.removeAllItems()
            popup.addItem(withTitle: defaultTitle)
            for choice in choices() {
                popup.addItem(withTitle: choice.title)
                popup.lastItem?.representedObject = choice.id
            }
            let selected = settings[keyPath: path]
            popup.selectItem(at: popup.itemArray.firstIndex { ($0.representedObject as? String) == selected } ?? 0)
            popup.isEnabled = settings[keyPath: enabledBy]
        }, apply: {
            var settings = S.current
            settings[keyPath: path] = popup.selectedItem?.representedObject as? String
            S.current = settings
        })
        return addRow(label, popup)
    }

    private func bind<S: StoredSettings>(
        _ control: NSControl, to: S.Type, sync: @escaping () -> Void, apply: @escaping () -> Void
    ) {
        bindings.append(SettingsBinding(control, name: S.didChange, sync: sync, apply: apply))
    }
}

/// Runs `apply` when its control changes and `sync` (also right away) whenever the settings post `name`.
@MainActor
private final class SettingsBinding: NSObject {
    private let sync: () -> Void
    private let apply: () -> Void

    init(_ control: NSControl, name: Notification.Name, sync: @escaping () -> Void, apply: @escaping () -> Void) {
        self.sync = sync
        self.apply = apply
        super.init()
        control.target = self
        control.action = #selector(changed)
        NotificationCenter.default.addObserver(self, selector: #selector(resync), name: name, object: nil)
        sync()
    }

    @objc private func changed() { apply() }
    @objc private func resync() { sync() }
}

private extension NSLayoutConstraint {
    func withPriority(_ value: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        priority = value
        return self
    }
}

/// A small borderless link-colored button that opens `url`.
final class LinkButton: NSButton {
    private var url: URL?

    convenience init(title: String, url: String) {
        self.init(frame: .zero)
        self.title = title
        self.url = URL(string: url)
        isBordered = false
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        contentTintColor = .linkColor
        target = self
        action = #selector(open)
    }

    @objc private func open() {
        if let url { NSWorkspace.shared.open(url) }
    }
}
