import AppKit

final class SettingsPanel: NSPanel {
    private let localRadio = NSButton(radioButtonWithTitle: "Save to local folder", target: nil, action: nil)
    private let cloudRadio = NSButton(radioButtonWithTitle: "Upload to ", target: nil, action: nil)
    private let uploadcareLink = NSTextField(labelWithString: "")
    private let folderLabel = NSTextField(labelWithString: "")
    private let chooseButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let keyField = NSTextField(frame: .zero)
    private let keyLabel = NSTextField(labelWithString: "Public key:")

    var onSettingsChanged: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "Settings"
        isReleasedWhenClosed = false
        center()
        setupControls()
        setupLayout()
        loadSettings()
        updateEnabledStates()
    }

    private func setupControls() {
        localRadio.target = self
        localRadio.action = #selector(radioChanged)
        cloudRadio.target = self
        cloudRadio.action = #selector(radioChanged)

        let linkURL = "https://app.uploadcare.com"
        let linkString = NSMutableAttributedString(
            string: "Uploadcare",
            attributes: [
                .link: linkURL,
                .font: cloudRadio.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            ]
        )
        uploadcareLink.attributedStringValue = linkString
        uploadcareLink.allowsEditingTextAttributes = true
        uploadcareLink.isSelectable = true

        chooseButton.target = self
        chooseButton.action = #selector(chooseFolderClicked)
        chooseButton.bezelStyle = .rounded

        keyField.placeholderString = "Your public key"
        keyField.lineBreakMode = .byTruncatingTail
        keyField.cell?.usesSingleLineMode = true
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        keyField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func setupLayout() {
        let folderRow = NSStackView(views: [folderLabel, chooseButton])
        folderRow.orientation = .horizontal
        folderRow.spacing = 8

        let localSection = NSStackView(views: [localRadio, folderRow])
        localSection.orientation = .vertical
        localSection.alignment = .leading
        localSection.spacing = 6
        folderRow.leadingAnchor.constraint(equalTo: localSection.leadingAnchor, constant: 18).isActive = true

        let cloudRadioRow = NSStackView(views: [cloudRadio, uploadcareLink])
        cloudRadioRow.orientation = .horizontal
        cloudRadioRow.spacing = 0

        let keyRow = NSStackView(views: [keyLabel, keyField])
        keyRow.orientation = .horizontal
        keyRow.spacing = 8

        let cloudSection = NSStackView(views: [cloudRadioRow, keyRow])
        cloudSection.orientation = .vertical
        cloudSection.alignment = .leading
        cloudSection.spacing = 6
        keyRow.leadingAnchor.constraint(equalTo: cloudSection.leadingAnchor, constant: 18).isActive = true

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)

        let mainStack = NSStackView(views: [localSection, cloudSection, spacer, buttonRow])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 16
        mainStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        mainStack.translatesAutoresizingMaskIntoConstraints = false
        contentView?.addSubview(mainStack)
        if let cv = contentView {
            NSLayoutConstraint.activate([
                mainStack.topAnchor.constraint(equalTo: cv.topAnchor),
                mainStack.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
                mainStack.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
                mainStack.trailingAnchor.constraint(equalTo: cv.trailingAnchor)
            ])
        }

        buttonRow.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor, constant: -20).isActive = true
        folderRow.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor, constant: -20).isActive = true
        keyRow.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor, constant: -20).isActive = true
    }

    private func loadSettings() {
        let savedKey = UserDefaults.standard.string(forKey: "uploadcarePublicKey") ?? ""
        let mode = UserDefaults.standard.string(forKey: "saveMode")
        // Backwards compat: if no saveMode, infer from key presence
        let isCloud = mode == "cloud" || (mode == nil && !savedKey.isEmpty)

        if isCloud {
            cloudRadio.state = .on
            localRadio.state = .off
        } else {
            localRadio.state = .on
            cloudRadio.state = .off
        }
        keyField.stringValue = savedKey

        let folderPath = UserDefaults.standard.string(forKey: "saveFolderPath")
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
            ?? "~/Desktop"
        folderLabel.stringValue = abbreviatePath(folderPath)
        folderLabel.toolTip = folderPath
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    @objc private func radioChanged(_ sender: NSButton) {
        // Radio buttons in different stack views don't auto-group — toggle manually
        if sender === localRadio {
            cloudRadio.state = .off
        } else {
            localRadio.state = .off
        }
        updateEnabledStates()
    }

    private func updateEnabledStates() {
        let isLocal = localRadio.state == .on
        folderLabel.textColor = isLocal ? .labelColor : .tertiaryLabelColor
        chooseButton.isEnabled = isLocal
        keyLabel.textColor = isLocal ? .tertiaryLabelColor : .labelColor
        keyField.isEnabled = !isLocal
    }

    @objc private func chooseFolderClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose where to save screenshots"

        panel.beginSheetModal(for: self) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.folderLabel.stringValue = self.abbreviatePath(url.path)
            self.folderLabel.toolTip = url.path
        }
    }

    @objc private func cancelClicked() {
        close()
    }

    @objc private func saveClicked() {
        // Always persist the key (even when switching to local)
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if cloudRadio.state == .on {
            if key.isEmpty {
                keyField.window?.makeFirstResponder(keyField)
                NSSound.beep()
                return
            }
            UserDefaults.standard.set("cloud", forKey: "saveMode")
            UserDefaults.standard.set(key, forKey: "uploadcarePublicKey")
            UserDefaults.standard.removeObject(forKey: "saveFolderPath")
        } else {
            let wasCloud = UserDefaults.standard.string(forKey: "saveMode") == "cloud"
                || (UserDefaults.standard.string(forKey: "saveMode") == nil
                    && UserDefaults.standard.string(forKey: "uploadcarePublicKey") != nil)

            UserDefaults.standard.set("local", forKey: "saveMode")
            if !key.isEmpty {
                UserDefaults.standard.set(key, forKey: "uploadcarePublicKey")
            }

            // Save folder path from the label's tooltip (full path)
            if let fullPath = folderLabel.toolTip {
                let desktopPath = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
                if fullPath == desktopPath {
                    UserDefaults.standard.removeObject(forKey: "saveFolderPath")
                } else {
                    UserDefaults.standard.set(fullPath, forKey: "saveFolderPath")
                }
            }

            if wasCloud {
                onSettingsChanged?()
            }
        }

        close()
    }
}
