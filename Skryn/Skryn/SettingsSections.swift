import AppKit
import ServiceManagement

/// Resizes the Settings window to its sections (`SettingsPanel.relayout`): animated or not, with extra
/// animations to run alongside, and a completion.
typealias SettingsRelayout = (_ animated: Bool, _ alongside: (() -> Void)?, _ completion: (() -> Void)?) -> Void

// MARK: - Shortcuts

/// Settings → Shortcuts: a recorder per action, each with a reset button; shortcuts stay unique.
@MainActor
final class ShortcutsSection: NSObject {
    private var recorders: [MenuBarAction: HotkeyRecorderButton] = [:]

    var isRecording: Bool { recorders.values.contains(where: \.isRecording) }

    /// A registered global shortcut fired while a recorder listened: the press never reached the recorder,
    /// so keep that recorder's current shortcut.
    func cancelRecording() {
        recorders.values.filter(\.isRecording).forEach { $0.cancelRecording() }
    }

    func makeView() -> NSView {
        let form = SettingsForm()
        for (index, action) in MenuBarAction.available.enumerated() {
            let recorder = HotkeyRecorderButton(frame: .zero)
            recorder.widthAnchor.constraint(equalToConstant: 120).isActive = true
            recorder.setHotkey(action.hotkey)
            recorder.onChange = { [unowned recorder] in action.hotkey = recorder.hotkey }
            recorder.shouldAccept = { [weak self] in self?.isFree($0, otherThan: action) ?? true }
            recorders[action] = recorder
            form.addRow(Self.label(action), SettingsForm.hstack([recorder, makeResetButton(tag: index)]))
        }
        return SettingsStyle.section("Shortcuts", symbol: "keyboard", tint: .systemIndigo, form: form)
    }

    private static func label(_ action: MenuBarAction) -> String {
        action == .screenshot ? "Take screenshot" : action.title
    }

    /// True when no other recorder already uses this shortcut.
    private func isFree(_ hotkey: Hotkey, otherThan action: MenuBarAction) -> Bool {
        !recorders.contains { $0.key != action && $0.value.hotkey == hotkey }
    }

    private func makeResetButton(tag: Int) -> NSButton {
        let image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset to default")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) ?? NSImage()
        let button = NSButton(image: image, target: self, action: #selector(resetClicked(_:)))
        button.tag = tag
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Reset to default"
        return button
    }

    @objc private func resetClicked(_ sender: NSButton) {
        let action = MenuBarAction.available[sender.tag]
        guard let recorder = recorders[action] else { return }
        recorder.cancelRecording()
        guard isFree(action.defaultHotkey, otherThan: action) else {
            NSSound.beep()
            return
        }
        recorder.setHotkey(action.defaultHotkey)
        action.hotkey = action.defaultHotkey
    }
}

// MARK: - After Capture

/// Settings → After Capture: the modifier+Return key of each save action, and the save folder.
@MainActor
final class AfterCaptureSection: NSObject {
    private var popups: [SaveAction: NSPopUpButton] = [:]
    private let folderLabel = NSTextField(labelWithString: "")
    private weak var form: SettingsForm?

    func makeView() -> NSView {
        let form = SettingsForm()
        self.form = form
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let change = NSButton(title: "Change\u{2026}", target: self, action: #selector(chooseFolderClicked))
        change.controlSize = .small

        let rows: [(SaveAction, String)] = [(.local, "Save to folder"), (.clipboard, "Copy to clipboard"),
                                            (.cloud, "Upload")]
        for (action, label) in rows {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            SaveModifier.allCases.forEach { popup.addItem(withTitle: $0.label) }
            popup.target = self
            popup.action = #selector(modifierChanged(_:))
            popups[action] = popup
            form.addRow(label, popup)
            if action == .local { form.addRow("Folder", SettingsForm.hstack([folderLabel, change])) }
        }
        syncPopups()
        showFolder(Defaults.saveFolder.path)
        NotificationCenter.default.addObserver(
            self, selector: #selector(syncPopups), name: SaveModifiers.didChange, object: nil
        )
        return SettingsStyle.section(
            "After Capture", symbol: "square.and.arrow.down", tint: .systemBlue, form: form,
            footer: "Press the key in the editor to choose what happens with a screenshot or recording."
        )
    }

    @objc private func syncPopups() {
        let modifiers = SaveModifiers.current
        for (action, popup) in popups {
            popup.selectItem(at: SaveModifier.allCases.firstIndex(of: modifiers[action]) ?? 0)
        }
    }

    @objc private func modifierChanged(_ sender: NSPopUpButton) {
        guard let action = popups.first(where: { $0.value === sender })?.key,
              SaveModifier.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        action.assign(SaveModifier.allCases[sender.indexOfSelectedItem])
    }

    private func showFolder(_ path: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        folderLabel.stringValue = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        folderLabel.toolTip = path
    }

    @objc private func chooseFolderClicked() {
        guard let window = form?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose where to save screenshots and recordings"
        panel.directoryURL = Defaults.saveFolder

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            Defaults.saveFolder = url
            showFolder(url.path)
        }
    }
}

// MARK: - Upload

/// Settings → Upload: the Service menu, then the chosen provider's own view, swapped when the service changes.
@MainActor
final class UploadSection: NSObject {
    private let relayout: SettingsRelayout
    private let servicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Holds the chosen provider's own Settings view. Stays in its row for good; only its subview is swapped
    /// (re-setting a container's content once left the previous provider's rows drawn under the new one).
    private let providerHost = NSView()
    /// The newest provider view (an outgoing one may still be fading out beneath it)
    private var providerView: NSView? { providerHost.subviews.last }
    /// Pins the host's bottom to the current provider view, so the host takes its height
    private var providerBottom: NSLayoutConstraint?

    init(relayout: @escaping SettingsRelayout) {
        self.relayout = relayout
    }

    func makeView() -> NSView {
        let form = SettingsForm()
        UploadProviders.all.forEach { servicePopup.addItem(withTitle: $0.title) }
        servicePopup.target = self
        servicePopup.action = #selector(serviceChanged)
        form.addRow("Service", servicePopup)
        providerHost.wantsLayer = true
        providerHost.layer?.masksToBounds = true  // an outgoing, taller provider view is clipped, not drawn over
        let hostRow = form.addFullWidthRow(providerHost, padding: 0)
        hostRow.showsSeparator = false  // the provider's rows draw their own
        providerHost.widthAnchor.constraint(equalTo: hostRow.widthAnchor).isActive = true
        showProviderSettings()
        return SettingsStyle.section("Upload", symbol: "icloud.and.arrow.up", tint: .systemTeal, form: form)
    }

    /// Selects the current provider in the Service menu and hosts its view, then resizes the window.
    /// Animated, the new view crossfades over the old one while the window takes the new height.
    private func showProviderSettings(animated: Bool = false) {
        let current = UploadProviders.current
        servicePopup.selectItem(at: UploadProviders.all.firstIndex { $0 === current } ?? 0)
        let outgoing = providerView
        let view = current.makeSettingsView { [weak self] in
            self?.relayout(true, nil, nil)
            NotificationCenter.default.post(name: UploadProviders.didChange, object: nil)  // setupProblem may differ
        }
        view.separatesFirstRow = true  // a hairline under the Service row
        view.translatesAutoresizingMaskIntoConstraints = false
        providerHost.addSubview(view)
        // The host takes the new view's height; the outgoing view keeps its own, clipped by the host
        providerBottom?.isActive = false
        let bottom = view.bottomAnchor.constraint(equalTo: providerHost.bottomAnchor)
        providerBottom = bottom
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: providerHost.topAnchor),
            view.leadingAnchor.constraint(equalTo: providerHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: providerHost.trailingAnchor),
            bottom,
        ])
        guard animated, let outgoing else {
            outgoing?.removeFromSuperview()
            return relayout(false, nil, nil)
        }
        view.alphaValue = 0
        relayout(true, {
            outgoing.animator().alphaValue = 0
            view.animator().alphaValue = 1
        }, { outgoing.removeFromSuperview() })
    }

    @objc private func serviceChanged() {
        guard UploadProviders.all.indices.contains(servicePopup.indexOfSelectedItem) else { return }
        UploadProviders.current = UploadProviders.all[servicePopup.indexOfSelectedItem]
        showProviderSettings(animated: true)
    }
}

// MARK: - General

/// Settings → General: launch at login.
@MainActor
final class GeneralSection: NSObject {
    private let launchAtLoginSwitch = SettingsStyle.makeSwitch()

    func makeView() -> NSView {
        let form = SettingsForm()
        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(launchAtLoginChanged)
        form.addRow("Launch at login", launchAtLoginSwitch)
        syncLaunchAtLogin()
        return SettingsStyle.section("General", symbol: "gearshape", tint: .systemGray, form: form)
    }

    private func syncLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLoginSwitch.state = (status == .enabled || status == .requiresApproval) ? .on : .off
    }

    @objc private func launchAtLoginChanged() {
        applyLaunchAtLogin(launchAtLoginSwitch.state == .on)
        syncLaunchAtLogin()
    }

    /// Registers or unregisters the login item, telling the user when it fails or
    /// when macOS needs them to approve it in System Settings.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        let isRegistered = service.status == .enabled || service.status == .requiresApproval
        if enabled != isRegistered {
            do {
                if enabled {
                    try service.register()
                } else {
                    try service.unregister()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = enabled
                    ? "Couldn't enable launch at login"
                    : "Couldn't disable launch at login"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return
            }
        }

        if enabled && service.status == .requiresApproval {
            let alert = NSAlert()
            alert.messageText = "Approve Skryn in Login Items"
            alert.informativeText = "macOS needs your approval before Skryn can launch at login."
            alert.addButton(withTitle: "Open Login Items")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }
}
