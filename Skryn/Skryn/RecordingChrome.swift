import AppKit
import QuartzCore

/// The on-screen frame around the area being recorded, plus the pre-recording countdown.
/// Skryn excludes its own windows from capture, so none of this appears in the video.
@MainActor
final class RecordingFrame {
    private let window: RecordingFrameWindow
    private let layers: RecordingFrameLayers
    /// The running `countdown()`; cancelling it (Esc, `close()`) ends the countdown as cancelled.
    private var countdownTask: Task<Void, Error>?

    init(area: CaptureArea) {
        let screenFrame = area.screen.frame
        window = RecordingFrameWindow(screenFrame: screenFrame)
        layers = RecordingFrameLayers(
            bounds: CGRect(origin: .zero, size: screenFrame.size),
            area: area.globalFrame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY),
            scale: area.screen.backingScaleFactor
        )
        window.contentView?.layer = layers.root
        window.contentView?.wantsLayer = true
        window.onEscape = { [weak self] in self?.countdownTask?.cancel() }
    }

    /// Orders the frame in and draws the border in: it settles inward onto the area, then breathes.
    func show() {
        window.orderFrontRegardless()
        layers.animateIn()
    }

    /// Fades the frame out quickly, then closes it. Ends a running countdown as cancelled.
    func close() {
        countdownTask?.cancel()
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
        guard seconds > 0, countdownTask == nil else { return seconds <= 0 }
        layers.setCountdownVisible(true)
        window.setInteractive(true)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)

        let layers = layers
        let task = Task {
            for remaining in stride(from: seconds, to: 0, by: -1) {
                layers.showDigit(remaining)
                try await Task.sleep(for: .seconds(1))
            }
        }
        countdownTask = task
        let finished = (try? await task.value) != nil
        countdownTask = nil

        layers.setCountdownVisible(false)
        let wasKey = window.isKeyWindow
        window.setInteractive(false)
        // Hand focus back to whatever the user was working in, so recording doesn't steal it.
        if finished && wasKey { NSApp.deactivate() }
        return finished
    }
}

// MARK: - Window

private final class RecordingFrameWindow: OverlayPanel {
    private var acceptsKey = false

    init(screenFrame: CGRect) {
        // Above normal windows, below menus, alerts and modal panels.
        super.init(frame: screenFrame, level: .floating, behavior: [.stationary, .ignoresCycle])
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { acceptsKey }

    /// Interactive during the countdown (key, swallows clicks), click-through otherwise.
    func setInteractive(_ interactive: Bool) {
        acceptsKey = interactive
        ignoresMouseEvents = !interactive
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
        let grow = CABasicAnimation(keyPath: "transform.scale", from: visible ? 0.92 : 1, to: visible ? 1 : 0.94)
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
        pop.animations = [CABasicAnimation(keyPath: "opacity", from: 0, to: 1)]
        if !reduce { pop.animations?.append(CABasicAnimation(keyPath: "transform.scale", from: 1.25, to: 1)) }
        pop.duration = HUDMotion.enterDuration * 1.6
        pop.timingFunction = HUDMotion.enterTiming
        next.add(pop, forKey: "enter")

        let sweep = CABasicAnimation(keyPath: "strokeEnd", from: 0, to: 1)
        sweep.duration = 1
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        ring.add(sweep, forKey: "sweep")
    }

    private func setUpCountdown(center: CGPoint) {
        let size = Self.circleSize
        // Whole points, so the caption's small text lands on the pixel grid instead of smearing across it
        countdown.frame = CGRect(x: round(center.x - size / 2), y: round(center.y - size / 2), width: size, height: size)
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
        caption.foregroundColor = HUDStyle.dimmed.cgColor
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
