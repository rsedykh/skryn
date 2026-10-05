import AppKit

/// Settings window: a column of sections (`SettingsSections.swift`, `CaptureSettingsSections.swift`,
/// `MenuBarSettingsSection`), each applying its controls as soon as they change. Grouped cards under titled
/// sections; the window resizes with an animation, its top edge fixed.
final class SettingsPanel: AnimatedPanel {
    /// The column of sections, pinned to the top: the window grows and shrinks below it
    private let sections = NSStackView()
    /// Titlebar height plus breathing room (the content runs under the transparent titlebar)
    private var topInset: CGFloat = 40

    private let shortcuts = ShortcutsSection()
    private var recording: RecordingSection?
    /// Every section's controller: they're the targets of their controls
    private var controllers: [AnyObject] = []

    var isRecordingHotkey: Bool { shortcuts.isRecording }

    /// Called when a registered global hotkey fires while a recorder is listening:
    /// the press never reaches the recorder, so keep that recorder's current shortcut.
    func confirmCurrentHotkey() {
        shortcuts.cancelRecording()
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
        setupLayout()
        relayout(animated: false)
        center()
        initialFirstResponder = contentView
    }

    override func becomeKey() {
        super.becomeKey()
        // The user may have granted Accessibility in System Settings meanwhile
        recording?.refreshAccessibility()
    }

    private func setupLayout() {
        let titlebar = frame.height - contentLayoutRect.height
        topInset = (titlebar > 0 ? titlebar : 28) + 8
        let relayout: SettingsRelayout = { [weak self] animated, alongside, completion in
            self?.relayout(animated: animated, alongside: alongside, completion: completion)
        }
        let afterCapture = AfterCaptureSection()
        let output = OutputSection(relayout: relayout)
        let upload = UploadSection(relayout: relayout)
        let menuBar = MenuBarSettingsSection()
        let general = GeneralSection()
        controllers = [afterCapture, output, upload, menuBar, general]
        var views = [shortcuts.makeView(), afterCapture.makeView(), output.makeView(), upload.makeView()]
        if MenuBarAction.available.contains(.record) {
            let recording = RecordingSection(relayout: relayout)
            self.recording = recording
            views.append(recording.makeView())
        }
        views += [menuBar.makeView(), general.makeView()]

        sections.orientation = .vertical
        sections.alignment = .leading
        sections.spacing = 24
        views.forEach { sections.addArrangedSubview($0) }
        // In a scroll view: on a short screen (a 13" laptop) the window stops at the visible height and scrolls
        let scroll = SettingsStyle.scrollingDocument(
            sections, insets: NSEdgeInsets(top: topInset, left: 0, bottom: 20, right: 0),
            width: SettingsStyle.cardWidth, adjustsInsets: false  // topInset already clears the titlebar
        )
        scroll.documentView?.wantsLayer = true
        contentView = scroll
        NSLayoutConstraint.activate(views.map { $0.widthAnchor.constraint(equalTo: sections.widthAnchor) })
    }

    /// Sizes the window to its sections, keeping the top edge put. Animated, the sections' frames move
    /// (rows sliding open or shut, a provider view crossfading in `alongside`) together with the window.
    private func relayout(animated: Bool, alongside: (() -> Void)? = nil, completion: (() -> Void)? = nil) {
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
}
