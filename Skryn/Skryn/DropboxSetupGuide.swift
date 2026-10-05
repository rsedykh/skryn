import AppKit

/// Step-by-step guide to connecting Dropbox (each user brings their own Dropbox app). A separate,
/// non-modal window, so it can stay open while the user works in the browser and in Settings.
@MainActor
final class DropboxSetupGuide: AnimatedPanel {
    static let appConsoleURL = "https://www.dropbox.com/developers/apps"
    static let permissions = ["files.content.write", "sharing.write", "sharing.read", "account_info.read"]

    private static var shared: DropboxSetupGuide?

    /// Opens the guide, or brings it forward if it's already open.
    static func show() {
        let guide = shared ?? DropboxSetupGuide()
        shared = guide
        guide.present()
    }

    private struct Step {
        let title: String
        let body: String
        var link: (title: String, url: String)?
    }

    private static let steps: [Step] = [
        Step(title: "Create a Dropbox app",
             body: "Open the App Console, sign in, and click Create app.",
             link: ("Open Dropbox App Console \u{2197}", appConsoleURL)),
        Step(title: "Choose its access",
             body: "Choose Scoped access, then App folder: Skryn can only see its own folder, Apps/<app name>, " +
                "never the rest of your Dropbox. Give the app any unique name (for example \u{201C}Skryn Your Name\u{201D}) " +
                "and click Create app."),
        Step(title: "Turn on the permissions",
             body: "Open the Permissions tab and check " + permissions.joined(separator: ", ") + ". " +
                "Then click Submit at the bottom of the page \u{2014} the changes don't apply until you do."),
        Step(title: "Copy the App key",
             body: "Open the Settings tab and copy the App key. Paste it into Skryn Settings \u{2192} Upload \u{2192} " +
                "Dropbox \u{2192} App key. Skryn never needs the App secret."),
        Step(title: "Connect",
             body: "Click Connect Dropbox\u{2026}. Your browser opens Dropbox; click Allow (or Continue, then Allow). " +
                "Dropbox shows a code: copy it, paste it into the Code field in Settings, and click Finish. " +
                "Settings then shows \u{201C}Connected as\u{201D} your name."),
        Step(title: "Upload",
             body: "With Dropbox chosen as the Service, Upload saves files to Dropbox/Apps/<app name>/ and copies a " +
                "public link to the file itself: it opens directly in a browser and embeds in Markdown, GitHub, " +
                "and chat. Anyone with the link can view the file."),
    ]

    private static let troubleshooting = [
        "\u{201C}The Dropbox app lacks the \u{2026} permission\u{201D}: turn it on in the Permissions tab and click " +
            "Submit, then Disconnect and Connect again in Skryn. Dropbox grants permissions at connect time.",
        "\u{201C}The code is invalid or expired\u{201D}: codes work once and expire quickly. Click Connect Dropbox\u{2026} " +
            "again and paste the new code.",
        "A link stopped working: deleting the file, or its shared link in Dropbox, revokes it.",
        "New apps stay in Development status. That's fine for your own account; there's no need to apply for production.",
        "Disconnecting revokes Skryn's access and removes the sign-in token from your Keychain.",
    ]

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        title = "Set Up Dropbox"
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        contentMinSize = NSSize(width: 420, height: 360)
        contentView = makeContent()
        center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func close() {
        super.close()
        Self.shared = nil
    }

    private func makeContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 24, bottom: 24, right: 24)
        stack.addArrangedSubview(Self.heading("Connect Skryn to your Dropbox", size: 17))
        stack.addArrangedSubview(Self.body(
            "Skryn uploads with a Dropbox app that you create, so your files and access stay under your account. " +
                "It takes about two minutes."
        ))
        for (index, step) in Self.steps.enumerated() {
            stack.addArrangedSubview(Self.stepView(number: index + 1, step: step))
        }
        stack.setCustomSpacing(22, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(Self.heading("Troubleshooting", size: 13))
        for tip in Self.troubleshooting {
            stack.addArrangedSubview(Self.body("\u{2022} " + tip))
        }

        return SettingsStyle.scrollingDocument(stack)
    }

    /// A numbered badge beside the step's title, text, and optional link.
    private static func stepView(number: Int, step: Step) -> NSView {
        let badge = NSTextField(labelWithString: "\(number)")
        badge.font = .systemFont(ofSize: 12, weight: .semibold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemBlue.cgColor
        badge.layer?.cornerRadius = 11
        badge.widthAnchor.constraint(equalToConstant: 22).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 22).isActive = true

        var lines: [NSView] = [heading(step.title, size: 13), body(step.body)]
        if let link = step.link { lines.append(LinkButton(title: link.title, url: link.url)) }
        let text = NSStackView(views: lines)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4

        let row = NSStackView(views: [badge, text])
        row.alignment = .top
        row.spacing = 12
        return row
    }

    private static func heading(_ text: String, size: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: .semibold)
        return label
    }

    private static func body(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 390
        label.isSelectable = true  // permission names can be copied
        return label
    }
}
