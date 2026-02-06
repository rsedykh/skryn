import AppKit

final class AnnotationWindow: NSWindow {
    init(screen: NSScreen, screenshot: NSImage) {
        let inset = screen.frame.width * 0.05
        let windowRect = screen.frame.insetBy(dx: inset, dy: inset)

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
}
