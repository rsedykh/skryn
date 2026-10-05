import AppKit

/// Uploadcare: a public key in Settings, links on the project's CDN. HTTP lives in `UploadcareService`.
final class UploadcareProvider: UploadProvider {
    let id = "uploadcare"
    let title = "Uploadcare"

    fileprivate static let publicKeyDefaultsKey = "uploadcarePublicKey"

    /// The public key, or nil when none is configured
    fileprivate static var publicKey: String? {
        guard let key = UserDefaults.standard.string(forKey: publicKeyDefaultsKey), !key.isEmpty else { return nil }
        return key
    }

    init() {
        UserDefaults.standard.removeObject(forKey: "uploadcareCdnBase")  // legacy: the CDN now comes from the key
    }

    var setupProblem: String? {
        Self.publicKey == nil ? "Add your Uploadcare public key in Settings" : nil
    }

    func makeSettingsView(onChange: @escaping () -> Void) -> NSView {
        UploadcareSettingsView(onChange: onChange)
    }

    func upload(fileURL: URL, filename: String, contentType: String) async throws -> String {
        guard let publicKey = Self.publicKey else { throw UploadcareError.serverError("No public key") }
        return try await UploadcareService.upload(
            fileURL: fileURL, filename: filename, contentType: contentType, publicKey: publicKey,
            cdnBase: UploadcareService.cdnBase(forPublicKey: publicKey)
        )
    }
}

/// "Public key:" field (saved on every edit) and a link to the dashboard's API keys page.
private final class UploadcareSettingsView: SettingsForm, NSTextFieldDelegate {
    private let keyField = NSTextField(frame: .zero)
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        keyField.placeholderString = "Paste your public key"
        keyField.lineBreakMode = .byTruncatingTail
        keyField.cell?.usesSingleLineMode = true
        keyField.delegate = self
        keyField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        keyField.stringValue = UploadcareProvider.publicKey ?? ""
        addRow("Public key", keyField)
        addFullWidthRow(LinkButton(title: "Get a key \u{2197}", url: "https://app.uploadcare.com/projects/-/api-keys/"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func controlTextDidChange(_ obj: Notification) {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            UserDefaults.standard.removeObject(forKey: UploadcareProvider.publicKeyDefaultsKey)
        } else {
            UserDefaults.standard.set(key, forKey: UploadcareProvider.publicKeyDefaultsKey)
        }
        onChange()
    }
}
