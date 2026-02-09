import AppKit

final class AboutPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "About"
        isReleasedWhenClosed = false
        center()
        setupContent()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    private func setupContent() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 20)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        contentView?.addSubview(scrollView)
        if let cv = contentView {
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: cv.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
                scrollView.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: cv.trailingAnchor)
            ])
        }

        textView.textStorage?.setAttributedString(buildContent())
    }

    // MARK: - Content

    private func buildContent() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let s = TextStyles()

        appendHeader(to: result, styles: s)
        appendDescription(to: result, styles: s)
        appendShortcutSections(to: result, styles: s)
        trimTrailingWhitespace(result)
        return result
    }

    private func appendHeader(to result: NSMutableAttributedString, styles s: TextStyles) {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.1.0"

        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .right, location: 370)]

        let header = NSMutableAttributedString()
        header.append(NSAttributedString(
            string: "Skryn",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: s.text]
        ))
        header.append(NSAttributedString(
            string: "  v\(version)\t",
            attributes: [.font: s.body, .foregroundColor: s.secondary]
        ))
        header.append(NSAttributedString(string: "skryn.app \u{2197}", attributes: [
            .font: s.bold, .link: "https://skryn.app",
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.linkColor
        ]))
        header.append(NSAttributedString(string: "\n\n", attributes: [.font: s.body]))
        header.addAttribute(.paragraphStyle, value: para, range: header.fullRange)
        result.append(header)
    }

    private func appendDescription(to result: NSMutableAttributedString, styles s: TextStyles) {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = 6
        para.paragraphSpacing = 20
        result.append(NSAttributedString(
            string: "Click the menu bar camera icon or press the hotkey to take a screenshot. " +
            "Drag an image onto the menu bar icon to annotate it. " +
            "Right-click the menu bar icon for recent uploads and settings.\n",
            attributes: [.font: s.body, .foregroundColor: s.text, .paragraphStyle: para]
        ))
    }

    private func appendShortcutSections(to result: NSMutableAttributedString, styles s: TextStyles) {
        let uploadAction = NSMutableAttributedString(
            string: "Upload to ",
            attributes: [.font: s.body, .foregroundColor: s.secondary]
        )
        uploadAction.append(NSAttributedString(string: "Uploadcare", attributes: [
            .font: s.bold, .link: "https://uploadcare.com",
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.linkColor
        ]))

        appendSection(to: result, title: "Save", styles: s, richItems: [
            ("\u{2318}\u{2325}5", s.plain("Take a screenshot")),
            ("\u{2318}\u{23CE}", s.plain("Copy to clipboard")),
            ("\u{2325}\u{23CE}", s.plain("Save to local folder")),
            ("\u{2303}\u{23CE}", uploadAction)
        ])
        appendSection(to: result, title: "Drawing", styles: s, items: [
            ("Drag", "Arrow"), ("\u{21E7} Drag", "Line"),
            ("\u{2318} Drag", "Rectangle"), ("\u{2325} Drag", "Blur"),
            ("\u{2303} Drag", "Crop screenshot"), ("\u{238B}", "Cancel crop")
        ])
        appendSection(to: result, title: "Text", styles: s, items: [
            ("T, then click", "Text"), ("U", "UTC timestamp"),
            ("\u{23CE} / \u{238B}", "Finalize text"),
            ("\u{21E7}\u{23CE}", "New line"), ("\u{2318}+ / \u{2318}-", "Adjust font size"),
            ("Click text", "Edit")
        ])
        appendSection(to: result, title: "Editing", styles: s, items: [
            ("Drag annotation", "Move it"), ("Drag handle", "Resize / reshape"),
            ("\u{232B}", "Remove annotation"), ("\u{2318}Z / \u{2318}\u{21E7}Z", "Undo / Redo")
        ])
        appendSection(to: result, title: "Other", styles: s, items: [
            ("\u{2318}W", "Close window"), ("\u{2318}Q", "Quit")
        ])
    }

    // MARK: - Helpers

    private func appendSection(
        to result: NSMutableAttributedString, title: String,
        styles s: TextStyles, items: [(String, String)]
    ) {
        appendSection(
            to: result, title: title, styles: s,
            richItems: items.map { ($0.0, s.plain($0.1)) }
        )
    }

    private func appendSection(
        to result: NSMutableAttributedString, title: String,
        styles s: TextStyles, richItems: [(String, NSAttributedString)]
    ) {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = 4
        para.paragraphSpacing = 4
        result.append(NSAttributedString(
            string: "\(title)\n",
            attributes: [.font: s.heading, .foregroundColor: s.text, .paragraphStyle: para]
        ))

        let rowPara = NSMutableParagraphStyle()
        rowPara.tabStops = [NSTextTab(textAlignment: .left, location: 190)]
        rowPara.headIndent = 190
        rowPara.lineSpacing = 2
        rowPara.paragraphSpacing = 3

        for (shortcut, action) in richItems {
            let row = NSMutableAttributedString()
            row.append(NSAttributedString(
                string: shortcut, attributes: [.font: s.mono, .foregroundColor: s.text]
            ))
            row.append(NSAttributedString(string: "\t", attributes: [.font: s.body]))
            row.append(action)
            row.append(NSAttributedString(string: "\n", attributes: [.font: s.body]))
            row.addAttribute(.paragraphStyle, value: rowPara, range: row.fullRange)
            result.append(row)
        }

        result.append(NSAttributedString(
            string: "\n", attributes: [.font: s.body, .foregroundColor: s.text]
        ))
    }

    private func trimTrailingWhitespace(_ result: NSMutableAttributedString) {
        while result.length > 0 {
            let last = result.attributedSubstring(from: NSRange(location: result.length - 1, length: 1))
            guard last.string == "\n" || last.string == " " else { break }
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
    }
}

// MARK: - Text Styles

private struct TextStyles {
    let body = NSFont.systemFont(ofSize: 14)
    let bold = NSFont.boldSystemFont(ofSize: 14)
    let heading = NSFont.boldSystemFont(ofSize: 16)
    let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let text = NSColor.labelColor
    let secondary = NSColor.secondaryLabelColor

    func plain(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: body, .foregroundColor: secondary])
    }
}

private extension NSMutableAttributedString {
    var fullRange: NSRange { NSRange(location: 0, length: length) }
}
