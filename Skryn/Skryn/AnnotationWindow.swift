import AppKit

final class AnnotationWindow: NSWindow {
    init(screen: NSScreen, screenshot: NSImage) {
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
        self.contentView = AnnotationView(
            frame: NSRect(origin: .zero, size: windowRect.size),
            screenshot: screenshot
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // MARK: - Entrance and exit

    /// Set by the first `close()`: the exit is playing, input is dropped, later closes are ignored
    private(set) var isClosing = false
    private weak var backdrop: EditorBackdrop?
    private weak var editorToolbar: AnnotationToolbar?

    /// Brings the editor in as one sequence: the screen dims, the screenshot grows into place (key at
    /// once, so keys work), and the toolbar rises in just behind it. Backdrop and toolbar become child
    /// windows only once settled: a child follows its parent's frame, which is animating meanwhile.
    func present(backdrop: EditorBackdrop, toolbar: AnnotationToolbar) {
        self.backdrop = backdrop
        self.editorToolbar = toolbar
        toolbar.place(below: self)  // its final frame, from the window's final frame
        HUDMotion.show(self, scale: 0.96, makeKey: true) { [weak self, weak backdrop] in
            guard let self, let backdrop, !isClosing else { return }
            addChildWindow(backdrop, ordered: .below)
        }
        backdrop.show(below: self)
        let delay: TimeInterval = HUDMotion.reduceMotion ? 0 : 0.06
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak toolbar] in
            MainActor.assumeIsolated {
                guard let self, let toolbar, !self.isClosing else { return }
                HUDMotion.show(toolbar, travel: .up, distance: 12) { [weak self, weak toolbar] in
                    guard let self, let toolbar, !isClosing else { return }
                    addChildWindow(toolbar, ordered: .above)
                }
            }
        }
    }

    /// Every close path (Cmd+W, the toolbar's ✕, ESC, closing after Save/Copy/Upload) plays the exit:
    /// toolbar sinks, screenshot shrinks, backdrop lifts. Then the real close runs once, so
    /// `windowWillClose` fires after the animation.
    override func close() {
        guard !isClosing else { return }
        guard isVisible else { return super.close() }
        isClosing = true
        HUDHint.shared.hide()
        if let toolbar = editorToolbar {
            removeChildWindow(toolbar)
            toolbar.ignoresMouseEvents = true
            HUDMotion.hide(toolbar, travel: .up, distance: 10) {}
        }
        if let backdrop {
            removeChildWindow(backdrop)
            backdrop.hide()
        }
        HUDMotion.hide(self, scale: 0.97) { [weak self] in self?.finishClose() }
    }

    private func finishClose() { super.close() }

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
