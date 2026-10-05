import AppKit
import QuartzCore

/// The on-screen frame around the area being recorded, plus the pre-recording countdown.
/// Skryn excludes its own windows from capture, so none of this appears in the video.
@MainActor
final class RecordingFrame {
    private let window: RecordingFrameWindow
    private let layers: RecordingFrameLayers
    private var countdownTimer: Timer?
    /// Resumes a running `countdown()` exactly once; nil when no countdown is in progress.
    private var finishCountdown: ((Bool) -> Void)?

    /// `rect` is in `screen`-local points with a TOP-LEFT origin (same as SCStreamConfiguration.sourceRect).
    init(screen: NSScreen, rect: CGRect) {
        let screenFrame = screen.frame
        let area = Self.windowFrame(for: rect, on: screenFrame)
            .offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        window = RecordingFrameWindow(screenFrame: screenFrame)
        layers = RecordingFrameLayers(
            bounds: CGRect(origin: .zero, size: screenFrame.size), area: area, scale: screen.backingScaleFactor
        )
        window.contentView?.layer = layers.root
        window.contentView?.wantsLayer = true
        window.onEscape = { [weak self] in self?.endCountdown(false) }
    }

    /// Converts a top-left-origin, screen-local rect into AppKit global coordinates (bottom-left origin).
    static func windowFrame(for rect: CGRect, on screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.minX + rect.minX, y: screenFrame.maxY - rect.maxY,
            width: rect.width, height: rect.height
        )
    }

    /// Orders the frame in and draws the border in: it settles inward onto the area, then breathes.
    func show() {
        window.orderFrontRegardless()
        layers.animateIn()
    }

    /// Fades the frame out quickly, then closes it. Ends a running countdown as cancelled.
    func close() {
        endCountdown(false)
        window.setInteractive(false)
        let window = window
        HUDMotion.hide(window) {
            window.orderOut(nil)
            window.close()
        }
    }

    /// Shows a large 3 → 2 → 1 in the middle of the area (about 1s each, with a subtle scale/fade).
    /// Returns false if the user pressed Esc (cancel), true when it finishes.
    func countdown(from seconds: Int = 3) async -> Bool {
        guard seconds > 0, finishCountdown == nil else { return seconds <= 0 }
        var remaining = seconds
        layers.setCountdownVisible(true)
        layers.showDigit(remaining)
        window.setInteractive(true)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)

        let finished = await withCheckedContinuation { continuation in
            finishCountdown = { continuation.resume(returning: $0) }
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    remaining -= 1
                    if remaining > 0 {
                        self.layers.showDigit(remaining)
                    } else {
                        self.endCountdown(true)
                    }
                }
            }
        }

        layers.setCountdownVisible(false)
        let wasKey = window.isKeyWindow
        window.setInteractive(false)
        // Hand focus back to whatever the user was working in, so recording doesn't steal it.
        if finished && wasKey { NSApp.deactivate() }
        return finished
    }

    /// Resumes the pending countdown (if any) exactly once.
    private func endCountdown(_ finished: Bool) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        let finish = finishCountdown
        finishCountdown = nil
        finish?(finished)
    }
}

// MARK: - Window

private final class RecordingFrameWindow: NSWindow {
    var onEscape: (() -> Void)?
    private var acceptsKey = false

    init(screenFrame: CGRect) {
        super.init(contentRect: screenFrame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screenFrame, display: false)
        // Above normal windows, below menus, alerts and modal panels.
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { acceptsKey }

    /// Interactive during the countdown (key, swallows clicks), click-through otherwise.
    func setInteractive(_ interactive: Bool) {
        acceptsKey = interactive
        ignoresMouseEvents = !interactive
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

// MARK: - Layers

/// Layer tree for the frame window (layer-hosting, bottom-left origin, in window points).
@MainActor
private final class RecordingFrameLayers {
    private static let borderWidth: CGFloat = 2
    private static let haloWidth: CGFloat = 4
    private static let circleSize: CGFloat = 184
    private static let ringInset: CGFloat = 7
    private static let ringWidth: CGFloat = 3
    /// How far outside the area the border starts before settling onto it
    private static let settleDistance: CGFloat = 10
    private static let digitFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 104, weight: .bold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 104) } ?? base
    }()

    let root = CALayer()
    private let bounds: CGRect
    private let area: CGRect
    private let scale: CGFloat
    private let dim = CAShapeLayer()
    private let halo: CAShapeLayer
    private let border: CAShapeLayer
    private let countdown = CALayer()
    private let ring = CAShapeLayer()
    private var digit: CATextLayer?

    init(bounds: CGRect, area: CGRect, scale: CGFloat) {
        self.bounds = bounds
        self.area = area
        self.scale = scale
        let path = Self.borderPath(bounds: bounds, area: area, outset: 0)
        // A dark halo under the red line keeps the border readable on light and dark content alike.
        halo = Self.stroke(path, color: NSColor.black.withAlphaComponent(0.35), width: Self.haloWidth)
        border = Self.stroke(path, color: NSColor.systemRed.withAlphaComponent(0.9), width: Self.borderWidth)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds

        dim.path = Self.dimPath(bounds: bounds, area: area)
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.35).cgColor
        dim.opacity = 0
        root.addSublayer(dim)
        root.addSublayer(halo)
        root.addSublayer(border)

        setUpCountdown(center: CGPoint(x: area.midX, y: area.midY))
        CATransaction.commit()
    }

    // MARK: Frame

    /// The border fades in while settling from slightly outside the area onto it, then starts breathing.
    func animateIn() {
        let reduce = HUDMotion.reduceMotion
        let from = Self.borderPath(bounds: bounds, area: area, outset: reduce ? 0 : Self.settleDistance)
        let duration = HUDMotion.enterDuration * 1.6
        for layer in [halo, border] {
            let settle = CABasicAnimation(keyPath: "path")
            settle.fromValue = from
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            let group = CAAnimationGroup()
            group.animations = [settle, fade]
            group.duration = duration
            group.timingFunction = HUDMotion.enterTiming
            layer.add(group, forKey: "enter")
        }
        guard !reduce else { return }
        // A calm 2s pulse of the red line: present, never distracting
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = 0.55
        breathe.duration = 1
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.beginTime = CACurrentMediaTime() + duration
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        border.add(breathe, forKey: "breathe")
    }

    // MARK: Countdown

    /// Fades the dim and the countdown circle in (growing from 0.92) or out (shrinking to 0.94).
    func setCountdownVisible(_ visible: Bool) {
        let duration = visible ? HUDMotion.enterDuration * 1.4 : HUDMotion.exitDuration * 1.4
        let timing = visible ? HUDMotion.enterTiming : HUDMotion.exitTiming
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(timing)
        dim.opacity = visible ? 1 : 0
        countdown.opacity = visible ? 1 : 0
        CATransaction.commit()
        guard !HUDMotion.reduceMotion else { return }
        let grow = visible ? Self.basic("transform.scale", from: 0.92, to: 1) : Self.basic("transform.scale", from: 1, to: 0.94)
        grow.duration = duration
        grow.timingFunction = timing
        countdown.add(grow, forKey: "visibility")
    }

    /// Swaps in the digit: the new one scales down from 1.25 while fading in, the old one shrinks away,
    /// and the ring sweeps once around the circle over the coming second.
    func showDigit(_ number: Int) {
        let reduce = HUDMotion.reduceMotion
        if let old = digit {
            CATransaction.begin()
            CATransaction.setAnimationDuration(HUDMotion.exitDuration)
            CATransaction.setAnimationTimingFunction(HUDMotion.exitTiming)
            CATransaction.setCompletionBlock { old.removeFromSuperlayer() }
            old.opacity = 0
            if !reduce { old.transform = CATransform3DMakeScale(0.8, 0.8, 1) }
            CATransaction.commit()
        }
        let next = makeDigit(number)
        countdown.addSublayer(next)
        digit = next

        let pop = CAAnimationGroup()
        pop.animations = [Self.basic("opacity", from: 0, to: 1)]
        if !reduce { pop.animations?.append(Self.basic("transform.scale", from: 1.25, to: 1)) }
        pop.duration = HUDMotion.enterDuration * 1.6
        pop.timingFunction = HUDMotion.enterTiming
        next.add(pop, forKey: "enter")

        let sweep = Self.basic("strokeEnd", from: 0, to: 1)
        sweep.duration = 1
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        ring.add(sweep, forKey: "sweep")
    }

    private func setUpCountdown(center: CGPoint) {
        let size = Self.circleSize
        countdown.frame = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        HUDStyle.paintSurface(countdown, radius: size / 2)
        countdown.opacity = 0
        root.addSublayer(countdown)

        // A faint track with the progress ring on top, starting at 12 o'clock and going clockwise
        let radius = size / 2 - Self.ringInset
        let circle = CGMutablePath()
        circle.addArc(center: CGPoint(x: size / 2, y: size / 2), radius: radius,
                      startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        let track = Self.stroke(circle, color: NSColor.white.withAlphaComponent(0.1), width: Self.ringWidth)
        countdown.addSublayer(track)
        ring.path = circle
        ring.fillColor = nil
        ring.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        ring.lineWidth = Self.ringWidth
        ring.lineCap = .round
        countdown.addSublayer(ring)

        let caption = CATextLayer()
        let captionFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        caption.string = "Esc to cancel"
        caption.font = captionFont
        caption.fontSize = captionFont.pointSize
        caption.foregroundColor = HUDStyle.dimmed.withAlphaComponent(0.5).cgColor
        caption.alignmentMode = .center
        caption.contentsScale = scale
        caption.frame = CGRect(x: 0, y: 34, width: size, height: ceil(captionFont.ascender - captionFont.descender))
        countdown.addSublayer(caption)
    }

    /// CATextLayer draws from its top edge; place it so the numerals' cap height sits a bit above center,
    /// leaving room for the caption below.
    private func makeDigit(_ number: Int) -> CATextLayer {
        let size = Self.circleSize
        let font = Self.digitFont
        let lineHeight = ceil(font.ascender - font.descender)
        let baseline = size / 2 - font.capHeight / 2 + 8
        let layer = CATextLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = CGRect(x: 0, y: baseline + font.ascender - lineHeight, width: size, height: lineHeight)
        layer.string = "\(number)"
        layer.font = font
        layer.fontSize = font.pointSize
        layer.foregroundColor = NSColor.white.cgColor
        layer.alignmentMode = .center
        layer.contentsScale = scale
        CATransaction.commit()
        return layer
    }

    // MARK: Helpers

    private static func basic(_ keyPath: String, from: Any, to: Any) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        return animation
    }

    private static func stroke(_ path: CGPath, color: NSColor, width: CGFloat) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = path
        layer.fillColor = nil
        layer.strokeColor = color.cgColor
        layer.lineWidth = width
        return layer
    }

    /// The border hugs the area from outside (`outset` further out while it settles), but is pushed inside
    /// the screen where the area touches its edges (e.g. a full-screen recording), so it's always fully visible.
    private static func borderPath(bounds: CGRect, area: CGRect, outset: CGFloat) -> CGPath {
        let inset = -borderWidth / 2 - outset
        let outside = area.insetBy(dx: inset, dy: inset)
        let rect = outside.intersection(bounds.insetBy(dx: haloWidth / 2, dy: haloWidth / 2))
        return CGPath(rect: rect.isNull ? area : rect, transform: nil)
    }

    private static func dimPath(bounds: CGRect, area: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(area)
        return path
    }
}

/// Everything shown on screen around a recording: the frame (never captured) and, when switched on,
/// the keystroke HUD and camera bubble (captured by window ID). They must be on screen before the
/// recorder lists windows, so they're shown before it starts.
@MainActor
struct RecordingOverlays {
    let frame: RecordingFrame
    let keystrokes: KeystrokeOverlay?
    let camera: WebcamBubble?
    /// Things the user should know (missing permissions), shown when recording starts
    var notices: [String]

    var capturedWindowIDs: [CGWindowID] { [keystrokes?.windowID, camera?.windowID].compactMap { $0 } }

    static func show(screen: NSScreen, area: CGRect, options: RecordingOptions) async -> RecordingOverlays {
        let frame = RecordingFrame(screen: screen, rect: area)
        frame.show()
        var notices: [String] = []
        let keystrokes = options.showKeystrokes
            ? KeystrokeOverlay.start(screen: screen, area: area, layoutID: options.keystrokeLayoutID) : nil
        if options.showKeystrokes && keystrokes == nil {
            notices.append("Keystrokes need Accessibility permission — allow Skryn, then record again")
        }
        let camera = options.camera
            ? await WebcamBubble.start(screen: screen, area: area, deviceID: options.cameraDeviceID) : nil
        if options.camera && camera == nil {
            notices.append("Camera unavailable — check Camera permission for Skryn")
        }
        return RecordingOverlays(frame: frame, keystrokes: keystrokes, camera: camera, notices: notices)
    }

    func tearDown() {
        frame.close()
        keystrokes?.stop()
        camera?.stop()
    }
}
