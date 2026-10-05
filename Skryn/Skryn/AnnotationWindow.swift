import AppKit

/// The screenshot editor: the screenshot (`annotationView`) in a borderless window, with the dimmed
/// backdrop behind it and the toolbar under it, which it creates, shows and closes along with itself.
final class AnnotationWindow: NSWindow {
    let annotationView: AnnotationView
    private let backdrop: EditorBackdrop
    private let editorToolbar: AnnotationToolbar
    private let exit = WindowExit()
    /// The exit is playing: input is dropped, later closes are ignored
    private var isClosing: Bool { exit.isRunning }

    /// `onAction` runs Save / Copy / Upload; the editor closes when it returns true.
    init(screen: NSScreen, screenshot: NSImage, onAction: @escaping (SaveAction, RenderedScreenshot) -> Bool) {
        // Room under the image for the toolbar, which floats below the window
        let toolbarSpace = AnnotationToolbar.height + AnnotationToolbar.gap
        var maxRect = screen.frame.insetBy(
            dx: screen.frame.width * 0.08,
            dy: screen.frame.height * 0.08
        )
        maxRect.size.height -= toolbarSpace

        let imageSize = screenshot.size
        let windowSize: NSSize
        if imageSize.width <= maxRect.width && imageSize.height <= maxRect.height {
            windowSize = imageSize
        } else {
            let scale = min(maxRect.width / imageSize.width, maxRect.height / imageSize.height)
            windowSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        }

        let windowRect = NSRect(
            x: screen.frame.midX - windowSize.width / 2,
            // Center the image and toolbar together
            y: screen.frame.midY - windowSize.height / 2 + toolbarSpace / 2,
            width: windowSize.width,
            height: windowSize.height
        )

        annotationView = AnnotationView(frame: NSRect(origin: .zero, size: windowRect.size), screenshot: screenshot)
        backdrop = EditorBackdrop(screen: screen)
        editorToolbar = AnnotationToolbar(editor: annotationView)
        super.init(
            contentRect: windowRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        self.level = .normal
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.contentView = annotationView
        annotationView.showHintIfNew()
        annotationView.onAction = { [weak self] action, shot in
            if onAction(action, shot) { self?.dismiss() }  // saved: nothing to ask about
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // MARK: - Entrance and exit

    /// Brings the editor in as one sequence: the screen dims, the screenshot grows into place (key at
    /// once, so keys work), and the toolbar rises in just behind it. Backdrop and toolbar become child
    /// windows only once settled: a child follows its parent's frame, which is animating meanwhile.
    func present() {
        editorToolbar.place(below: self)  // its final frame, from the window's final frame
        HUDMotion.show(self, scale: 0.96, makeKey: true) { [weak self] in
            guard let self, !isClosing else { return }
            addChildWindow(backdrop, ordered: .below)
        }
        backdrop.show(below: self)
        let delay: TimeInterval = HUDMotion.reduceMotion ? 0 : 0.06
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isClosing else { return }
                HUDMotion.show(self.editorToolbar, travel: .up, distance: 12) { [weak self] in
                    guard let self, !isClosing else { return }
                    addChildWindow(editorToolbar, ordered: .above)
                }
            }
        }
    }

    /// ⌘W and the toolbar's ✕: asks before throwing away unsaved marks, then plays the exit.
    override func close() {
        guard !isClosing, confirmDiscard() else { return }
        dismiss()
    }

    /// True when there's nothing to lose, or the user chose Discard. Cancel is the default (Return)
    /// and Esc, so a stray key never throws the marks away.
    func confirmDiscard() -> Bool {
        let count = annotationView.unsavedMarkCount
        guard count > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard your marks?"
        alert.informativeText = count == 1 ? "1 mark will be lost." : "\(count) marks will be lost."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Every close path ends here (closing after Save/Copy/Upload directly) and plays the exit: toolbar
    /// sinks, screenshot shrinks, backdrop lifts. Then the real close runs once, so `windowWillClose`
    /// fires after the animation.
    func dismiss() {
        guard !isClosing else { return }
        HUDHint.shared.hide()
        removeChildWindow(editorToolbar)
        editorToolbar.ignoresMouseEvents = true
        if editorToolbar.isVisible { HUDMotion.hide(editorToolbar, travel: .up, distance: 10) {} }
        removeChildWindow(backdrop)
        backdrop.hide()
        exit.run(self, scale: 0.97) { [weak self] in self?.finishClose() }
    }

    private func finishClose() {
        editorToolbar.close()
        backdrop.close()
        super.close()
    }

    // No edits, saves or second closes while the editor is leaving
    override func sendEvent(_ event: NSEvent) {
        guard !isClosing else { return }
        super.sendEvent(event)
    }
}

/// Dims the screen behind the editor, so the screenshot doesn't blend into the real desktop it shows.
/// Ordered just below the editor (then attached as its child): above other apps' windows, under the
/// screenshot and toolbar. A soft vignette, a little darker at the edges, draws the eye to the center.
final class EditorBackdrop: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // Drawn by a layer: a content-less borderless window doesn't paint its background color
        let dim = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        dim.wantsLayer = true
        let vignette = CAGradientLayer()
        vignette.type = .radial
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 1.1, y: 1.1)  // just past the corners
        vignette.colors = [0.7, 0.75, 0.84].map { NSColor.black.withAlphaComponent($0).cgColor }
        vignette.locations = [0, 0.55, 1]
        vignette.frame = dim.bounds
        vignette.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        dim.layer?.addSublayer(vignette)
        contentView = dim
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        alphaValue = 0
    }

    // Clicks on the dimmed area do nothing: no stray click throws the edits away
    override var canBecomeKey: Bool { false }

    /// Orders the backdrop just below `editor` and fades it in.
    func show(below editor: NSWindow) {
        order(.below, relativeTo: editor.windowNumber)
        fade(to: 1, duration: 0.25, timing: HUDMotion.enterTiming)
    }

    /// Fades out; the owner closes it afterwards (closing mid-fade is fine).
    func hide() {
        fade(to: 0, duration: HUDMotion.exitDuration, timing: HUDMotion.exitTiming)
    }

    private func fade(to alpha: CGFloat, duration: TimeInterval, timing: CAMediaTimingFunction) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = timing
            animator().alphaValue = alpha
        }
    }
}
