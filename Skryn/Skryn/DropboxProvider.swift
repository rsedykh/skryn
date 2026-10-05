import AppKit

/// Uploads to the app's Dropbox folder and returns the file's permanent public URL (dl.dropboxusercontent.com).
/// Account and HTTP live in DropboxClient.swift.
final class DropboxProvider: UploadProvider {
    let id = "dropbox"
    let title = "Dropbox"
    private let client: DropboxClient
    private let account: DropboxAccount

    init(client: DropboxClient = DropboxClient(), tokens: DropboxAccount.TokenStore = .keychain) {
        self.client = client
        account = DropboxAccount(client: client, tokens: tokens)
    }

    var setupProblem: String? { account.setupProblem?.errorDescription }

    func makeSettingsView(onChange: @escaping () -> Void) -> SettingsForm {
        DropboxSettingsView(account: account, onChange: onChange)
    }

    func upload(fileURL: URL, filename: String, contentType: String) async throws -> String {
        let path = try await account.authorized { token in
            try await client.upload(fileURL: fileURL, path: "/" + filename, accessToken: token)
        }
        let link = try await account.authorized { token in
            try await client.sharedLink(path: path, accessToken: token)
        }
        return DropboxClient.directLink(from: link)
    }
}

/// The guided connect flow: app setup steps, App key, Connect… (opens the browser), paste the code, Finish;
/// once connected, "Connected as …" and Disconnect.
private final class DropboxSettingsView: SettingsForm, NSTextFieldDelegate {
    private let account: DropboxAccount
    private let onChange: () -> Void
    private let appKeyField = NSTextField(frame: .zero)
    private let codeField = NSTextField(frame: .zero)
    /// Connect… or Disconnect, by state
    private lazy var accountButton = NSButton(title: "", target: self, action: #selector(accountClicked))
    private lazy var finishButton = NSButton(title: "Finish", target: self, action: #selector(finish))
    private let spinner = NSProgressIndicator()
    /// Its label reads "Account", or "Connected as …"
    private var accountRow: SettingsRow?
    /// "Code" and its caption: revealed only between Connect and Finish
    private var codeRows: [SettingsRow] = []
    /// The browser authorization in progress, waiting for its code
    private var pending: DropboxAccount.PendingConnection?
    /// A finish or disconnect request is running
    private var busy = false

    init(account: DropboxAccount, onChange: @escaping () -> Void) {
        self.account = account
        self.onChange = onChange
        super.init()
        setupControls()
        addRows()
        appKeyField.stringValue = account.appKey ?? ""
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupControls() {
        appKeyField.placeholderString = "Paste your app key"
        codeField.placeholderString = "Paste the code Dropbox shows"
        for field in [appKeyField, codeField] {
            field.lineBreakMode = .byTruncatingTail
            field.cell?.usesSingleLineMode = true
            field.delegate = self
        }
        appKeyField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        codeField.widthAnchor.constraint(equalToConstant: 160).isActive = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
    }

    @objc private func showSetupGuide() {
        DropboxSetupGuide.show()
    }

    private func addRows() {
        let setup = Self.caption(
            "Create a Dropbox app (Scoped access, App folder) and enable "
                + DropboxSetupGuide.permissions.joined(separator: ", ") + ". The setup guide walks through it."
        )
        addFullWidthRow(setup)
        let guide = LinkButton(title: "Setup guide\u{2026}", url: "")
        guide.target = self
        guide.action = #selector(showSetupGuide)
        let console = LinkButton(title: "Open Dropbox App Console \u{2197}", url: DropboxSetupGuide.appConsoleURL)
        addFullWidthRow(Self.hstack([guide, console]))
        addRow("App key", appKeyField)
        let row = addRow("Account", accountButton)
        row.label?.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)  // a long name truncates
        accountRow = row
        codeRows = [
            // The spinner leads, so Finish stays on the trailing edge with the other controls
            addRow("Code", Self.hstack([spinner, codeField, finishButton])),
            addFullWidthRow(Self.caption("Click Allow in your browser, then paste the code here."))
        ]
    }

    /// Shows the step the user is on and enables what can be done now.
    private func refresh() {
        let connected = account.isConnected
        if connected { pending = nil }
        codeRows.forEach { $0.isRevealed = pending != nil }
        accountRow?.label?.stringValue = connected
            ? account.accountName.map { "Connected as \($0)" } ?? "Connected" : "Account"
        accountButton.title = connected ? "Disconnect" : "Connect Dropbox\u{2026}"

        let idle = !busy
        // A different app key needs a new authorization, so it's locked until Disconnect
        appKeyField.isEnabled = idle && !connected
        appKeyField.toolTip = connected ? "Disconnect to change the app key" : nil
        accountButton.isEnabled = idle && (connected || account.appKey != nil)
        codeField.isEnabled = idle
        finishButton.isEnabled = idle && !trimmedCode.isEmpty
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private var trimmedCode: String { codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === appKeyField else {
            refresh()  // the code field: Finish needs a code
            return
        }
        account.appKey = appKeyField.stringValue
        pending = nil  // its code belongs to the old key
        codeField.stringValue = ""
        refresh()
        onChange()
    }

    @objc private func accountClicked() {
        if account.isConnected { disconnect() } else { connect() }
    }

    private func connect() {
        guard let appKey = account.appKey else { return }
        pending = account.beginConnecting(appKey: appKey)
        codeField.stringValue = ""
        refresh()
        onChange()
        window?.makeFirstResponder(codeField)
    }

    @objc private func finish() {
        guard let pending, !trimmedCode.isEmpty, !busy else { return }
        busy = true
        refresh()
        Task {
            defer {
                busy = false
                refresh()
                onChange()
            }
            do {
                try await account.finishConnecting(pending, code: trimmedCode)
                codeField.stringValue = ""
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't connect Dropbox"
                alert.informativeText = error.localizedDescription
                if let window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            }
        }
    }

    private func disconnect() {
        guard !busy else { return }
        busy = true
        refresh()
        Task {
            await account.disconnect()
            busy = false
            refresh()
            onChange()
        }
    }
}
