import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement

/// UserDefaults keys and default values shared across the app
enum Defaults {
    static let saveFolderPath = "saveFolderPath"
    static let hotkeyKeyCode = "hotkeyKeyCode"
    static let hotkeyModifiers = "hotkeyModifiers"
    static let hasLaunchedBefore = "hasLaunchedBefore"

    static let defaultHotkeyKeyCode = UInt32(kVK_ANSI_5)
    static let defaultHotkeyModifiers = UInt32(cmdKey | shiftKey)

    /// The configured global hotkey, falling back to ⌘⇧5
    static var hotkey: (keyCode: UInt32, modifiers: UInt32) {
        let defaults = UserDefaults.standard
        return (
            defaults.object(forKey: hotkeyKeyCode) as? UInt32 ?? defaultHotkeyKeyCode,
            defaults.object(forKey: hotkeyModifiers) as? UInt32 ?? defaultHotkeyModifiers
        )
    }

    static var desktopFolder: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Where local saves go: the custom folder if one is set, otherwise the Desktop
    static var saveFolder: URL {
        guard let path = UserDefaults.standard.string(forKey: saveFolderPath) else { return desktopFolder }
        return URL(fileURLWithPath: path)
    }
}

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

    /// Reads a configured modifier from UserDefaults, falling back to the given default.
    static func configured(forKey key: String, default fallback: SaveModifier) -> SaveModifier {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return fallback }
        return SaveModifier(rawValue: raw) ?? fallback
    }
}

enum SaveAction: CaseIterable {
    case local, clipboard, cloud

    var defaultsKey: String {
        switch self {
        case .local: return "modifierLocal"
        case .clipboard: return "modifierClipboard"
        case .cloud: return "modifierCloud"
        }
    }

    var defaultModifier: SaveModifier {
        switch self {
        case .local: return .opt
        case .clipboard: return .cmd
        case .cloud: return .ctrl
        }
    }

    var configuredModifier: SaveModifier {
        SaveModifier.configured(forKey: defaultsKey, default: defaultModifier)
    }

    static func action(for flags: NSEvent.ModifierFlags) -> SaveAction? {
        let relevant = flags.intersection([.command, .option, .control])
        return allCases.first { $0.configuredModifier.flags == relevant }
    }
}

/// Settings window. Every control applies as soon as it changes and calls `onSettingsChanged`.
/// Grouped cards under titled sections; the window resizes with an animation, its top edge fixed.
final class SettingsPanel: AnimatedPanel {
    /// The column of sections, pinned to the top: the window grows and shrinks below it
    private let sections = NSStackView()
    /// Titlebar height plus breathing room (the content runs under the transparent titlebar)
    private var topInset: CGFloat = 40

    private let screenshotRecorder = HotkeyRecorderButton(frame: .zero)
    private let recordRecorder = HotkeyRecorderButton(frame: .zero)
    private let areaRecorder = HotkeyRecorderButton(frame: .zero)
    /// Every shortcut recorder shown, so shortcuts can be kept unique across them
    private var hotkeyRecorders: [HotkeyRecorderButton] {
        recordingSupported ? [screenshotRecorder, areaRecorder, recordRecorder] : [screenshotRecorder, areaRecorder]
    }

    private let localPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let clipboardPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cloudPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let folderLabel = NSTextField(labelWithString: "")

    private let servicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Holds the chosen provider's own Settings view. Stays in its row for good; only its subview is swapped
    /// (re-setting a container's content once left the previous provider's rows drawn under the new one).
    private let providerHost = NSView()
    /// The newest provider view (an outgoing one may still be fading out beneath it)
    private var providerView: NSView? { providerHost.subviews.last }
    /// Pins the host's bottom to the current provider view, so the host takes its height
    private var providerBottom: NSLayoutConstraint?

    private let microphoneSwitch = SettingsStyle.makeSwitch()
    private let microphonePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let systemAudioSwitch = SettingsStyle.makeSwitch()
    private let cameraSwitch = SettingsStyle.makeSwitch()
    private let cameraPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let clicksSwitch = SettingsStyle.makeSwitch()
    private let cursorSwitch = SettingsStyle.makeSwitch()
    private let keystrokesSwitch = SettingsStyle.makeSwitch()
    /// Keyboard layout that names keys in the overlay (nil = as typed)
    private let keyLayoutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let countdownSwitch = SettingsStyle.makeSwitch()
    private let accessibilityLink = LinkButton(
        title: "Open Settings\u{2026}",
        url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )
    /// "Needs Accessibility permission": revealed only while the permission is missing
    private var accessibilityRow: SettingsRow?

    private let launchAtLoginSwitch = SettingsStyle.makeSwitch()
    private let menuBarSection = MenuBarSettingsSection()

    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let presetCaption = SettingsForm.caption("")
    private let imageFormatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let losslessSwitch = SettingsStyle.makeSwitch()
    private let qualitySlider = NSSlider(value: 0.85, minValue: 0.1, maxValue: 1, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: "")
    private let videoFormatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let frameRatePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let retinaSwitch = SettingsStyle.makeSwitch()
    private let stripMetadataSwitch = SettingsStyle.makeSwitch()
    /// Revealed only where they apply (see `syncOutput`)
    private var losslessRow: SettingsRow?
    private var qualityRow: SettingsRow?
    private var videoCaptionRow: SettingsRow?

    /// Screen recording needs macOS 15; on 14 its shortcut and section are hidden.
    private let recordingSupported: Bool = {
        if #available(macOS 15, *) { return true }
        return false
    }()

    var onSettingsChanged: (() -> Void)?

    var isRecordingHotkey: Bool { hotkeyRecorders.contains(where: \.isRecording) }

    /// Called when a registered global hotkey fires while a recorder is listening:
    /// the press never reaches the recorder, so keep that recorder's current shortcut.
    func confirmCurrentHotkey() {
        for recorder in hotkeyRecorders where recorder.isRecording {
            recorder.cancelRecording()
        }
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: SettingsStyle.windowWidth, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Skryn Settings"
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        removeLegacyDefaults()
        setupControls()
        setupLayout()
        loadSettings()
        relayout(animated: false)
        center()
        initialFirstResponder = contentView
        NotificationCenter.default.addObserver(
            self, selector: #selector(recordingOptionsChanged), name: RecordingOptions.didChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(outputSettingsChanged), name: OutputSettings.didChange, object: nil
        )
    }

    override func becomeKey() {
        super.becomeKey()
        // The user may have granted Accessibility in System Settings meanwhile
        refreshAccessibilityLink()
    }

    // MARK: - Controls

    private func setupControls() {
        for popup in [localPopup, clipboardPopup, cloudPopup] {
            SaveModifier.allCases.forEach { popup.addItem(withTitle: $0.label) }
            popup.target = self
            popup.action = #selector(modifierPopupChanged(_:))
        }

        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        UploadProviders.all.forEach { servicePopup.addItem(withTitle: $0.title) }
        servicePopup.target = self
        servicePopup.action = #selector(serviceChanged)

        for recorder in [screenshotRecorder, areaRecorder, recordRecorder] {
            recorder.widthAnchor.constraint(equalToConstant: 120).isActive = true
            recorder.onChange = { [weak self, unowned recorder] in self?.hotkeyRecorded(by: recorder) }
            recorder.shouldAccept = { [weak self, unowned recorder] code, mods in
                self?.isFree(code, mods, otherThan: recorder) ?? true
            }
        }

        let recordingControls: [NSControl] = [
            microphoneSwitch, microphonePopup, systemAudioSwitch, cameraSwitch, cameraPopup, clicksSwitch,
            cursorSwitch, keystrokesSwitch, keyLayoutPopup, countdownSwitch,
        ]
        for control in recordingControls {
            control.target = self
            control.action = #selector(recordingControlChanged(_:))
        }
        // Long device names would otherwise stretch the window
        for popup in [microphonePopup, cameraPopup, keyLayoutPopup] {
            popup.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        }
        keyLayoutPopup.toolTip = "Name keys with this layout, so shortcuts read the same whatever layout you type in"
        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(launchAtLoginChanged)
        setupOutputControls()
    }

    private func setupOutputControls() {
        // Custom can't be picked: it's shown, selected, only while the settings match no preset
        presetPopup.autoenablesItems = false
        OutputSettings.Preset.allCases.forEach { presetPopup.addItem(withTitle: $0.title) }
        presetPopup.addItem(withTitle: "Custom")
        presetPopup.lastItem?.isEnabled = false
        ImageFormat.allCases.forEach { imageFormatPopup.addItem(withTitle: $0.title) }
        VideoFormat.allCases.forEach { videoFormatPopup.addItem(withTitle: $0.title) }
        frameRatePopup.addItems(withTitles: ["30 fps", "60 fps"])
        qualitySlider.controlSize = .small
        qualitySlider.isContinuous = true
        qualitySlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        qualityLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        qualityLabel.textColor = .secondaryLabelColor
        qualityLabel.alignment = .right
        qualityLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true  // "100%" never nudges the slider
        let controls: [NSControl] = [
            presetPopup, imageFormatPopup, losslessSwitch, qualitySlider, videoFormatPopup, frameRatePopup,
            retinaSwitch, stripMetadataSwitch,
        ]
        for control in controls {
            control.target = self
            control.action = #selector(outputControlChanged(_:))
        }
    }

    private func setupLayout() {
        var views = [shortcutsSection(), afterCaptureSection(), outputSection(), uploadSection()]
        if recordingSupported { views.append(recordingSection()) }
        menuBarSection.onChange = { [weak self] in self?.onSettingsChanged?() }
        views.append(menuBarSection.makeView())
        let general = SettingsForm()
        general.addRow("Launch at login", launchAtLoginSwitch)
        views.append(SettingsStyle.section("General", symbol: "gearshape", tint: .systemGray, form: general))

        sections.orientation = .vertical
        sections.alignment = .leading
        sections.spacing = 24
        sections.translatesAutoresizingMaskIntoConstraints = false
        views.forEach { sections.addArrangedSubview($0) }

        // Flipped, so the sections keep their place while the window's height animates. In a scroll
        // view: on a short screen (a 13" laptop) the window stops at the visible height and scrolls.
        let container = FlippedView()
        container.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sections)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false  // topInset already clears the transparent titlebar
        scroll.documentView = container
        contentView = scroll
        let titlebar = frame.height - contentLayoutRect.height
        topInset = (titlebar > 0 ? titlebar : 28) + 8
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            sections.topAnchor.constraint(equalTo: container.topAnchor, constant: topInset),
            sections.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            sections.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            sections.widthAnchor.constraint(equalToConstant: SettingsStyle.cardWidth),
        ] + views.map { $0.widthAnchor.constraint(equalTo: sections.widthAnchor) })
    }

    private func shortcutsSection() -> NSView {
        let form = SettingsForm()
        form.addRow("Take screenshot", SettingsForm.hstack([screenshotRecorder, makeResetButton(#selector(resetScreenshotHotkey))]))
        form.addRow("Screenshot of area", SettingsForm.hstack([areaRecorder, makeResetButton(#selector(resetAreaHotkey))]))
        if recordingSupported {
            form.addRow("Record screen", SettingsForm.hstack([recordRecorder, makeResetButton(#selector(resetRecordHotkey))]))
        }
        return SettingsStyle.section("Shortcuts", symbol: "keyboard", tint: .systemIndigo, form: form)
    }

    private func afterCaptureSection() -> NSView {
        let form = SettingsForm()
        form.addRow("Save to folder", localPopup)
        let change = NSButton(title: "Change\u{2026}", target: self, action: #selector(chooseFolderClicked))
        change.controlSize = .small
        form.addRow("Folder", SettingsForm.hstack([folderLabel, change]))
        form.addRow("Copy to clipboard", clipboardPopup)
        form.addRow("Upload", cloudPopup)
        return SettingsStyle.section(
            "After Capture", symbol: "square.and.arrow.down", tint: .systemBlue, form: form,
            footer: "Press the key in the editor to choose what happens with a screenshot or recording."
        )
    }

    private func outputSection() -> NSView {
        let form = SettingsForm()
        form.addRow("Preset", presetPopup)
        addCaption(presetCaption, to: form)
        form.addRow("Screenshot format", imageFormatPopup)
        losslessRow = form.addRow("Lossless", losslessSwitch)
        // The percentage leads, so the row's label lines up with its text
        qualityRow = form.addRow("Quality", SettingsForm.hstack([qualityLabel, qualitySlider]))
        if recordingSupported {
            form.addRow("Recording format", videoFormatPopup)
            videoCaptionRow = addCaption(SettingsForm.caption("No sound; converted after recording"), to: form)
            form.addRow("Frame rate", frameRatePopup)
        }
        form.addRow("Retina resolution", retinaSwitch)
        addCaption(SettingsForm.caption("Off saves at 1x: half the width and height, much smaller files"), to: form)
        form.addRow("Strip metadata", stripMetadataSwitch)
        return SettingsStyle.section("Output", symbol: "doc.badge.gearshape", tint: .systemOrange, form: form)
    }

    /// A quiet note tucked under the row above it (no hairline between them).
    @discardableResult
    private func addCaption(_ caption: NSTextField, to form: SettingsForm) -> SettingsRow {
        let inset = NSStackView(views: [caption])
        inset.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        let row = form.addFullWidthRow(inset, padding: 0)
        row.showsSeparator = false
        return row
    }

    /// Service picker, then the chosen provider's own view (see `showProviderSettings`).
    private func uploadSection() -> NSView {
        let form = SettingsForm()
        form.addRow("Service", servicePopup)
        providerHost.wantsLayer = true
        providerHost.layer?.masksToBounds = true  // an outgoing, taller provider view is clipped, not drawn over
        let hostRow = form.addFullWidthRow(providerHost, padding: 0)
        hostRow.showsSeparator = false  // the provider's rows draw their own
        providerHost.widthAnchor.constraint(equalTo: hostRow.widthAnchor).isActive = true
        return SettingsStyle.section("Upload", symbol: "icloud.and.arrow.up", tint: .systemTeal, form: form)
    }

    private func recordingSection() -> NSView {
        let form = SettingsForm()
        // Device menus get their own row under their switch: beside it they squeezed the title to "Re…"
        form.addRow("Record microphone", microphoneSwitch)
        form.addRow("Microphone", microphonePopup)
        form.addRow("Record system audio", systemAudioSwitch)
        form.addRow("Show camera", cameraSwitch)
        form.addRow("Camera", cameraPopup)
        form.addRow("Highlight mouse clicks", clicksSwitch)
        form.addRow("Show cursor", cursorSwitch)
        form.addRow("Show keystrokes", keystrokesSwitch)
        form.addRow("Key labels", keyLayoutPopup)
        let permission = form.addRow("Keystrokes need Accessibility permission", accessibilityLink)
        permission.label?.textColor = .secondaryLabelColor
        accessibilityRow = permission
        form.addRow("3-2-1 countdown", countdownSwitch)
        return SettingsStyle.section("Recording", symbol: "record.circle", tint: .systemRed, form: form)
    }

    private func makeResetButton(_ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset to default")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Reset to default"
        return button
    }

    /// Sizes the window to its sections, keeping the top edge put. Animated, the sections' frames move
    /// (rows sliding open or shut, a provider view crossfading in `alongside`) together with the window.
    private func relayout(
        animated: Bool, alongside: (() -> Void)? = nil, completion: (@MainActor () -> Void)? = nil
    ) {
        let width = SettingsStyle.windowWidth
        let contentHeight = (topInset + sections.fittingSize.height + 20).rounded()
        // Never taller than the screen's usable area; the rest scrolls
        let maxHeight = (screen ?? NSScreen.main)?.visibleFrame.height ?? contentHeight
        let height = min(contentHeight, maxHeight)
        let visible = (screen ?? NSScreen.main)?.visibleFrame
        var target = NSRect(x: (frame.midX - width / 2).rounded(), y: frame.maxY - height, width: width, height: height)
        if let visible {  // growing downward must not run past the Dock or off the bottom
            target.origin.y = max(target.origin.y, visible.minY)
            target.origin.y = min(target.origin.y, visible.maxY - height)
        }
        let animate = animated && isVisible && !HUDMotion.reduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animate ? HUDMotion.enterDuration : 0
            context.timingFunction = HUDMotion.enterTiming
            context.allowsImplicitAnimation = animate
            alongside?()
            if animate { animator().setFrame(target, display: true) } else { setFrame(target, display: true) }
            contentView?.layoutSubtreeIfNeeded()
        }, completionHandler: {
            MainActor.assumeIsolated { completion?() }
        })
    }

    // MARK: - Loading

    private func removeLegacyDefaults() {
        UserDefaults.standard.removeObject(forKey: "saveMode")
    }

    private func loadSettings() {
        showProviderSettings()
        showFolder(Defaults.saveFolder.path)
        syncPopups()

        let hotkey = Defaults.hotkey
        screenshotRecorder.setHotkey(keyCode: hotkey.keyCode, carbonModifiers: hotkey.modifiers)
        let area = Defaults.areaHotkey
        areaRecorder.setHotkey(keyCode: area.keyCode, carbonModifiers: area.modifiers)
        let record = Defaults.recordHotkey
        recordRecorder.setHotkey(keyCode: record.keyCode, carbonModifiers: record.modifiers)

        if recordingSupported { loadRecordingOptions() }
        syncOutput()
        syncLaunchAtLogin()
    }

    /// Shows `OutputSettings.current`: the matching preset, and only the rows that apply to the chosen formats.
    private func syncOutput() {
        let settings = OutputSettings.current
        let preset = settings.preset
        presetPopup.lastItem?.isHidden = preset != nil
        presetPopup.selectItem(at: preset.flatMap { OutputSettings.Preset.allCases.firstIndex(of: $0) }
            ?? presetPopup.numberOfItems - 1)
        presetCaption.stringValue = preset?.summary ?? "Your own mix of the settings below"
        imageFormatPopup.selectItem(at: ImageFormat.allCases.firstIndex(of: settings.imageFormat) ?? 0)
        losslessSwitch.state = settings.imageLossless ? .on : .off
        if abs(qualitySlider.doubleValue - settings.imageQuality) > 0.005 {  // don't fight a drag in progress
            qualitySlider.doubleValue = settings.imageQuality
        }
        qualityLabel.stringValue = "\(Int((settings.imageQuality * 100).rounded()))%"
        videoFormatPopup.selectItem(at: VideoFormat.allCases.firstIndex(of: settings.videoFormat) ?? 0)
        frameRatePopup.selectItem(at: settings.frameRate == 60 ? 1 : 0)
        retinaSwitch.state = settings.retina ? .on : .off
        stripMetadataSwitch.state = settings.stripMetadata ? .on : .off

        let format = settings.imageFormat
        // macOS can't write AVIF/HEIC bit-exact; only WebP's lossless is exact
        losslessRow?.label?.stringValue = format.isLosslessExact ? "Lossless" : "Near-lossless"
        let reveals: [(SettingsRow?, Bool)] = [
            (losslessRow, format.hasLosslessOption),
            (qualityRow, format.hasQuality && !(format.hasLosslessOption && settings.imageLossless)),
            (videoCaptionRow, settings.videoFormat.isAnimatedImage),
        ]
        var changed = false
        for case let (row?, show) in reveals where row.isRevealed != show {
            row.isRevealed = show
            changed = true
        }
        if changed { relayout(animated: true) }
    }

    private func loadRecordingOptions() {
        let options = RecordingOptions.current
        fillDevicePopup(microphonePopup, devices: Self.microphones(), selectedID: options.microphoneDeviceID)
        fillDevicePopup(cameraPopup, devices: Self.cameras(), selectedID: options.cameraDeviceID)
        fillPopup(
            keyLayoutPopup, defaultTitle: "As Typed",
            choices: KeyboardLayout.enabled().map { ($0.id, $0.name) }, selectedID: options.keystrokeLayoutID
        )
        microphoneSwitch.state = options.microphone ? .on : .off
        microphonePopup.isEnabled = options.microphone
        systemAudioSwitch.state = options.systemAudio ? .on : .off
        cameraSwitch.state = options.camera ? .on : .off
        cameraPopup.isEnabled = options.camera
        clicksSwitch.state = options.highlightClicks ? .on : .off
        cursorSwitch.state = options.showCursor ? .on : .off
        keystrokesSwitch.state = options.showKeystrokes ? .on : .off
        keyLayoutPopup.isEnabled = options.showKeystrokes
        countdownSwitch.state = options.countdown ? .on : .off
        refreshAccessibilityLink()
    }

    private func refreshAccessibilityLink() {
        guard let accessibilityRow, accessibilityRow.isRevealed == AXIsProcessTrusted() else { return }
        accessibilityRow.isRevealed.toggle()
        relayout(animated: true)
    }

    private func syncPopups() {
        localPopup.selectItem(at: SaveModifier.allCases.firstIndex(of: SaveAction.local.configuredModifier) ?? 0)
        clipboardPopup.selectItem(
            at: SaveModifier.allCases.firstIndex(of: SaveAction.clipboard.configuredModifier) ?? 0
        )
        cloudPopup.selectItem(at: SaveModifier.allCases.firstIndex(of: SaveAction.cloud.configuredModifier) ?? 0)
    }

    private func syncLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLoginSwitch.state = (status == .enabled || status == .requiresApproval) ? .on : .off
    }

    private func showFolder(_ path: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        folderLabel.stringValue = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        folderLabel.toolTip = path
    }

    // MARK: - Devices

    private static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified
        ).devices
    }

    private static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified
        ).devices
    }

    /// "System Default" (nil) followed by each device, whose `uniqueID` is the item's represented object.
    /// ponytail: a saved device that is unplugged shows as System Default; its saved ID stays until the popup is changed.
    private func fillDevicePopup(_ popup: NSPopUpButton, devices: [AVCaptureDevice], selectedID: String?) {
        fillPopup(
            popup, defaultTitle: "System Default",
            choices: devices.map { ($0.uniqueID, $0.localizedName) }, selectedID: selectedID
        )
    }

    /// The nil choice first, then `choices`; selects `selectedID`, or the nil choice if it's gone.
    private func fillPopup(
        _ popup: NSPopUpButton, defaultTitle: String, choices: [(id: String, title: String)], selectedID: String?
    ) {
        popup.removeAllItems()
        popup.addItem(withTitle: defaultTitle)
        for choice in choices {
            popup.addItem(withTitle: choice.title)
            popup.lastItem?.representedObject = choice.id
        }
        let index = popup.itemArray.firstIndex { ($0.representedObject as? String) == selectedID }
        popup.selectItem(at: index ?? 0)
    }

    // MARK: - Actions

    @objc private func recordingControlChanged(_ sender: NSControl) {
        var options = RecordingOptions.current
        options.microphone = microphoneSwitch.state == .on
        if sender === microphonePopup {
            options.microphoneDeviceID = microphonePopup.selectedItem?.representedObject as? String
        }
        options.systemAudio = systemAudioSwitch.state == .on
        options.camera = cameraSwitch.state == .on
        if sender === cameraPopup {
            options.cameraDeviceID = cameraPopup.selectedItem?.representedObject as? String
        }
        options.highlightClicks = clicksSwitch.state == .on
        options.showCursor = cursorSwitch.state == .on
        options.showKeystrokes = keystrokesSwitch.state == .on
        if sender === keyLayoutPopup {
            options.keystrokeLayoutID = keyLayoutPopup.selectedItem?.representedObject as? String
        }
        options.countdown = countdownSwitch.state == .on
        RecordingOptions.current = options
        microphonePopup.isEnabled = options.microphone
        cameraPopup.isEnabled = options.camera
        keyLayoutPopup.isEnabled = options.showKeystrokes
        onSettingsChanged?()
    }

    @objc private func outputControlChanged(_ sender: NSControl) {
        var settings = OutputSettings.current
        if sender === presetPopup {
            let presets = OutputSettings.Preset.allCases
            guard presets.indices.contains(presetPopup.indexOfSelectedItem) else { return }
            presets[presetPopup.indexOfSelectedItem].apply(to: &settings)
        } else {
            settings.imageFormat = ImageFormat.allCases[max(imageFormatPopup.indexOfSelectedItem, 0)]
            settings.imageLossless = losslessSwitch.state == .on
            settings.imageQuality = (qualitySlider.doubleValue * 100).rounded() / 100
            settings.videoFormat = VideoFormat.allCases[max(videoFormatPopup.indexOfSelectedItem, 0)]
            settings.frameRate = frameRatePopup.indexOfSelectedItem == 1 ? 60 : 30
            settings.retina = retinaSwitch.state == .on
            settings.stripMetadata = stripMetadataSwitch.state == .on
        }
        OutputSettings.current = settings  // posts didChange when it differs, which resyncs the rows
        onSettingsChanged?()
    }

    @objc private func outputSettingsChanged() {
        syncOutput()
    }

    @objc private func recordingOptionsChanged() {
        if recordingSupported { loadRecordingOptions() }
    }

    @objc private func modifierPopupChanged(_ sender: NSPopUpButton) {
        let popups: [(SaveAction, NSPopUpButton)] = [(.local, localPopup), (.clipboard, clipboardPopup),
                                                     (.cloud, cloudPopup)]
        guard let action = popups.first(where: { $0.1 === sender })?.0,
              sender.indexOfSelectedItem >= 0 else { return }
        let newValue = SaveModifier.allCases[sender.indexOfSelectedItem]
        let previous = action.configuredModifier

        // Auto-swap: the action that had this key takes over the changed action's previous key
        let defaults = UserDefaults.standard
        if let other = SaveAction.allCases.first(where: { $0 != action && $0.configuredModifier == newValue }) {
            defaults.set(previous.rawValue, forKey: other.defaultsKey)
        }
        defaults.set(newValue.rawValue, forKey: action.defaultsKey)
        syncPopups()
        onSettingsChanged?()
    }

    @objc private func chooseFolderClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose where to save screenshots and recordings"
        panel.directoryURL = Defaults.saveFolder

        panel.beginSheetModal(for: self) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if url.path == Defaults.desktopFolder.path {
                UserDefaults.standard.removeObject(forKey: Defaults.saveFolderPath)
            } else {
                UserDefaults.standard.set(url.path, forKey: Defaults.saveFolderPath)
            }
            showFolder(url.path)
            onSettingsChanged?()
        }
    }

    // MARK: - Upload service

    /// Selects the current provider in the Service menu and hosts its view, then resizes the window.
    /// Animated, the new view crossfades over the old one while the window takes the new height.
    private func showProviderSettings(animated: Bool = false) {
        let current = UploadProviders.current
        servicePopup.selectItem(at: UploadProviders.all.firstIndex { $0 === current } ?? 0)
        let outgoing = providerView
        let view = current.makeSettingsView { [weak self] in
            self?.relayout(animated: true)
            self?.onSettingsChanged?()
        }
        (view as? SettingsForm)?.separatesFirstRow = true  // a hairline under the Service row
        view.translatesAutoresizingMaskIntoConstraints = false
        providerHost.addSubview(view)
        // The host takes the new view's height; the outgoing view keeps its own, clipped by the host
        providerBottom?.isActive = false
        providerBottom = view.bottomAnchor.constraint(equalTo: providerHost.bottomAnchor)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: providerHost.topAnchor),
            view.leadingAnchor.constraint(equalTo: providerHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: providerHost.trailingAnchor),
            providerBottom,
        ].compactMap { $0 })
        guard animated, let outgoing else {
            outgoing?.removeFromSuperview()
            return relayout(animated: false)
        }
        view.alphaValue = 0
        relayout(animated: true, alongside: {
            outgoing.animator().alphaValue = 0
            view.animator().alphaValue = 1
        }, completion: { outgoing.removeFromSuperview() })
    }

    @objc private func serviceChanged() {
        guard servicePopup.indexOfSelectedItem >= 0 else { return }
        UploadProviders.current = UploadProviders.all[servicePopup.indexOfSelectedItem]
        showProviderSettings(animated: true)
        onSettingsChanged?()
    }

    // MARK: - Hotkeys

    /// True when no other recorder already uses this shortcut.
    private func isFree(_ keyCode: UInt32, _ modifiers: UInt32, otherThan recorder: HotkeyRecorderButton?) -> Bool {
        !hotkeyRecorders.contains { other in
            other !== recorder && other.recordedKeyCode == keyCode && other.recordedCarbonModifiers == modifiers
        }
    }

    private func hotkeyRecorded(by recorder: HotkeyRecorderButton) {
        let keys = recorder === screenshotRecorder ? (Defaults.hotkeyKeyCode, Defaults.hotkeyModifiers)
            : recorder === areaRecorder ? (Defaults.areaHotkeyKeyCode, Defaults.areaHotkeyModifiers)
            : (Defaults.recordHotkeyKeyCode, Defaults.recordHotkeyModifiers)
        UserDefaults.standard.set(recorder.recordedKeyCode, forKey: keys.0)
        UserDefaults.standard.set(recorder.recordedCarbonModifiers, forKey: keys.1)
        onSettingsChanged?()
    }

    @objc private func resetScreenshotHotkey() {
        resetHotkey(screenshotRecorder, Defaults.defaultHotkeyKeyCode, Defaults.defaultHotkeyModifiers)
    }

    @objc private func resetAreaHotkey() {
        resetHotkey(areaRecorder, Defaults.defaultAreaHotkeyKeyCode, Defaults.defaultAreaHotkeyModifiers)
    }

    @objc private func resetRecordHotkey() {
        resetHotkey(recordRecorder, Defaults.defaultRecordHotkeyKeyCode, Defaults.defaultRecordHotkeyModifiers)
    }

    private func resetHotkey(_ recorder: HotkeyRecorderButton, _ keyCode: UInt32, _ modifiers: UInt32) {
        recorder.cancelRecording()
        guard isFree(keyCode, modifiers, otherThan: recorder) else {
            NSSound.beep()
            return
        }
        recorder.setHotkey(keyCode: keyCode, carbonModifiers: modifiers)
        hotkeyRecorded(by: recorder)
    }

    // MARK: - Launch at login

    @objc private func launchAtLoginChanged() {
        applyLaunchAtLogin(launchAtLoginSwitch.state == .on)
        syncLaunchAtLogin()
        onSettingsChanged?()
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

// MARK: - Window motion

/// A panel that fades and grows in when presented and plays the reverse when closed (every close path:
/// Cmd+W, the close button, ESC); the real close, and so `windowWillClose`, runs once it has finished.
class AnimatedPanel: NSPanel {
    private(set) var isClosing = false

    /// Shows the panel with the shared entrance; brings it forward if it's already up.
    func present() {
        guard !isClosing else { return }  // AppDelegate reopens once the close finishes
        collectionBehavior.insert(.moveToActiveSpace)  // open on the Space the user is looking at
        // Panels hide whenever Skryn isn't active; Settings and About should stay like normal windows
        hidesOnDeactivate = false
        guard !isVisible else {
            makeKeyAndOrderFront(nil)
            orderFrontRegardless()  // in front even if macOS doesn't activate Skryn
            return
        }
        HUDMotion.show(self, scale: 0.97, makeKey: true)
    }

    override func close() {
        guard !isClosing else { return }
        guard isVisible else { return super.close() }
        isClosing = true
        HUDMotion.hide(self, scale: 0.98) { [weak self] in self?.finishClose() }
    }

    private func finishClose() { super.close() }
}

/// Top-left origin: content pinned to the top stays put while the window's height changes.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Settings look

/// Metrics, colors and builders for the grouped Settings look (also used by the About panel).
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
