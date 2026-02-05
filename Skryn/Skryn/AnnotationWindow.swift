import AppKit

final class AnnotationWindow: NSWindow {
    init(screen: NSScreen, image: NSImage) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        self.level = .floating
        self.isOpaque = true
        self.hasShadow = false
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.contentView = AnnotationView(frame: screen.frame, image: image)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
