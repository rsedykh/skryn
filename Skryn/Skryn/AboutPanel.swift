import AppKit

/// About Skryn: icon, name, version and a short line, then every shortcut in key/description cards
/// that match Settings. Scrolls under its transparent titlebar.
final class AboutPanel: AnimatedPanel {
    private static let width: CGFloat = 540
    private static let cardWidth = width - 40
    /// Where descriptions start in a shortcut row
    private static let keyColumn: CGFloat = 210

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "About Skryn"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        setupContent()
        center()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    private func setupContent() {
        let stack = NSStackView(views: [header()] + shortcutSections().map(section))
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 24
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 20, bottom: 28, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = document
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        guard let contentView else { return }
        contentView.addSubview(scrollView)
        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
        ])
    }

    // MARK: - Header

    private func header() -> NSView {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 80).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 80).isActive = true

        let name = NSTextField(labelWithString: "Skryn")
        name.font = .systemFont(ofSize: 22, weight: .bold)
        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        let help = centered(
            "Click the menu bar icon or press the shortcut to take a screenshot. "
                + "Drag an image onto the menu bar icon to annotate it. "
                + "Right-click the icon to record the screen, see recent uploads, and open Settings."
        )
        let link = LinkButton(title: "skryn.app \u{2197}", url: "https://skryn.app")
        link.refusesFirstResponder = true  // otherwise it opens focused, ringed in the accent color

        let stack = NSStackView(views: [icon, name, versionLabel, help, link])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(10, after: icon)
        stack.setCustomSpacing(12, after: versionLabel)
        stack.setCustomSpacing(8, after: help)
        return stack
    }

    private func centered(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 400
        return label
    }

    // MARK: - Shortcuts

    private struct ShortcutSection {
        let title: String
        let symbol: String
        let tint: NSColor
        let items: [(keys: String, action: NSAttributedString)]
    }

    private func section(_ content: ShortcutSection) -> NSView {
        let form = SettingsForm()
        content.items.forEach { form.addFullWidthRow(shortcutRow($0.keys, $0.action), padding: 7) }
        let view = SettingsStyle.section(content.title, symbol: content.symbol, tint: content.tint, form: form)
        view.widthAnchor.constraint(equalToConstant: Self.cardWidth).isActive = true
        return view
    }

    /// Keycaps in the first column; the description in the second, its first line centered on the keys.
    private func shortcutRow(_ keys: String, _ action: NSAttributedString) -> NSView {
        let row = NSView()
        let caps = Keycaps.view(for: keys)
        let text = NSTextField(wrappingLabelWithString: "")
        text.attributedStringValue = action
        text.preferredMaxLayoutWidth = Self.cardWidth - 2 * SettingsStyle.cardPadding - Self.keyColumn
        for view in [caps, text] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        let low = row.heightAnchor.constraint(equalToConstant: 0)
        low.priority = .defaultLow
        let fits = caps.trailingAnchor.constraint(lessThanOrEqualTo: text.leadingAnchor, constant: -8)
        fits.priority = .defaultHigh
        NSLayoutConstraint.activate([
            low, fits,
            caps.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            caps.topAnchor.constraint(equalTo: row.topAnchor),
            caps.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Self.keyColumn),
            text.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            text.firstBaselineAnchor.constraint(equalTo: caps.topAnchor, constant: Keycaps.height / 2 + 4.5),
            text.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor),
            text.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
        ])
        return row
    }

    private func shortcutSections() -> [ShortcutSection] {
        let uploadAction = NSMutableAttributedString(attributedString: plain("Upload to "))
        uploadAction.append(NSAttributedString(string: UploadProviders.current.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ]))
        let capture = hotkeyDisplayString(keyCode: Defaults.hotkey.keyCode, carbonModifiers: Defaults.hotkey.modifiers)
        let area = hotkeyDisplayString(keyCode: Defaults.areaHotkey.keyCode, carbonModifiers: Defaults.areaHotkey.modifiers)
        var sections = [ShortcutSection(title: "Capture and Save", symbol: "camera.viewfinder", tint: .systemBlue, items: [
            (capture, plain("Take a screenshot")),
            (area, plain("Take a screenshot of an area")),
            (SaveAction.clipboard.configuredModifier.label, plain("Copy to clipboard")),
            (SaveAction.local.configuredModifier.label, plain("Save to local folder")),
            (SaveAction.cloud.configuredModifier.label, uploadAction),
        ])]
        if #available(macOS 15.0, *) {
            let record = hotkeyDisplayString(
                keyCode: Defaults.recordHotkey.keyCode, carbonModifiers: Defaults.recordHotkey.modifiers
            )
            sections.append(plainSection("Recording", "record.circle", .systemRed, [
                (record, "Record the screen, press again to stop"),
                ("Drag / Click", "Record an area / the full screen"),
                ("Menu bar icon", "Stop (right-click to discard)"),
                ("\u{23CE}", "Default action in the result window"),
                ("Space", "Play / pause the result"),
            ]))
        }
        return sections + editorSections()
    }

    private func editorSections() -> [ShortcutSection] {
        [
            plainSection("Drawing", "pencil.tip", .systemOrange, [
                ("Toolbar / A L R O B X", "Pick the tool for a plain drag"),
                ("Drag", "Draw with the picked tool (Arrow by default)"), ("\u{21E7} Drag", "Line"),
                ("\u{2318} Drag", "Rectangle"), ("\u{21E7}\u{2318} Drag", "Ellipse"),
                ("\u{2303} Drag", "Blur"),
                ("\u{2325} Drag", "Crop screenshot"), ("\u{238B}", "Cancel crop"),
                ("1\u{2013}0", "Numbered badge at cursor"),
                ("C / Toolbar", "Next color / pick one of 8"),
            ]),
            plainSection("Text", "textformat", .systemPurple, [
                ("T", "Type text at cursor"), ("U", "Capture time (UTC)"),
                ("\u{23CE} / \u{238B}", "Finalize text"),
                ("\u{21E7}\u{23CE}", "New line"), ("\u{2318}+ / \u{2318}-", "Adjust font size"),
                ("Click text / T over it", "Edit"),
            ]),
            plainSection("Editing", "hand.draw", .systemGreen, [
                ("Drag annotation", "Move it"), ("Drag handle", "Resize / reshape"),
                ("\u{232B}", "Remove annotation"), ("\u{2318}Z / \u{2318}\u{21E7}Z", "Undo / Redo"),
            ]),
            plainSection("Other", "command", .systemGray, [
                ("\u{2318}W", "Close window"), ("\u{2318}Q", "Quit"),
            ]),
        ]
    }

    private func plainSection(_ title: String, _ symbol: String, _ tint: NSColor, _ items: [(String, String)]) -> ShortcutSection {
        ShortcutSection(title: title, symbol: symbol, tint: tint, items: items.map { ($0.0, plain($0.1)) })
    }

    private func plain(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
    }
}

/// Renders a shortcut like "⇧⌘ Drag" or "⌘Z / ⌘⇧Z": keys as keycaps, words ("Drag", "Click text") as
/// plain secondary text, alternatives split by a slash.
@MainActor
enum Keycaps {
    static let height: CGFloat = 20

    private static let fill = SettingsStyle.dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.1))
    private static let border = SettingsStyle.dynamic(
        light: NSColor(white: 0, alpha: 0.18), dark: NSColor(white: 1, alpha: 0.16)
    )

    static func view(for keys: String) -> NSView {
        var views: [NSView] = []
        for (index, alternative) in keys.components(separatedBy: " / ").enumerated() {
            if index > 0 { views.append(word("/")) }
            var words: [String] = []
            for token in alternative.split(separator: " ").map(String.init) {
                if isWord(token) {
                    words.append(token)
                    continue
                }
                if !words.isEmpty { views.append(word(words.joined(separator: " "))) }
                words = []
                views.append(cap(token))
            }
            if !words.isEmpty { views.append(word(words.joined(separator: " "))) }
        }
        let stack = NSStackView(views: views)
        stack.spacing = 4
        return stack
    }

    /// A word to read rather than a key to press ("Drag", "Toolbar"); "Space" is a key.
    static func isWord(_ token: String) -> Bool {
        token.count > 1 && token != "Space" && token.allSatisfy(\.isLetter)
    }

    private static func word(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func cap(_ text: String) -> NSView {
        let box = RoundedFillView(fill: fill, border: border, radius: 5)
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        let snug = box.widthAnchor.constraint(equalToConstant: 0)  // as narrow as the label allows
        snug.priority = .defaultLow
        NSLayoutConstraint.activate([
            snug,
            box.heightAnchor.constraint(equalToConstant: height),
            box.widthAnchor.constraint(greaterThanOrEqualToConstant: height),
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor, constant: 6),
        ])
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.staticText)
        box.setAccessibilityLabel(text)
        return box
    }
}
