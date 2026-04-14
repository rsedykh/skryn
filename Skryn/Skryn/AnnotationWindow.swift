import AppKit

final class AnnotationWindow: NSWindow {
    init(screen: NSScreen, screenshot: NSImage) {
        let maxRect = screen.frame.insetBy(
            dx: screen.frame.width * 0.08,
            dy: screen.frame.height * 0.08
        )

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
            y: screen.frame.midY - windowSize.height / 2,
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
}
