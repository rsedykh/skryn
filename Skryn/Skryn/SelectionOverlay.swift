import AppKit
import AVFoundation

@MainActor
enum SelectionOverlay {
    enum Purpose {
        case recording, screenshot

        var hint: String {
            let fullScreen = self == .recording ? "record" : "capture"
            return "Drag to select an area \u{00B7} Click to \(fullScreen) the full screen \u{00B7} Esc to cancel"
        }
    }

    /// Drags smaller than this (in either dimension) select the whole screen.
    static let minSelectionSize: CGFloat = 8

    /// Shows a dimmed, borderless overlay over `screen` and lets the user drag a rectangle.
    /// Returns the selection in the screen's local points with a TOP-LEFT origin (the coordinate space of
    /// SCStreamConfiguration.sourceRect), or nil if the user pressed Esc.
    /// A click without dragging (or a drag smaller than ~8pt) selects the whole screen.
    /// The recording switch bar shows only when picking an area to record.
    /// Returns once the overlay has faded out and left the screen, so a capture never includes it.
    static func pickArea(on screen: NSScreen, for purpose: Purpose = .recording) async -> CGRect? {
        let window = SelectionOverlayWindow(screen: screen, purpose: purpose)
        // Losing key status (Cmd+Tab, a click on another display) cancels, since Esc can't reach us anymore
        let resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { window.selectionView.finish(nil) }
        }
        let result: CGRect? = await withCheckedContinuation { continuation in
            window.selectionView.onFinish = { continuation.resume(returning: $0) }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(window.selectionView)
            window.selectionView.animateIn()
        }
        NotificationCenter.default.removeObserver(resignObserver)
        window.orderOut(nil)
        window.close()
        return result
    }

    /// Converts two drag points in view coordinates (bottom-left origin) into a top-left-origin rect,
    /// clamped to the screen and rounded to integral points. Returns the full screen for tiny drags.
    static func selectionRect(from start: NSPoint, to end: NSPoint, in screenSize: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: screenSize)
        let viewRect = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        ).intersection(bounds)
        guard !viewRect.isNull,
              viewRect.width >= minSelectionSize, viewRect.height >= minSelectionSize else { return bounds }
        let flipped = CGRect(
            x: viewRect.minX, y: screenSize.height - viewRect.maxY,
            width: viewRect.width, height: viewRect.height
        )
        return flipped.integral.intersection(bounds)
    }
}

private final class SelectionOverlayWindow: NSWindow {
    let selectionView: SelectionView

    init(screen: NSScreen, purpose: SelectionOverlay.Purpose) {
        // The options bar sits above the Dock, like the ⇧⌘5 bar
        let barInset = max(screen.visibleFrame.minY - screen.frame.minY, 0) + 32
        selectionView = SelectionView(
            frame: NSRect(origin: .zero, size: screen.frame.size), barBottomInset: barInset, purpose: purpose
        )
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        // Above the menu bar and Dock, but below pop-up menus so the device menus aren't hidden behind us
        self.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onFinish: (@MainActor @Sendable (CGRect?) -> Void)?
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var isFinishing = false
    private var showsSize = false
    private let shade = SelectionShade()
    private let hint: HintPill
    private let sizePill = SizePill()
    private let optionsBar: RecordingOptionsBar?
    private let barBottomInset: CGFloat
    private var hintCenterY: NSLayoutConstraint?
    private var barBottom: NSLayoutConstraint?

    /// How far the hint and the switch bar travel while they appear
    private static let hintRise: CGFloat = 6
    private static let barRise: CGFloat = 12

    init(frame: NSRect, barBottomInset: CGFloat, purpose: SelectionOverlay.Purpose) {
        hint = HintPill(text: purpose.hint)
        optionsBar = purpose == .recording ? RecordingOptionsBar() : nil
        self.barBottomInset = barBottomInset
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self, userInfo: nil
        ))
        shade.frame = bounds
        shade.autoresizingMask = [.width, .height]
        addSubview(shade)
        addSubview(sizePill)
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        let hintCenterY = hint.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([hint.centerXAnchor.constraint(equalTo: centerXAnchor), hintCenterY])
        self.hintCenterY = hintCenterY
        guard let optionsBar else { return }
        optionsBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(optionsBar)
        let barBottom = optionsBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -barBottomInset)
        NSLayoutConstraint.activate([optionsBar.centerXAnchor.constraint(equalTo: centerXAnchor), barBottom])
        self.barBottom = barBottom
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    // MARK: - Motion

    /// The dim fades in, then the hint rises into place and the switch bar rises in from below.
    func animateIn() {
        let travel = !HUDMotion.reduceMotion
        hint.alphaValue = 0
        hintCenterY?.constant = travel ? Self.hintRise : 0
        optionsBar?.alphaValue = 0
        barBottom?.constant = -barBottomInset + (travel ? Self.barRise : 0)
        layoutSubtreeIfNeeded()
        shade.alphaValue = 0
        HUDMotion.fade(shade, visible: true)
        afterDelay(0.05) { view in
            guard view.dragStart == nil else { return }  // the drag already started: the hint stays away
            view.hint.animator().alphaValue = 1
            view.hintCenterY?.animator().constant = 0
        }
        afterDelay(0.08) { view in
            view.optionsBar?.animator().alphaValue = 1
            view.barBottom?.animator().constant = -view.barBottomInset
        }
    }

    /// Runs `changes` in an enter-timed animation group after `delay`, unless the overlay is finishing.
    private func afterDelay(_ delay: TimeInterval, _ changes: @escaping @MainActor (SelectionView) -> Void) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !self.isFinishing else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = HUDMotion.enterDuration
                context.timingFunction = HUDMotion.enterTiming
                changes(self)
            }, completionHandler: nil)
        }
    }

    /// Fades everything out (the switch bar sinks a little), then resumes the caller exactly once.
    func finish(_ rect: CGRect?) {
        guard let handler = onFinish else { return }
        onFinish = nil
        isFinishing = true
        HUDHint.shared.hide()
        guard let window, window.isVisible else { handler(rect); return }
        window.ignoresMouseEvents = true
        if !HUDMotion.reduceMotion, let barBottom {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = HUDMotion.exitDuration
                context.timingFunction = HUDMotion.exitTiming
                barBottom.animator().constant = -barBottomInset + Self.barRise / 2
            }
        }
        HUDMotion.hide(window) {
            window.orderOut(nil)
            handler(rect)
        }
    }

    // MARK: - Input

    override func mouseDown(with event: NSEvent) {
        guard !isFinishing else { return }
        NSCursor.crosshair.set()
        HUDMotion.fade(hint, visible: false, duration: 0.12)
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        updateSelection()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil, !isFinishing else { return }
        dragCurrent = convert(event.locationInWindow, from: nil)
        updateSelection()
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        finish(SelectionOverlay.selectionRect(from: start, to: end, in: bounds.size))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            finish(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        finish(nil)
    }

    /// Current selection in view coordinates (bottom-left origin), clamped and rounded like the result.
    /// Nil while it's below `minSelectionSize`, since releasing then picks the whole screen.
    private var selectionInView: CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        let rect = CGRect(
            x: min(start.x, current.x), y: min(start.y, current.y),
            width: abs(current.x - start.x), height: abs(current.y - start.y)
        ).integral.intersection(bounds)
        let minSize = SelectionOverlay.minSelectionSize
        return rect.isNull || rect.width < minSize || rect.height < minSize ? nil : rect
    }

    /// Follows the pointer directly (no easing lag); only the size pill fades in and out.
    private func updateSelection() {
        let selection = selectionInView
        shade.show(selection)
        if let selection { sizePill.show(selection, in: bounds) }
        guard (selection != nil) != showsSize else { return }
        showsSize = selection != nil
        HUDMotion.fade(sizePill, visible: showsSize, duration: 0.12)
    }
}

/// The dim around the selection and its border, drawn with shape layers so dragging never redraws the view.
private final class SelectionShade: NSView {
    private let dim = CAShapeLayer()
    private let border = CAShapeLayer()
    private let handles = CAShapeLayer()
    private var selection: CGRect?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        dim.fillColor = NSColor.black.withAlphaComponent(0.42).cgColor
        dim.fillRule = .evenOdd
        border.fillColor = nil
        border.strokeColor = NSColor.white.cgColor
        border.lineWidth = 1.5
        handles.fillColor = NSColor.white.cgColor
        for layer in [border, handles] {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.4
            layer.shadowRadius = 3
            layer.shadowOffset = .zero
        }
        for sublayer in [dim, border, handles] { layer?.addSublayer(sublayer) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        show(selection)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [dim, border, handles] { layer.contentsScale = scale }
    }

    func show(_ selection: CGRect?) {
        self.selection = selection
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [dim, border, handles] { layer.frame = bounds }
        let dimPath = CGMutablePath()
        dimPath.addRect(bounds)
        if let selection { dimPath.addRect(selection) }
        dim.path = dimPath
        border.path = selection.map { CGPath(rect: $0.insetBy(dx: 0.75, dy: 0.75), transform: nil) }
        handles.path = selection.flatMap(Self.handlesPath)
        CATransaction.commit()
    }

    /// Small dots on the corners, so the selection reads as a frame; left out when it's too small for them.
    private static func handlesPath(for rect: CGRect) -> CGPath? {
        guard min(rect.width, rect.height) >= 32 else { return nil }
        let path = CGMutablePath()
        let inner = rect.insetBy(dx: 0.75, dy: 0.75)
        for corner in [CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY),
                       CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY)] {
            path.addEllipse(in: CGRect(x: corner.x - 3.5, y: corner.y - 3.5, width: 7, height: 7))
        }
        return path
    }
}

/// HUD-surface pill that stays readable on any background. Mouse events pass through to the selection view.
private final class HintPill: NSView {
    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        HUDStyle.paintSurface(layer, radius: 17)
        let label = NSTextField(labelWithAttributedString: Self.styled(text))
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// White phrases with dimmed separator dots between them
    private static func styled(_ text: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let result = NSMutableAttributedString()
        for (index, part) in text.components(separatedBy: " \u{00B7} ").enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "  \u{00B7}  ", attributes: [
                    .font: font, .foregroundColor: HUDStyle.disabled,
                ]))
            }
            result.append(NSAttributedString(string: part, attributes: [.font: font, .foregroundColor: NSColor.white]))
        }
        return result
    }
}

/// "640 × 480" in a tiny HUD pill just outside the selection's corner.
private final class SizePill: NSView {
    private let label = NSTextField(labelWithString: "")
    private static let height: CGFloat = 20
    private static let gap: CGFloat = 6

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        HUDStyle.paintSurface(layer, radius: 6)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        addSubview(label)
        alphaValue = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Below the bottom-left corner; above the top-left one when the screen edge is in the way,
    /// inside the selection when neither fits. Always kept on screen.
    func show(_ selection: CGRect, in bounds: CGRect) {
        label.stringValue = "\(Int(selection.width)) \u{00D7} \(Int(selection.height))"
        let text = label.intrinsicContentSize
        let size = CGSize(width: ceil(text.width) + 14, height: Self.height)
        var origin = CGPoint(x: selection.minX, y: selection.minY - size.height - Self.gap)
        if origin.y < bounds.minY + Self.gap { origin.y = selection.maxY + Self.gap }
        if origin.y + size.height > bounds.maxY - Self.gap { origin.y = selection.minY + Self.gap }
        origin.x = min(max(origin.x, bounds.minX + Self.gap), bounds.maxX - size.width - Self.gap)
        frame = NSRect(origin: origin, size: size)
        label.frame = NSRect(x: 7, y: round((size.height - text.height) / 2), width: ceil(text.width), height: text.height)
    }
}

/// One on/off switch on the options bar.
private struct RecordingToggle {
    let title: String
    let onSymbol: String
    let offSymbol: String
    /// Follows the title in the hover hint: "Microphone — record your mic"
    let detail: String
    let option: WritableKeyPath<RecordingOptions, Bool>
    var device: CaptureDeviceKind?

    var hint: String { "\(title) \u{2014} \(detail)" }

    static let all: [[RecordingToggle]] = [
        [
            RecordingToggle(title: "Microphone", onSymbol: "mic", offSymbol: "mic.slash",
                            detail: "record your mic", option: \.microphone, device: .microphone),
            RecordingToggle(title: "System Audio", onSymbol: "speaker.wave.2", offSymbol: "speaker.slash",
                            detail: "record sound played by your Mac", option: \.systemAudio),
            RecordingToggle(title: "Camera", onSymbol: "video", offSymbol: "video.slash",
                            detail: "your camera in a round bubble", option: \.camera, device: .camera),
        ],
        [
            RecordingToggle(title: "Clicks", onSymbol: "cursorarrow.click", offSymbol: "cursorarrow.click",
                            detail: "highlight mouse clicks", option: \.highlightClicks),
            RecordingToggle(title: "Cursor", onSymbol: "cursorarrow", offSymbol: "cursorarrow",
                            detail: "show the pointer in the recording", option: \.showCursor),
            RecordingToggle(title: "Keys", onSymbol: "keyboard", offSymbol: "keyboard",
                            detail: "show pressed shortcuts (needs Accessibility)",
                            option: \.showKeystrokes, device: .keyboardLayout),
        ],
        [
            RecordingToggle(title: "Countdown", onSymbol: "timer", offSymbol: "timer",
                            detail: "3-2-1 before recording starts", option: \.countdown),
        ],
    ]
}

/// What a toggle's chevron menu picks: a capture device, or the layout that names keys in the keystroke overlay.
private enum CaptureDeviceKind {
    case microphone, camera, keyboardLayout

    var name: String {
        switch self {
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .keyboardLayout: "Key labels"
        }
    }

    /// Title of the nil choice
    var defaultTitle: String { self == .keyboardLayout ? "As Typed" : "System Default" }

    var deviceID: WritableKeyPath<RecordingOptions, String?> {
        switch self {
        case .microphone: \.microphoneDeviceID
        case .camera: \.cameraDeviceID
        case .keyboardLayout: \.keystrokeLayoutID
        }
    }

    var choices: [(id: String, title: String)] {
        switch self {
        case .microphone:
            AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
                .devices.map { ($0.uniqueID, $0.localizedName) }
        case .camera:
            AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified
            ).devices.map { ($0.uniqueID, $0.localizedName) }
        case .keyboardLayout:
            KeyboardLayout.enabled().map { ($0.id, $0.name) }
        }
    }
}

/// The recording switches on a `HUDBar`, in the screenshot toolbar's look, bound to `RecordingOptions.current`.
/// Swallows clicks so they never start a selection.
private final class RecordingOptionsBar: NSView {
    private struct Item {
        let toggle: RecordingToggle
        let button: SwitchButton
        let chevron: ChevronButton?
    }
    private var items: [Item] = []

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        self.shadow = shadow
        let bar = HUDBar(views: groupViews())
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self, userInfo: nil
        ))
        NotificationCenter.default.addObserver(
            self, selector: #selector(optionsDidChange), name: RecordingOptions.didChange, object: nil
        )
        refresh(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Toggle groups separated by HUD dividers.
    private func groupViews() -> [NSView] {
        var views: [NSView] = []
        for (index, group) in RecordingToggle.all.enumerated() {
            if index > 0 { views.append(HUDDivider()) }
            views.append(contentsOf: group.map(makeItem))
        }
        return views
    }

    /// An icon switch; one with a device menu gets a small chevron right after it.
    private func makeItem(_ toggle: RecordingToggle) -> NSView {
        let index = items.count
        let button = SwitchButton(title: toggle.title)
        button.hint = toggle.hint
        button.handler = { [weak self] in self?.toggleOption(at: index) }
        guard let device = toggle.device else {
            items.append(Item(toggle: toggle, button: button, chevron: nil))
            return button
        }
        let chevron = ChevronButton(device: device)
        chevron.handler = { [weak self, weak chevron] in
            guard let self, let chevron else { return }
            self.showDeviceMenu(from: chevron, for: index)
        }
        items.append(Item(toggle: toggle, button: button, chevron: chevron))
        let pair = NSStackView(views: [button, chevron])
        pair.spacing = 0
        return pair
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    @objc private func optionsDidChange() {
        refresh(animated: true)
    }

    /// On = white icon with a dot under it; off = dimmed, slashed icon. Changes cross-fade.
    /// (No filled tiles: these are independent switches, and a row of filled "selected" tiles read as noise.)
    private func refresh(animated: Bool) {
        let options = RecordingOptions.current
        for item in items {
            let isOn = options[keyPath: item.toggle.option]
            if animated && item.button.isOn == isOn { continue }
            if animated {
                for view in [item.button, item.chevron].compactMap({ $0 as NSView? }) {
                    view.layer?.add(Self.crossfade(), forKey: "toggle")
                }
            }
            item.button.symbol = isOn ? item.toggle.onSymbol : item.toggle.offSymbol
            item.button.isOn = isOn
            item.chevron?.isOn = isOn
        }
    }

    private static func crossfade() -> CATransition {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.15
        return transition
    }

    private func toggleOption(at index: Int) {
        var options = RecordingOptions.current
        options[keyPath: items[index].toggle.option].toggle()
        RecordingOptions.current = options
        refresh(animated: true) // `current` skips the notification when nothing changed
    }

    private func showDeviceMenu(from sender: ChevronButton, for index: Int) {
        let device = sender.device
        let selectedID = RecordingOptions.current[keyPath: device.deviceID]
        let menu = NSMenu()
        let systemDefault = NSMenuItem(title: device.defaultTitle, action: #selector(pickDevice(_:)), keyEquivalent: "")
        menu.addItem(systemDefault)
        menu.addItem(.separator())
        for choice in device.choices {
            let item = NSMenuItem(title: choice.title, action: #selector(pickDevice(_:)), keyEquivalent: "")
            item.representedObject = choice.id
            menu.addItem(item)
        }
        for item in menu.items where !item.isSeparatorItem {
            item.target = self
            item.tag = index
            item.state = item.representedObject as? String == selectedID ? .on : .off
        }
        HUDHint.shared.hide()  // the menu would cover it
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender)
    }

    @objc private func pickDevice(_ sender: NSMenuItem) {
        let toggle = items[sender.tag].toggle
        guard let device = toggle.device else { return }
        var options = RecordingOptions.current
        options[keyPath: device.deviceID] = sender.representedObject as? String
        options[keyPath: toggle.option] = true
        RecordingOptions.current = options
    }
}

/// Small chevron right after a switch that opens its device menu; a faint tile on hover.
private final class ChevronButton: HUDHintButton {
    let device: CaptureDeviceKind
    var isOn = false { didSet { refresh() } }
    private var isHovered = false { didSet { refresh() } }

    init(device: CaptureDeviceKind) {
        self.device = device
        super.init(frame: .zero)
        title = ""
        image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        imagePosition = .imageOnly
        isBordered = false
        hint = "Choose \(device.name.lowercased())"
        setAccessibilityLabel(hint)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        widthAnchor.constraint(equalToConstant: 16).isActive = true
        heightAnchor.constraint(equalToConstant: HUDStyle.buttonSize).isActive = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
    }

    private func refresh() {
        contentTintColor = isHovered ? .white : isOn ? NSColor.white.withAlphaComponent(0.7) : HUDStyle.disabled
        layer?.backgroundColor = isHovered ? NSColor.white.withAlphaComponent(0.1).cgColor : nil
    }
}

/// An independent on/off switch in the recording bar: white icon with a small dot underneath when on,
/// dimmed when off, a faint tile on hover. Distinct from `HUDButton`'s "selected" tile, which marks the
/// one chosen tool of a group.
private final class SwitchButton: HUDHintButton {
    var isOn = false { didSet { refresh() } }
    var symbol = "" {
        didSet {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: HUDStyle.iconPointSize, weight: .regular))
        }
    }
    private let label: String
    private let dot = CALayer()
    private var isHovered = false { didSet { refresh() } }

    init(title: String) {
        label = title
        super.init(frame: .zero)
        self.title = ""
        imagePosition = .imageOnly
        isBordered = false
        setAccessibilityLabel(title)
        wantsLayer = true
        layer?.cornerRadius = HUDStyle.buttonRadius
        layer?.cornerCurve = .continuous
        dot.backgroundColor = NSColor.white.cgColor
        dot.cornerRadius = 1.5
        layer?.addSublayer(dot)
        widthAnchor.constraint(equalToConstant: HUDStyle.buttonSize).isActive = true
        heightAnchor.constraint(equalToConstant: HUDStyle.buttonSize).isActive = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        dot.frame = CGRect(x: bounds.midX - 1.5, y: isFlipped ? bounds.maxY - 5 : 2, width: 3, height: 3)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
    }

    private func refresh() {
        contentTintColor = isOn ? .white : NSColor.white.withAlphaComponent(0.4)
        dot.opacity = isOn ? 0.9 : 0
        layer?.backgroundColor = isHovered ? NSColor.white.withAlphaComponent(0.1).cgColor : nil
        setAccessibilityValue(isOn ? "On" : "Off")
    }
}
