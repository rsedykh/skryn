import AppKit
import AVFoundation

/// Round, draggable webcam window floating over the recording area. The recorder captures it by `windowID`.
@MainActor
final class WebcamBubble {
    static let diameter: CGFloat = 200
    static let largeDiameter: CGFloat = 320
    static let inset: CGFloat = 24
    /// Transparent margin around the circle so the shadow isn't clipped by the window
    static let shadowPadding: CGFloat = 20

    private let camera: CameraSession
    private let panel: NSPanel
    private let view: BubbleView

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    /// Asks for camera permission if needed, starts the camera, and shows the bubble at the bottom-right
    /// of `area` (`screen`-local points, TOP-LEFT origin, same as SCStreamConfiguration.sourceRect).
    /// Returns nil if permission is denied or no camera is available. The window is on screen when this returns.
    static func start(screen: NSScreen, area: CGRect, deviceID: String?) async -> WebcamBubble? {
        guard await cameraAccessGranted() else { return nil }
        guard let camera = await CameraSession.make(deviceID: deviceID) else { return nil }

        let globalArea = globalRect(fromTopLeft: area, screenFrame: screen.frame)
        let bubble = WebcamBubble(camera: camera, frame: initialFrame(in: globalArea))
        await camera.startAndWaitForFirstFrame(timeout: 1)
        bubble.panel.orderFrontRegardless()
        bubble.view.animateIn()
        return bubble
    }

    private init(camera: CameraSession, frame: CGRect) {
        self.camera = camera
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // the circle draws its own; a window shadow would be square
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        view = BubbleView(previewLayer: camera.makePreviewLayer(), diameter: frame.width - 2 * Self.shadowPadding)
        panel.contentView = view
        view.onDoubleClick = { [weak self] in self?.toggleSize() }
    }

    /// Shrinks and fades the bubble away, then closes it and turns the camera off.
    func stop() {
        let panel = panel, camera = camera
        view.animateOut {
            panel.orderOut(nil)
            panel.close()
            camera.stop()
        }
    }

    /// Grows or shrinks the circle around its center. The window takes the larger size for the whole
    /// animation (growing first, shrinking after), so the circle animates on the GPU instead of the window resizing.
    private func toggleSize() {
        let next = view.diameter < Self.largeDiameter ? Self.largeDiameter : Self.diameter
        let growing = next > view.diameter
        if growing { setPanelSide(next + 2 * Self.shadowPadding) }
        view.setDiameter(next) { [weak self] in
            if !growing { self?.setPanelSide(next + 2 * Self.shadowPadding) }
        }
    }

    private func setPanelSide(_ side: CGFloat) {
        let frame = panel.frame
        panel.setFrame(CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side),
                       display: true)
    }

    private static func cameraAccessGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    // MARK: - Geometry

    /// Converts a top-left-origin rect local to a screen into AppKit global (bottom-left origin) coordinates.
    static func globalRect(fromTopLeft rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.minX + rect.minX, y: screenFrame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    /// Window frame (circle plus shadow padding) placing the circle `inset` from `area`'s bottom-right corner.
    static func initialFrame(in area: CGRect) -> CGRect {
        let side = diameter + 2 * shadowPadding
        return CGRect(x: area.maxX - inset - diameter - shadowPadding,
                      y: area.minY + inset - shadowPadding,
                      width: side, height: side)
    }
}

// MARK: - View

private final class BubbleView: NSView {
    var onDoubleClick: (() -> Void)?
    private(set) var diameter: CGFloat
    /// Holds the shadow; scaled and faded for entrances, exits and the drag lift
    private let bubble = CALayer()
    private let circle = CALayer()
    private let previewLayer: CALayer

    private struct Shadow {
        let opacity: Float, radius: CGFloat, offset: CGFloat
        static let resting = Shadow(opacity: 0.32, radius: 12, offset: -4)
        static let lifted = Shadow(opacity: 0.45, radius: 22, offset: -10)
    }

    init(previewLayer: CALayer, diameter: CGFloat) {
        self.previewLayer = previewLayer
        self.diameter = diameter
        super.init(frame: .zero)
        wantsLayer = true
        bubble.shadowColor = NSColor.black.cgColor
        apply(.resting)

        circle.masksToBounds = true
        circle.backgroundColor = NSColor.black.cgColor
        circle.borderWidth = 2  // borders draw above sublayers, so this rings the video
        circle.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        circle.addSublayer(previewLayer)
        bubble.addSublayer(circle)
        layer?.addSublayer(bubble)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        // performDrag runs until the mouse is released: lift for its duration, settle on drop
        lift(true)
        window?.performDrag(with: event)
        lift(false)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bubble.frame = bounds
        place()
        CATransaction.commit()
    }

    // MARK: Motion

    /// Grows from 0.9 while fading in (a plain fade with Reduce Motion).
    func animateIn() {
        let group = CAAnimationGroup()
        group.animations = [Self.basic("opacity", from: 0, to: 1)]
        if !HUDMotion.reduceMotion { group.animations?.append(Self.basic("transform.scale", from: 0.9, to: 1)) }
        group.duration = HUDMotion.enterDuration * 1.4
        group.timingFunction = HUDMotion.enterTiming
        bubble.add(group, forKey: "enter")
    }

    /// Shrinks to 0.9 while fading out, then runs `completion`.
    func animateOut(completion: @escaping @MainActor () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(HUDMotion.exitDuration)
        CATransaction.setAnimationTimingFunction(HUDMotion.exitTiming)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        bubble.opacity = 0
        if !HUDMotion.reduceMotion { bubble.transform = CATransform3DMakeScale(0.9, 0.9, 1) }
        CATransaction.commit()
    }

    /// Animates the circle (ring, video and shadow together) to `diameter` around the window's center.
    func setDiameter(_ diameter: CGFloat, completion: @escaping @MainActor () -> Void) {
        self.diameter = diameter
        CATransaction.begin()
        CATransaction.setAnimationDuration(HUDMotion.reduceMotion ? 0 : HUDMotion.enterDuration * 1.5)
        CATransaction.setAnimationTimingFunction(HUDMotion.enterTiming)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        place()
        CATransaction.commit()
    }

    private func lift(_ lifted: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(lifted ? HUDMotion.exitDuration : HUDMotion.enterDuration * 1.4)
        CATransaction.setAnimationTimingFunction(HUDMotion.enterTiming)
        apply(lifted ? .lifted : .resting)
        if !HUDMotion.reduceMotion {
            bubble.transform = lifted ? CATransform3DMakeScale(1.03, 1.03, 1) : CATransform3DIdentity
        }
        CATransaction.commit()
    }

    /// Centers a `diameter` circle in the view (inside the current transaction, so it animates or not).
    private func place() {
        let rect = CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        circle.frame = rect
        circle.cornerRadius = diameter / 2
        previewLayer.frame = circle.bounds
        bubble.shadowPath = CGPath(ellipseIn: rect, transform: nil)
    }

    private func apply(_ shadow: Shadow) {
        bubble.shadowOpacity = shadow.opacity
        bubble.shadowRadius = shadow.radius
        bubble.shadowOffset = CGSize(width: 0, height: shadow.offset)
    }

    private static func basic(_ keyPath: String, from: Any, to: Any) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        return animation
    }
}

// MARK: - Camera

/// Owns the capture session; all session work runs on `queue`, which makes the unchecked Sendable safe.
private final class CameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.skryn.webcam")
    /// Only used to detect the first frame, then removed
    private let probe = AVCaptureVideoDataOutput()
    private var firstFrame: CheckedContinuation<Void, Never>?

    /// Uses the camera with `deviceID`, falling back to the default one; nil if there's no camera.
    static func make(deviceID: String?) async -> CameraSession? {
        let camera = CameraSession()
        let configured = await withCheckedContinuation { continuation in
            camera.queue.async { continuation.resume(returning: camera.configure(deviceID: deviceID)) }
        }
        return configured ? camera : nil
    }

    private func configure(deviceID: String?) -> Bool {
        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(probe) else { return false }
        session.addInput(input)
        probe.alwaysDiscardsLateVideoFrames = true
        probe.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(probe)
        return true
    }

    /// Call before starting the session, so the preview connection exists but frames haven't flowed yet.
    @MainActor
    func makePreviewLayer() -> CALayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        return layer
    }

    /// Starts the session and returns after the first frame arrives or `timeout` seconds pass.
    func startAndWaitForFirstFrame(timeout: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.firstFrame = continuation
                self.session.startRunning()
            }
            queue.asyncAfter(deadline: .now() + timeout) { self.finishWaiting() }
        }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        finishWaiting()
    }

    /// Runs on `queue`; resumes the waiter once and drops the probe so frames stop being copied.
    private func finishWaiting() {
        guard let continuation = firstFrame else { return }
        firstFrame = nil
        continuation.resume()
        probe.setSampleBufferDelegate(nil, queue: nil)
        queue.async {
            self.session.beginConfiguration()
            self.session.removeOutput(self.probe)
            self.session.commitConfiguration()
        }
    }
}
