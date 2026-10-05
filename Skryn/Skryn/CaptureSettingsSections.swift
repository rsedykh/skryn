import AppKit
import ApplicationServices

// MARK: - Output

/// Settings → Output: a preset, or the formats and quality one by one. Rows show only where they apply.
@MainActor
final class OutputSection: NSObject {
    private let relayout: SettingsRelayout
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let presetCaption = SettingsForm.caption("")
    private let qualitySlider = NSSlider(value: 0.85, minValue: 0.1, maxValue: 1, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: "")
    private var losslessRow: SettingsRow?
    private var qualityRow: SettingsRow?
    private var videoCaptionRow: SettingsRow?

    init(relayout: @escaping SettingsRelayout) {
        self.relayout = relayout
    }

    func makeView() -> NSView {
        setupControls()
        let form = SettingsForm()
        form.addRow("Preset", presetPopup)
        form.addCaption(presetCaption)
        form.addPopup("Screenshot format", \OutputSettings.imageFormat,
                      options: ImageFormat.allCases.map { ($0, $0.title) })
        losslessRow = form.addSwitch("Lossless", \OutputSettings.imageLossless)
        // The percentage leads, so the row's label lines up with its text
        qualityRow = form.addRow("Quality", SettingsForm.hstack([qualityLabel, qualitySlider]))
        if MenuBarAction.available.contains(.record) {
            form.addPopup("Recording format", \OutputSettings.videoFormat,
                          options: VideoFormat.allCases.map { ($0, $0.title) })
            videoCaptionRow = form.addCaption(SettingsForm.caption("No sound; converted after recording"))
            form.addPopup("Frame rate", \OutputSettings.frameRate, options: FrameRate.allCases.map { ($0, $0.title) })
        }
        form.addSwitch("Retina resolution", \OutputSettings.retina)
        form.addCaption(SettingsForm.caption("Off saves at 1x: half the width and height, much smaller files"))
        form.addSwitch("Strip metadata", \OutputSettings.stripMetadata)
        sync()
        NotificationCenter.default.addObserver(self, selector: #selector(sync), name: OutputSettings.didChange, object: nil)
        return SettingsStyle.section("Output", symbol: "doc.badge.gearshape", tint: .systemOrange, form: form)
    }

    private func setupControls() {
        // Custom can't be picked: it's shown, selected, only while the settings match no preset
        presetPopup.autoenablesItems = false
        OutputSettings.Preset.allCases.forEach { presetPopup.addItem(withTitle: $0.title) }
        presetPopup.addItem(withTitle: "Custom")
        presetPopup.lastItem?.isEnabled = false
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged)
        qualitySlider.controlSize = .small
        qualitySlider.isContinuous = true
        qualitySlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)
        qualityLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        qualityLabel.textColor = .secondaryLabelColor
        qualityLabel.alignment = .right
        qualityLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true  // "100%" never nudges the slider
    }

    /// Shows the matching preset and the quality, and reveals only the rows that apply to the chosen formats.
    @objc private func sync() {
        let settings = OutputSettings.current
        let preset = settings.preset
        presetPopup.lastItem?.isHidden = preset != nil
        presetPopup.selectItem(at: preset.flatMap { OutputSettings.Preset.allCases.firstIndex(of: $0) }
            ?? presetPopup.numberOfItems - 1)
        presetCaption.stringValue = preset?.summary ?? "Your own mix of the settings below"
        if abs(qualitySlider.doubleValue - settings.imageQuality) > 0.005 {  // don't fight a drag in progress
            qualitySlider.doubleValue = settings.imageQuality
        }
        qualityLabel.stringValue = "\(Int((settings.imageQuality * 100).rounded()))%"

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
        if changed { relayout(true, nil, nil) }
    }

    @objc private func presetChanged() {
        let presets = OutputSettings.Preset.allCases
        guard presets.indices.contains(presetPopup.indexOfSelectedItem) else { return }
        var settings = OutputSettings.current
        presets[presetPopup.indexOfSelectedItem].apply(to: &settings)
        OutputSettings.current = settings
    }

    @objc private func qualityChanged() {
        var settings = OutputSettings.current
        settings.imageQuality = (qualitySlider.doubleValue * 100).rounded() / 100
        OutputSettings.current = settings
    }
}

// MARK: - Recording

/// Settings → Recording: the same switches and device choices as the area picker's bar.
@MainActor
final class RecordingSection: NSObject {
    private let relayout: SettingsRelayout
    /// "Needs Accessibility permission": revealed only while the permission is missing
    private var accessibilityRow: SettingsRow?

    init(relayout: @escaping SettingsRelayout) {
        self.relayout = relayout
    }

    func makeView() -> NSView {
        let form = SettingsForm()
        // Device menus get their own row under their switch: beside it they squeezed the title to "Re…"
        form.addSwitch("Record microphone", \RecordingOptions.microphone)
        addChoice(.microphone, "Microphone", to: form)
        form.addSwitch("Record system audio", \RecordingOptions.systemAudio)
        form.addSwitch("Show camera", \RecordingOptions.camera)
        addChoice(.camera, "Camera", to: form)
        form.addSwitch("Highlight mouse clicks", \RecordingOptions.highlightClicks)
        form.addSwitch("Show cursor", \RecordingOptions.showCursor)
        form.addSwitch("Show keystrokes", \RecordingOptions.showKeystrokes)
        let layout = addChoice(.keyboardLayout, "Key labels", to: form)
        layout.control.toolTip = "Name keys with this layout, so shortcuts read the same whatever layout you type in"
        let link = LinkButton(
            title: "Open Settings\u{2026}",
            url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
        let permission = form.addRow("Keystrokes need Accessibility permission", link)
        permission.label?.textColor = .secondaryLabelColor
        accessibilityRow = permission
        form.addSwitch("3-2-1 countdown", \RecordingOptions.countdown)
        refreshAccessibility()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshAccessibility), name: RecordingOptions.didChange, object: nil
        )
        return SettingsStyle.section("Recording", symbol: "record.circle", tint: .systemRed, form: form)
    }

    @discardableResult
    private func addChoice(_ choice: RecordingChoice, _ label: String, to form: SettingsForm) -> SettingsRow {
        let row = form.addChoice(
            label, choice.selection, defaultTitle: choice.defaultTitle, choices: { choice.choices },
            enabledBy: choice.option
        )
        // Long device names would otherwise stretch the window
        row.control.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        return row
    }

    /// Shows the permission row while Accessibility is missing (the user may grant it in System Settings
    /// while Settings is open).
    @objc func refreshAccessibility() {
        guard let accessibilityRow, accessibilityRow.isRevealed == AXIsProcessTrusted() else { return }
        accessibilityRow.isRevealed.toggle()
        relayout(true, nil, nil)
    }
}
