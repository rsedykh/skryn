import AppKit
import AVKit

/// Shows a finished screen recording with the same save actions as screenshots, plus trimming.
/// One dark object: a black video stage running under the transparent titlebar, and the HUD action
/// bar (the screenshot toolbar's look) below it. Every way of closing it (Esc, close button, Cmd+W,
/// Discard) goes through `close()`, which asks before throwing away a recording that hasn't been
/// saved anywhere. Show it with `present()`, not `makeKeyAndOrderFront`.
@MainActor
final class RecordingPanel: NSPanel {
    /// Preview size bounds: at least this wide on open, at most this share of the screen
    private static let minVideoWidth: CGFloat = 640
    private static let maxScreenShare: CGFloat = 0.8
    /// Gap around the action bar
    private static let barInset: CGFloat = 8
    /// Everything under the video: the action bar and its insets
    private static let chromeHeight: CGFloat = HUDStyle.barHeight + 2 * barInset
    private static let stageRadius: CGFloat = 12
    /// The window grows from / shrinks to this scale as it opens and closes
    private static let motionScale: CGFloat = 0.96

    private let onAction: (SaveAction, URL) -> Bool
    private let onDiscard: () -> Void
    private let player: AVPlayer
    private let stage = NSView()
    private let playerView = AVPlayerView()
    private let playOverlay = NSButton()
    private let infoLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    /// Return without modifiers triggers this one (the emphasized button).
    private let defaultAction: SaveAction = UploadProviders.current.setupProblem == nil ? .cloud : .local
    private var actionButtons: [HUDButton] = []
    private var trimButton: HUDButton?
    private var playbackObservation: NSKeyValueObservation?
    /// The file the actions act on: the original, or the latest trimmed copy.
    private var currentURL: URL
    /// Trimmed copies this panel made; deleted on close. The caller owns the original.
    private var trimmedFiles: [URL] = []
    /// Set once an action succeeded or the discard was confirmed; after that `close()` just closes.
    private var isFinished = false
    /// The exit animation is running; input is ignored.
    private(set) var isClosing = false
    /// `present()` was called; the panel shows once it has been fitted to the video.
    private var wantsPresent = false
    private var isFitted = false
    /// Trimming or exporting: action buttons and Return shortcuts are off.
    private var isBusy = false {
        didSet { (actionButtons + [trimButton].compactMap { $0 }).forEach { $0.isEnabled = !isBusy } }
    }

    /// `onAction` performs the action on the given file (the original or a trimmed copy) and returns true
    /// if the panel should close (false = keep it open, e.g. cloud with no key configured). `onDiscard` is
    /// called when the user discards the recording (after confirming).
    init(videoURL: URL, onAction: @escaping (SaveAction, URL) -> Bool, onDiscard: @escaping () -> Void) {
        self.onAction = onAction
        self.onDiscard = onDiscard
        currentURL = videoURL
        player = AVPlayer(url: videoURL)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 450 + Self.chromeHeight),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Recording"  // hidden, but named in the Window menu and to VoiceOver
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = HUDStyle.surfaceOpaque
        isReleasedWhenClosed = false

        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.setAccessibilityLabel("Recording preview")
        setupPlayOverlay()

        setupLayout()
        contentMinSize = NSSize(width: 640, height: 300 + Self.chromeHeight)
        initialFirstResponder = playerView  // so Space plays/pauses right away
        centerOnMouseScreen()
        loadInfo(fitPanel: true)
    }

    override var canBecomeKey: Bool { true }

    /// Shows the panel growing in from slightly smaller, once it has been sized to the video
    /// (so it doesn't jump mid-animation). Makes it key.
    func present() {
        wantsPresent = true
        guard isFitted, !isVisible else { return }
        HUDMotion.show(self, scale: Self.motionScale, makeKey: true)
    }

    // MARK: - Layout

    private func setupLayout() {
        guard let contentView else { return }
        // The stage: black, running under the transparent titlebar, rounded where it meets the bar
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor.black.cgColor
        stage.layer?.cornerRadius = Self.stageRadius
        stage.layer?.cornerCurve = .continuous
        stage.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]  // bottom (unflipped layer)
        stage.layer?.masksToBounds = true
        let bar = makeBar()

        for (view, parent) in [(stage, contentView), (bar, contentView), (playerView, stage), (playOverlay, stage)] {
            view.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(view)
        }
        let inset = Self.barInset
        // The video takes whatever the window gives it; the user can resize the window
        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: contentView.topAnchor),
            stage.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: stage.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            playOverlay.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            playOverlay.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            bar.topAnchor.constraint(equalTo: stage.bottomAnchor, constant: inset),
            bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
            bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
            bar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -inset),
        ])
        contentView.layoutSubtreeIfNeeded()
    }

    /// Discard | Trim | 0:12 · 4.3 MB · 1920×1080 (spinner) — spacer — Save Copy Upload
    private func makeBar() -> HUDBar {
        let discard = makeButton("Discard", symbol: "trash", hint: "Discard \u{2014} Esc") { $0.close() }
        let trim = makeButton("Trim", symbol: "scissors", hint: "Cut the start or end") { $0.trimClicked() }
        trim.showsTitle = true
        trimButton = trim
        actionButtons = SaveAction.allCases.map { action in
            let (title, symbol) = Self.titleAndSymbol(of: action)
            let shortcut = action.configuredModifier.label
            let keys = action == defaultAction ? "\u{23CE} or \(shortcut)" : shortcut
            let button = makeButton(title, symbol: symbol, hint: "\(title) \u{2014} \(keys)") { $0.perform(action) }
            button.showsTitle = true
            button.isEmphasized = action == defaultAction
            return button
        }

        infoLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        infoLabel.lineBreakMode = .byTruncatingTail
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        infoLabel.alphaValue = 0  // fades in once the file has been read
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.alphaValue = 0  // faded rather than hidden, so the bar's layout never shifts

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return HUDBar(views: [discard, HUDDivider(), trim, HUDDivider(), infoLabel, spinner, spacer] + actionButtons)
    }

    private func makeButton(
        _ title: String, symbol: String, hint: String, handler: @escaping (RecordingPanel) -> Void
    ) -> HUDButton {
        let button = HUDButton(title: title, symbol: symbol)
        button.hint = hint
        button.handler = { [weak self] in
            guard let self else { return }
            handler(self)
        }
        return button
    }

    private static func titleAndSymbol(of action: SaveAction) -> (String, String) {
        switch action {
        case .local: ("Save", "square.and.arrow.down")
        case .clipboard: ("Copy", "doc.on.doc")
        case .cloud: ("Upload", "icloud.and.arrow.up")
        }
    }

    /// A round HUD play button over the poster frame, so the preview reads as a video, not a live window.
    /// It fades away once playback starts.
    private func setupPlayOverlay() {
        let size: CGFloat = 64
        playOverlay.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .semibold))
        playOverlay.contentTintColor = .white
        playOverlay.isBordered = false
        playOverlay.imagePosition = .imageOnly
        playOverlay.wantsLayer = true
        HUDStyle.paintSurface(playOverlay.layer, radius: size / 2)
        playOverlay.widthAnchor.constraint(equalToConstant: size).isActive = true
        playOverlay.heightAnchor.constraint(equalToConstant: size).isActive = true
        playOverlay.target = self
        playOverlay.action = #selector(playClicked)
        playOverlay.setAccessibilityLabel("Play")
        playbackObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            guard player.timeControlStatus != .paused else { return }
            DispatchQueue.main.async {
                guard let self, !self.playOverlay.isHidden else { return }
                HUDMotion.fade(self.playOverlay, visible: false)
            }
        }
    }

    private func centerOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { center(); return }
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
    }

    /// Animates `changes` (made through `animator()`), then runs `completion`.
    private static func animate(
        _ duration: TimeInterval, _ changes: () -> Void, completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = HUDMotion.enterTiming
            changes()
        }, completionHandler: { MainActor.assumeIsolated { completion?() } })
    }

    // MARK: - Video info

    /// Fills the info line for `currentURL`; on first load also fits the preview to the video's aspect ratio
    /// (keeps 16:9 if it can't be read) and shows the panel if `present()` is waiting for that.
    private func loadInfo(fitPanel: Bool) {
        let url = currentURL
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let duration = try? await asset.load(.duration)
            var pixelSize: CGSize?
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let oriented = size.applying(transform)
                pixelSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            }
            let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let self, url == currentURL else { return }
            showInfo(Self.infoText(duration: duration, bytes: bytes, pixelSize: pixelSize))
            guard fitPanel else { return }
            if let pixelSize { fit(to: pixelSize) }
            isFitted = true
            if wantsPresent { present() }
        }
    }

    /// Crossfades the info line to `text`: the old one fades out, the new one fades in.
    private func showInfo(_ text: String) {
        guard infoLabel.stringValue != text || infoLabel.alphaValue < 1 else { return }
        guard !infoLabel.stringValue.isEmpty, isVisible else {
            infoLabel.stringValue = text
            Self.animate(HUDMotion.enterDuration) { infoLabel.animator().alphaValue = 1 }
            return
        }
        Self.animate(HUDMotion.exitDuration, { infoLabel.animator().alphaValue = 0 }, completion: { [self] in
            infoLabel.stringValue = text
            Self.animate(HUDMotion.enterDuration) { infoLabel.animator().alphaValue = 1 }
        })
    }

    /// "0:12 · 4.3 MB · 1920×1080"; parts that couldn't be read are left out.
    static func infoText(duration: CMTime?, bytes: Int?, pixelSize: CGSize?) -> String {
        var parts: [String] = []
        if let seconds = duration?.seconds, seconds.isFinite {
            let total = Int(seconds.rounded())
            parts.append(String(format: "%d:%02d", total / 60, total % 60))
        }
        if let bytes { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
        if let size = pixelSize { parts.append("\(Int(size.width))\u{00D7}\(Int(size.height))") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Opens at the video's actual size where it fits: at least `minVideoWidth` wide, at most
    /// `maxScreenShare` of the screen, keeping the aspect ratio.
    private func fit(to pixelSize: CGSize) {
        guard let screen = screen ?? NSScreen.main else { return }
        let size = Self.previewSize(
            pixelSize: pixelSize, backingScale: screen.backingScaleFactor,
            available: NSSize(
                width: screen.visibleFrame.width * Self.maxScreenShare,
                height: screen.visibleFrame.height * Self.maxScreenShare - Self.chromeHeight
            )
        )
        guard let size else { return }
        setContentSize(NSSize(width: size.width, height: size.height + Self.chromeHeight))
        centerOnMouseScreen()
    }

    static func previewSize(pixelSize: CGSize, backingScale: CGFloat, available: CGSize) -> CGSize? {
        guard pixelSize.width > 0, pixelSize.height > 0, available.width > 0, available.height > 0 else { return nil }
        let points = CGSize(width: pixelSize.width / max(backingScale, 1), height: pixelSize.height / max(backingScale, 1))
        var width = min(max(points.width, minVideoWidth), available.width)
        var height = width * points.height / points.width
        if height > available.height {
            height = available.height
            width = height * points.width / points.height
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    // MARK: - Trim

    private func trimClicked() {
        guard !isBusy, !isClosing, playerView.canBeginTrimming else { NSSound.beep(); return }
        isBusy = true
        HUDMotion.fade(playOverlay, visible: false)  // the trim UI takes over the stage
        playerView.beginTrimming { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if result == .okButton {
                    self.exportTrimmedRange()
                } else {
                    self.isBusy = false
                }
                self.makeFirstResponder(self.playerView)
            }
        }
    }

    /// Writes the range picked in the trim UI to a new temp file and swaps the preview to it.
    private func exportTrimmedRange() {
        guard let item = player.currentItem else { isBusy = false; return }
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let range = item.forwardPlaybackEndTime.isValid
            ? CMTimeRange(start: start, end: item.forwardPlaybackEndTime)
            : CMTimeRange(start: start, duration: .positiveInfinity)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("skryn-\(UUID().uuidString).mp4")
        let asset = item.asset
        setExporting(true)
        Task { [weak self] in
            do {
                try await Self.export(asset, range: range, to: output)
                guard let self, isVisible, !isClosing else { try? FileManager.default.removeItem(at: output); return }
                didExport(to: output)
            } catch {
                try? FileManager.default.removeItem(at: output)
                self?.exportFailed(error)
            }
        }
    }

    private static func export(_ asset: AVAsset, range: CMTimeRange, to url: URL) async throws {
        // ponytail: recording itself needs macOS 15, so there's no pre-15 export path
        guard #available(macOS 15, *),
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
        else { throw CocoaError(.featureUnsupported) }
        session.timeRange = range
        try await session.export(to: url, as: .mp4)
    }

    /// While exporting the spinner fades in and the info line dims; both settle back afterwards
    /// (a new info line crossfades in on its own after a successful trim).
    private func setExporting(_ exporting: Bool) {
        if exporting { spinner.startAnimation(nil) }
        Self.animate(exporting ? HUDMotion.enterDuration : HUDMotion.exitDuration, { [self] in
            spinner.animator().alphaValue = exporting ? 1 : 0
            infoLabel.animator().alphaValue = exporting ? 0.4 : 1
        }, completion: { [self] in
            if spinner.alphaValue == 0 { spinner.stopAnimation(nil) }
        })
    }

    private func didExport(to url: URL) {
        setExporting(false)
        trimmedFiles.append(url)
        currentURL = url
        swapVideo(to: url)
        isBusy = false
        loadInfo(fitPanel: false)
    }

    /// Dips the stage through black to the trimmed video, and brings the play button back for it.
    private func swapVideo(to url: URL) {
        let item = AVPlayerItem(url: url)
        Self.animate(HUDMotion.exitDuration, { playerView.animator().alphaValue = 0 }, completion: { [self] in
            player.replaceCurrentItem(with: item)
            Self.animate(HUDMotion.enterDuration * 1.5) { playerView.animator().alphaValue = 1 }
            HUDMotion.fade(playOverlay, visible: true)
        })
    }

    private func exportFailed(_ error: Error) {
        setExporting(false)
        // Undo the trim marks so the preview matches the file the actions will use
        player.currentItem?.reversePlaybackEndTime = .invalid
        player.currentItem?.forwardPlaybackEndTime = .invalid
        isBusy = false
        guard isVisible, !isClosing else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't trim the recording"
        alert.informativeText = "\(error.localizedDescription)\nThe untrimmed recording is kept."
        alert.alertStyle = .warning
        alert.beginSheetModal(for: self)
    }

    // MARK: - Actions

    @objc private func playClicked() {
        player.play()
        makeFirstResponder(playerView)
    }

    private func perform(_ action: SaveAction) {
        guard !isBusy, !isClosing, onAction(action, currentURL) else { return }
        isFinished = true
        close()
    }

    /// Modifier+Return runs the action configured for that modifier; plain Return runs the default action.
    /// Off while trimming, so Return reaches the trim controls.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if attachedSheet == nil, !isBusy, !isClosing, event.keyCode == 36 {
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if let action = modifiers.isEmpty ? defaultAction : SaveAction.action(for: event.modifierFlags) {
                perform(action)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    /// The close button, Cmd+W (`AppDelegate.closeKeyWindow` calls `close()`), Esc and Discard all land here.
    /// Once finished, the panel shrinks and fades out, then really closes.
    override func close() {
        guard isFinished else {
            confirmDiscard()
            return
        }
        guard !isClosing else { return }
        isClosing = true
        ignoresMouseEvents = true
        player.pause()
        HUDHint.shared.hide()
        guard isVisible else { finishClose(); return }
        HUDMotion.hide(self, scale: Self.motionScale) { [self] in finishClose() }
    }

    private func finishClose() {
        playbackObservation = nil
        playerView.player = nil
        player.replaceCurrentItem(with: nil)
        trimmedFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        trimmedFiles = []
        super.close()
    }

    private func confirmDiscard() {
        guard attachedSheet == nil, !isClosing else { return }
        player.pause()
        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.informativeText = "It hasn't been saved, copied, or uploaded, and can't be recovered."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: self) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            isFinished = true
            onDiscard()
            close()
        }
    }
}
