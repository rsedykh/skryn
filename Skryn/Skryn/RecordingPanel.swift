import AppKit
import AVKit

/// Shows a finished screen recording with the same save actions as screenshots.
/// Every way of closing it (Esc, close button, Cmd+W, Discard) goes through `close()`,
/// which asks before throwing away a recording that hasn't been saved anywhere.
@MainActor
final class RecordingPanel: NSPanel {
    private static let videoWidth: CGFloat = 640

    private let onAction: (SaveAction) -> Bool
    private let onDiscard: () -> Void
    private let playerView = AVPlayerView()
    private var player: AVPlayer?
    private var videoHeight: NSLayoutConstraint?
    /// Set once an action succeeded or the discard was confirmed; after that `close()` just closes.
    private var isFinished = false

    /// `onAction` performs the action and returns true if the panel should close (false = keep it open,
    /// e.g. cloud with no key configured). `onDiscard` is called when the user discards the recording
    /// (after confirming).
    init(videoURL: URL, onAction: @escaping (SaveAction) -> Bool, onDiscard: @escaping () -> Void) {
        self.onAction = onAction
        self.onDiscard = onDiscard
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.videoWidth, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Recording"
        isReleasedWhenClosed = false

        let player = AVPlayer(url: videoURL)
        self.player = player
        playerView.player = player
        playerView.controlsStyle = .inline

        setupLayout(aspectRatio: 9.0 / 16.0)
        centerOnMouseScreen()
        loadAspectRatio(of: videoURL)
    }

    override var canBecomeKey: Bool { true }

    // MARK: - Layout

    private func setupLayout(aspectRatio: CGFloat) {
        guard let contentView else { return }

        let discardButton = NSButton(title: "Discard", target: self, action: #selector(discardClicked))
        let actionButtons = [
            makeButton(title: "Save", action: .local),
            makeButton(title: "Copy", action: .clipboard),
            makeButton(title: "Upload", action: .cloud)
        ]
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttonRow = NSStackView(views: [discardButton, spacer] + actionButtons)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        for view in [playerView, buttonRow] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        let height = playerView.heightAnchor.constraint(equalToConstant: Self.videoWidth * aspectRatio)
        videoHeight = height
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            playerView.widthAnchor.constraint(equalToConstant: Self.videoWidth),
            height,
            buttonRow.topAnchor.constraint(equalTo: playerView.bottomAnchor, constant: 12),
            buttonRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
        contentView.layoutSubtreeIfNeeded()
    }

    private func makeButton(title: String, action: SaveAction) -> NSButton {
        let button = NSButton(
            title: "\(title)  \(action.configuredModifier.label)",
            target: self,
            action: #selector(actionClicked(_:))
        )
        button.tag = SaveAction.allCases.firstIndex(of: action) ?? 0
        return button
    }

    private func centerOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { center(); return }
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
    }

    /// Fits the preview to the video's aspect ratio; keeps 16:9 if it can't be read.
    private func loadAspectRatio(of url: URL) {
        Task { [weak self] in
            guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
                  let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
            else { return }
            let oriented = size.applying(transform)
            let width = abs(oriented.width), height = abs(oriented.height)
            guard width > 0, height > 0, let self else { return }
            let screenHeight = (screen ?? NSScreen.main)?.visibleFrame.height ?? .greatestFiniteMagnitude
            // Tall videos are capped so the panel (with its title bar and buttons) fits on screen
            videoHeight?.constant = min(Self.videoWidth * height / width, screenHeight - 140)
            contentView?.layoutSubtreeIfNeeded()
            centerOnMouseScreen()
        }
    }

    // MARK: - Actions

    @objc private func actionClicked(_ sender: NSButton) {
        perform(SaveAction.allCases[sender.tag])
    }

    @objc private func discardClicked() {
        close()
    }

    private func perform(_ action: SaveAction) {
        guard onAction(action) else { return }
        isFinished = true
        close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if attachedSheet == nil, event.keyCode == 36, let action = SaveAction.action(for: event.modifierFlags) {
            perform(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    /// The close button, Cmd+W (`AppDelegate.closeKeyWindow` calls `close()`), Esc and Discard all land here.
    override func close() {
        guard isFinished else {
            confirmDiscard()
            return
        }
        player?.pause()
        playerView.player = nil
        player = nil
        super.close()
    }

    private func confirmDiscard() {
        guard attachedSheet == nil else { return }
        player?.pause()
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
