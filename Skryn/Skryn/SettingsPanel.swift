import AppKit
import Carbon.HIToolbox
import ServiceManagement

enum SaveModifier: String, CaseIterable {
    case cmd
    case opt
    case ctrl

    var label: String {
        switch self {
        case .cmd: return "\u{2318}\u{23CE}"
        case .opt: return "\u{2325}\u{23CE}"
        case .ctrl: return "\u{2303}\u{23CE}"
        }
    }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .cmd: return .command
        case .opt: return .option
        case .ctrl: return .control
        }
    }
}

enum SaveAction: Equatable {
    case local, clipboard, cloud

    static func action(for flags: NSEvent.ModifierFlags) -> SaveAction? {
        let relevant = flags.intersection([.command, .option, .control])
        let defaults = UserDefaults.standard
        let localMod = SaveModifier(
            rawValue: defaults.string(forKey: "modifierLocal") ?? "opt"
        ) ?? .opt
        let clipboardMod = SaveModifier(
            rawValue: defaults.string(forKey: "modifierClipboard") ?? "cmd"
        ) ?? .cmd
        let cloudMod = SaveModifier(
            rawValue: defaults.string(forKey: "modifierCloud") ?? "ctrl"
        ) ?? .ctrl

        if relevant == localMod.flags { return .local }
        if relevant == clipboardMod.flags { return .clipboard }
        if relevant == cloudMod.flags { return .cloud }
        return nil
    }
}

final class SettingsPanel: NSPanel {
    private let folderLabel = NSTextField(labelWithString: "")
    private let chooseButton = NSButton(title: "Change", target: nil, action: nil)
    private let keyField = NSTextField(frame: .zero)
    private let hotkeyLabel = NSTextField(labelWithString: "App shortcut:")
    private let hotkeyRecorder = HotkeyRecorderButton(frame: .zero)
    private let launchAtLoginCheckbox = NSButton(
        checkboxWithTitle: "Launch at login", target: nil, action: nil
    )

    private let localPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let clipboardPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cloudPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private var modifierLocal: SaveModifier = .opt
    private var modifierClipboard: SaveModifier = .cmd
    private var modifierCloud: SaveModifier = .ctrl

    var onSettingsChanged: (() -> Void)?

    var isRecordingHotkey: Bool { hotkeyRecorder.isRecording }

    func confirmCurrentHotkey() {
        hotkeyRecorder.cancelRecording()
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 325, height: 340),
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
        initialFirstResponder = contentView
    }

    private func setupControls() {
        chooseButton.target = self
        chooseButton.action = #selector(chooseFolderClicked)
        chooseButton.bezelStyle = .rounded

        keyField.placeholderString = "Public key"
        keyField.lineBreakMode = .byTruncatingTail
        keyField.cell?.usesSingleLineMode = true
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        keyField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for popup in [localPopup, clipboardPopup, cloudPopup] {
            for mod in SaveModifier.allCases {
                popup.addItem(withTitle: mod.label)
            }
            popup.target = self
            popup.action = #selector(modifierPopupChanged(_:))
            popup.setContentHuggingPriority(.required, for: .horizontal)
        }
    }

    private func makeActionRow(
        label: String, popup: NSPopUpButton, linkText: String? = nil
    ) -> NSStackView {
        var views: [NSView]
        if let linkText {
            let prefix = NSTextField(labelWithString: "Upload to ")
            let linkField = NSTextField(labelWithString: "")
            let suffix = NSTextField(labelWithString: "")
            let fontSize = prefix.font?.pointSize ?? NSFont.systemFontSize
            let boldFont = NSFont.boldSystemFont(ofSize: fontSize)
            let linkString = NSMutableAttributedString(
                string: linkText,
                attributes: [
                    .link: "https://uploadcare.com",
                    .font: boldFont,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: NSColor.linkColor
                ]
            )
            linkField.attributedStringValue = linkString
            linkField.allowsEditingTextAttributes = true
            linkField.isSelectable = true
            suffix.font = NSFont.systemFont(ofSize: fontSize)

            let textRow = NSStackView(views: [prefix, linkField, suffix])
            textRow.orientation = .horizontal
            textRow.spacing = 0
            textRow.setContentHuggingPriority(.defaultLow, for: .horizontal)
            views = [textRow]
        } else {
            let textLabel = NSTextField(labelWithString: label)
            textLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            views = [textLabel]
        }
        views.append(popup)

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        row.distribution = .fill
        return row
    }

    private func setupLayout() {
        let clipboardRow = makeActionRow(label: "Copy to clipboard", popup: clipboardPopup)

        let localRow = makeActionRow(label: "Save to local folder", popup: localPopup)
        let folderRow = NSStackView(views: [folderLabel, chooseButton])
        folderRow.orientation = .horizontal
        folderRow.spacing = 8

        let localSection = NSStackView(views: [localRow, folderRow])
        localSection.orientation = .vertical
        localSection.alignment = .leading
        localSection.spacing = 6
        folderRow.leadingAnchor.constraint(equalTo: localSection.leadingAnchor).isActive = true

        let cloudRow = makeActionRow(label: "", popup: cloudPopup, linkText: "Uploadcare")
        let keyLink = makeSmallLinkButton(
            title: "Get API key \u{2197}", url: "https://app.uploadcare.com/projects/-/api-keys/"
        )
        let keyRow = NSStackView(views: [keyField, keyLink])
        keyRow.orientation = .horizontal
        keyRow.spacing = 6
        let cloudSection = NSStackView(views: [cloudRow, keyRow])
        cloudSection.orientation = .vertical
        cloudSection.alignment = .leading
        cloudSection.spacing = 6

        let separator = makeSeparator()
        let hotkeyRow = makeHotkeyRow()
        let buttonRow = makeButtonRow()

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)

        let separator2 = makeSeparator()
        let mainStack = NSStackView(
            views: [hotkeyRow, separator, clipboardRow, localSection, cloudSection,
                    separator2, launchAtLoginCheckbox, spacer, buttonRow]
        )
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

        pinTrailingToStack(
            views: [buttonRow, folderRow, localRow, clipboardRow, cloudRow, keyRow],
            stack: mainStack
        )
        for sep in [separator, separator2] {
            sep.leadingAnchor.constraint(
                equalTo: mainStack.leadingAnchor, constant: 20
            ).isActive = true
            sep.trailingAnchor.constraint(
                equalTo: mainStack.trailingAnchor, constant: -20
            ).isActive = true
        }
    }

    private func makeSmallLinkButton(title: String, url: String) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        let linkString = NSMutableAttributedString(
            string: title,
            attributes: [
                .link: url,
                .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor.linkColor
            ]
        )
        field.attributedStringValue = linkString
        field.allowsEditingTextAttributes = true
        field.isSelectable = true
        field.setContentHuggingPriority(.required, for: .horizontal)
        return field
    }

    private func makeHotkeyRow() -> NSStackView {
        let defaultButton = NSButton(
            title: "Reset to default", target: self, action: #selector(resetHotkeyClicked)
        )
        defaultButton.bezelStyle = .rounded
        defaultButton.toolTip = "Reset to \u{2318}\u{21E7}5"
        let row = NSStackView(views: [hotkeyLabel, hotkeyRecorder, defaultButton])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func makeButtonRow() -> NSStackView {
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let row = NSStackView(views: [saveButton, cancelButton])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func makeSeparator() -> NSBox {
        let sep = NSBox()
        sep.boxType = .separator
        return sep
    }

    private func pinTrailingToStack(views: [NSView], stack: NSStackView) {
        for view in views {
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -20).isActive = true
        }
    }

    private func loadSettings() {
        let defaults = UserDefaults.standard

        keyField.stringValue = defaults.string(forKey: "uploadcarePublicKey") ?? ""

        let folderPath = defaults.string(forKey: "saveFolderPath")
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
            ?? "~/Desktop"
        folderLabel.stringValue = abbreviatePath(folderPath)
        folderLabel.toolTip = folderPath

        modifierLocal = SaveModifier(rawValue: defaults.string(forKey: "modifierLocal") ?? "opt") ?? .opt
        modifierClipboard = SaveModifier(
            rawValue: defaults.string(forKey: "modifierClipboard") ?? "cmd"
        ) ?? .cmd
        modifierCloud = SaveModifier(rawValue: defaults.string(forKey: "modifierCloud") ?? "ctrl") ?? .ctrl
        syncPopups()

        let keyCode = defaults.object(forKey: "hotkeyKeyCode") as? UInt32 ?? UInt32(kVK_ANSI_5)
        let mods = defaults.object(forKey: "hotkeyModifiers") as? UInt32 ?? UInt32(cmdKey | shiftKey)
        hotkeyRecorder.setHotkey(keyCode: keyCode, carbonModifiers: mods)

        let status = SMAppService.mainApp.status
        launchAtLoginCheckbox.state = (status == .enabled) ? .on : .off
    }

    private func syncPopups() {
        localPopup.selectItem(at: SaveModifier.allCases.firstIndex(of: modifierLocal) ?? 0)
        clipboardPopup.selectItem(at: SaveModifier.allCases.firstIndex(of: modifierClipboard) ?? 1)
        cloudPopup.selectItem(at: SaveModifier.allCases.firstIndex(of: modifierCloud) ?? 2)
    }

    private func modifierFor(popup: NSPopUpButton) -> SaveModifier {
        let index = popup.indexOfSelectedItem
        guard index >= 0, index < SaveModifier.allCases.count else { return .opt }
        return SaveModifier.allCases[index]
    }

    @objc private func modifierPopupChanged(_ sender: NSPopUpButton) {
        let newValue = modifierFor(popup: sender)

        // Find which property this popup controls and its previous value
        let previous: SaveModifier
        if sender === localPopup {
            previous = modifierLocal
            modifierLocal = newValue
        } else if sender === clipboardPopup {
            previous = modifierClipboard
            modifierClipboard = newValue
        } else {
            previous = modifierCloud
            modifierCloud = newValue
        }

        // Auto-swap: if another popup has the same value, give it our previous value
        if sender !== localPopup && modifierLocal == newValue {
            modifierLocal = previous
        } else if sender !== clipboardPopup && modifierClipboard == newValue {
            modifierClipboard = previous
        } else if sender !== cloudPopup && modifierCloud == newValue {
            modifierCloud = previous
        }

        syncPopups()
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
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

    @objc private func resetHotkeyClicked() {
        hotkeyRecorder.setHotkey(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: UInt32(cmdKey | shiftKey))
    }

    @objc private func cancelClicked() {
        close()
    }

    @objc private func saveClicked() {
        let defaults = UserDefaults.standard
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Persist Uploadcare key
        if key.isEmpty {
            defaults.removeObject(forKey: "uploadcarePublicKey")
        } else {
            defaults.set(key, forKey: "uploadcarePublicKey")
        }

        // Clean up legacy CDN base key (now auto-computed from public key)
        defaults.removeObject(forKey: "uploadcareCdnBase")

        // Persist folder path
        if let fullPath = folderLabel.toolTip {
            let desktopPath = FileManager.default.urls(
                for: .desktopDirectory, in: .userDomainMask
            ).first?.path
            if fullPath == desktopPath {
                defaults.removeObject(forKey: "saveFolderPath")
            } else {
                defaults.set(fullPath, forKey: "saveFolderPath")
            }
        }

        // Persist modifier assignments
        defaults.set(modifierLocal.rawValue, forKey: "modifierLocal")
        defaults.set(modifierClipboard.rawValue, forKey: "modifierClipboard")
        defaults.set(modifierCloud.rawValue, forKey: "modifierCloud")

        // Remove legacy key
        defaults.removeObject(forKey: "saveMode")

        // Persist hotkey
        defaults.set(hotkeyRecorder.recordedKeyCode, forKey: "hotkeyKeyCode")
        defaults.set(hotkeyRecorder.recordedCarbonModifiers, forKey: "hotkeyModifiers")

        // Launch at login
        let service = SMAppService.mainApp
        if launchAtLoginCheckbox.state == .on {
            try? service.register()
        } else {
            try? service.unregister()
        }

        onSettingsChanged?()
        close()
    }
}
