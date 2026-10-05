import AppKit

// The visual language shared by Skryn's floating controls (screenshot toolbar, recording switch bar,
// HUD confirmations, hints): a near-black surface with a hairline border, 32pt icon buttons that are
// white when active and dimmed otherwise, thin dividers between groups, and instant hover hints.

/// Design tokens for the HUD look. Change them here, not at call sites.
@MainActor
enum HUDStyle {
    static let surface = NSColor(white: 0.1, alpha: 0.92)
    static let surfaceOpaque = NSColor(white: 0.11, alpha: 1)
    static let hairline = NSColor.white.withAlphaComponent(0.12)
    static let selectedFill = NSColor.white.withAlphaComponent(0.18)
    static let divider = NSColor.white.withAlphaComponent(0.18)
    static let dimmed = NSColor.white.withAlphaComponent(0.6)
    static let disabled = NSColor.white.withAlphaComponent(0.25)
    static let barRadius: CGFloat = 14
    static let buttonRadius: CGFloat = 8
    static let buttonSize: CGFloat = 32
    static let barHeight: CGFloat = 48
    static let iconPointSize: CGFloat = 15
    /// The icon beside a button's title
    static let titledIconPointSize: CGFloat = 13

    /// Paints `layer` as a HUD surface (call after `wantsLayer = true`).
    static func paintSurface(_ layer: CALayer?, radius: CGFloat? = nil, opaque: Bool = false) {
        layer?.backgroundColor = (opaque ? surfaceOpaque : surface).cgColor
        layer?.borderColor = hairline.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = radius ?? barRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
}

/// Shared motion: every Skryn window and overlay enters and leaves the same way, so state changes
/// read as one app. Entrances ease out and settle; exits are shorter. Reduce Motion gets fades only.
@MainActor
enum HUDMotion {
    static let enterDuration: TimeInterval = 0.22
    static let exitDuration: TimeInterval = 0.16
    /// Ease-out that settles quickly, close to the system's own panel animations
    static let enterTiming = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
    static let exitTiming = CAMediaTimingFunction(name: .easeIn)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Which way a window travels while it appears (`up` = rises into place).
    enum Travel { case none, up, down }

    /// Fades `window` in from alpha 0, travelling `distance` points and growing from `scale` into its
    /// current frame. Orders it front (key when `makeKey`); `completion` runs once it has settled.
    static func show(
        _ window: NSWindow, travel: Travel = .none, distance: CGFloat = 8, scale: CGFloat = 1,
        makeKey: Bool = false, completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let final = window.frame
        let start = reduceMotion ? final : offset(final, travel: travel, distance: distance, scale: scale)
        window.alphaValue = 0
        window.setFrame(start, display: false)
        if makeKey { window.makeKeyAndOrderFront(nil) }
        // Also above other apps' windows: macOS can refuse to activate Skryn (cooperative activation),
        // and then a key window would still open behind whatever app is in front
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = enterDuration
            context.timingFunction = enterTiming
            window.animator().alphaValue = 1
            if start != final { window.animator().setFrame(final, display: true) }
        }, completionHandler: {
            MainActor.assumeIsolated { completion?() }
        })
    }

    /// Animates `window` out (the reverse of `show`), then runs `completion` — order out or close there.
    static func hide(
        _ window: NSWindow, travel: Travel = .none, distance: CGFloat = 8, scale: CGFloat = 1,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        let end = reduceMotion ? window.frame : offset(window.frame, travel: travel, distance: distance, scale: scale)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = exitDuration
            context.timingFunction = exitTiming
            window.animator().alphaValue = 0
            if end != window.frame { window.animator().setFrame(end, display: true) }
        }, completionHandler: { MainActor.assumeIsolated { completion() } })
    }

    /// Fades a view in or out (for parts of a window: hints, labels, overlays inside a view).
    static func fade(_ view: NSView, visible: Bool, duration: TimeInterval? = nil) {
        if visible { view.isHidden = false }
        let target: CGFloat = visible ? 1 : 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration ?? (visible ? enterDuration : exitDuration)
            view.animator().alphaValue = target
        }, completionHandler: {
            MainActor.assumeIsolated {
                if !visible && view.alphaValue == 0 { view.isHidden = true }
            }
        })
    }

    /// Makes the next change to `view`'s look (tint, background, image) a quick crossfade instead of a jump.
    static func crossfade(_ view: NSView, duration: TimeInterval = 0.12) {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.layer?.add(fade, forKey: "crossfade")
    }

    /// `frame` shrunk to `scale` around its center and moved against `travel` by `distance`.
    static func offset(_ frame: NSRect, travel: Travel, distance: CGFloat, scale: CGFloat) -> NSRect {
        var rect = frame.insetBy(dx: frame.width * (1 - scale) / 2, dy: frame.height * (1 - scale) / 2)
        switch travel {
        case .up: rect.origin.y -= distance
        case .down: rect.origin.y += distance
        case .none: break
        }
        return rect
    }
}

/// Rounded dark bar holding a row of HUD controls: the look shared by every Skryn toolbar.
final class HUDBar: NSView {
    /// The groups in a row, a divider between each two.
    convenience init(groups: [[NSView]]) {
        self.init(views: groups.enumerated().flatMap { index, group in index == 0 ? group : [HUDDivider()] + group })
    }

    init(views: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        HUDStyle.paintSurface(layer)

        let stack = NSStackView(views: views)
        stack.spacing = 2
        // Breathing room around dividers, so groups read as groups
        for (index, view) in views.enumerated() where view is HUDDivider && index > 0 {
            stack.setCustomSpacing(8, after: views[index - 1])
            stack.setCustomSpacing(8, after: view)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // Buttons are 32pt in a 48pt bar: the same 8pt margin on every side
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            heightAnchor.constraint(equalToConstant: HUDStyle.barHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Swallow clicks on the background so they don't fall through
    override func mouseDown(with event: NSEvent) {}
}

/// Thin vertical line between button groups (a system separator is nearly invisible on the dark bar).
final class HUDDivider: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = HUDStyle.divider.cgColor
        widthAnchor.constraint(equalToConstant: 1).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Borderless icon (optionally icon + title) button: white when selected, dimmed otherwise.
final class HUDButton: HUDHintButton {

    var isSelectedTool = false {
        didSet {
            setAccessibilityValue(isSelectedTool ? "Selected" : nil)
            refresh()
        }
    }
    var isEmphasized = false { didSet { refresh() } }
    /// Icon and title side by side (Save / Copy / Upload). Drawn by hand: NSButton's own layout puts a
    /// borderless title a little low and off-center, so the pair is laid out here, the icon centered
    /// on the title's cap height and the group centered in the button.
    var showsTitle = false {
        didSet {
            let size = showsTitle ? HUDStyle.titledIconPointSize : HUDStyle.iconPointSize
            image = image?.withSymbolConfiguration(.init(pointSize: size, weight: .regular))
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// The plain title, drawn next to the icon when `showsTitle`
    private let label: String
    private static let titlePadding: CGFloat = 12
    private static let iconTitleGap: CGFloat = 6

    init(title: String, symbol: String) {
        label = title
        super.init(frame: .zero)
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: HUDStyle.iconPointSize, weight: .regular))
        imagePosition = .imageOnly
        font = .systemFont(ofSize: 12, weight: .medium)
        isBordered = false
        setAccessibilityLabel(title)
        wantsLayer = true
        layer?.cornerRadius = HUDStyle.buttonRadius
        heightAnchor.constraint(equalToConstant: HUDStyle.buttonSize).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: HUDStyle.buttonSize).isActive = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isEnabled: Bool { didSet { refresh() } }
    override var isHighlighted: Bool { didSet { if showsTitle { needsDisplay = true } } }

    override var intrinsicContentSize: NSSize {
        guard showsTitle else { return super.intrinsicContentSize }
        let width = Self.titlePadding * 2 + (image?.size.width ?? 0) + Self.iconTitleGap + titleText.size().width
        return NSSize(width: ceil(width), height: HUDStyle.buttonSize)
    }

    private var titleText: NSAttributedString {
        NSAttributedString(string: label, attributes: [
            .font: font ?? .systemFont(ofSize: 12, weight: .medium), .foregroundColor: contentTintColor ?? .white,
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsTitle, let font else { return super.draw(dirtyRect) }
        let color = (contentTintColor ?? .white).withAlphaComponent(isHighlighted ? 0.7 : 1)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
        let icon = image?.withSymbolConfiguration(.init(paletteColors: [color]))
        let iconSize = icon?.size ?? .zero
        let textWidth = ceil(text.size().width)
        var x = round((bounds.width - iconSize.width - Self.iconTitleGap - textWidth) / 2)
        // Center the caps (not the line box, which includes descender room) on the button's middle
        let capMiddle = bounds.midY
        if let icon {
            let iconRect = NSRect(x: x, y: round(capMiddle - iconSize.height / 2), width: iconSize.width, height: iconSize.height)
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += iconSize.width + Self.iconTitleGap
        }
        // Flipped: the line's top sits ascender above the baseline, which is capHeight / 2 below the middle
        let baseline = capMiddle + font.capHeight / 2
        text.draw(at: NSPoint(x: x, y: round(baseline - font.ascender)))
    }

    private func refresh() {
        let bright = isSelectedTool || isEmphasized || showsTitle
        contentTintColor = !isEnabled ? HUDStyle.disabled : bright ? .white : HUDStyle.dimmed
        let background: NSColor? = isEmphasized ? .controlAccentColor : isSelectedTool ? HUDStyle.selectedFill : nil
        layer?.backgroundColor = background?.cgColor
        if showsTitle { needsDisplay = true }
    }
}

/// Toolbar button with an instant hover hint. System tooltips wait about a second, and a
/// non-key panel doesn't always show them; the hint appears as soon as the pointer arrives.
class HUDHintButton: NSButton {
    var handler: (() -> Void)?
    var hint: String? {
        didSet { setAccessibilityHelp(hint) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(clicked)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The pointer is over the button; subclasses restyle in `hoverChanged()`
    private(set) var isHovered = false {
        didSet { if isHovered != oldValue { hoverChanged() } }
    }

    func hoverChanged() {}

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        if let hint { HUDHint.shared.show(hint, above: self) }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        HUDHint.shared.hide()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { HUDHint.shared.hide() }  // the toolbar closed under the pointer
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func clicked() { handler?() }
}

/// The single hint bubble shared by the toolbar's buttons.
@MainActor
final class HUDHint {
    static let shared = HUDHint()
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    private init() {
        panel = HUDPanel()
        panel.ignoresMouseEvents = true
        panel.level = .floating
        let background = NSView()
        background.wantsLayer = true
        HUDStyle.paintSurface(background.layer, radius: 6)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4),
        ])
        panel.contentView = background
    }

    /// Centers the hint 6pt above `view`, kept on its screen.
    func show(_ text: String, above view: NSView) {
        guard let window = view.window else { return }
        label.stringValue = text
        let size = panel.contentView?.fittingSize ?? .zero
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        var origin = NSPoint(x: round(anchor.midX - size.width / 2), y: anchor.maxY + 6)
        if let visible = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        }
        let frame = NSRect(origin: origin, size: size)
        // Above the window that owns the button (the area picker sits above .floating)
        panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, window.level.rawValue + 1))
        hiding = false
        guard panel.isVisible, panel.alphaValue > 0 else {
            // First hint: a quick fade so it doesn't flash, but still effectively instant
            panel.setFrame(frame, display: true)
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.1; panel.animator().alphaValue = 1 }
            return
        }
        // Moving between buttons: glide to the new one instead of blinking
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = HUDMotion.enterTiming
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        hiding = true
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; self.panel.animator().alphaValue = 0 }, completionHandler: {
            MainActor.assumeIsolated { if self.hiding { self.panel.orderOut(nil) } }
        })
    }

    /// Set while fading out; a new `show` cancels the pending order-out
    private var hiding = false
}

/// The window every HUD control floats in: borderless, non-activating (clicks don't take focus from
/// the app in front), transparent around its rounded surface, dark.
class HUDPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
    }
}

/// A full-screen or floating overlay that draws its own look (recording frame, keystrokes, camera bubble,
/// area picker): borderless, transparent, no window shadow, on every Space and over full-screen apps.
/// Esc runs `onEscape` while it's key.
class OverlayPanel: NSPanel {
    var onEscape: (() -> Void)?

    /// `behavior` is added to joining all Spaces and full-screen apps; `nonactivating` keeps Skryn
    /// inactive when the overlay is clicked or dragged.
    init(frame: CGRect, level: NSWindow.Level, behavior: NSWindow.CollectionBehavior = [], nonactivating: Bool = false) {
        super.init(
            contentRect: frame, styleMask: nonactivating ? [.borderless, .nonactivatingPanel] : .borderless,
            backing: .buffered, defer: false
        )
        setFrame(frame, display: false)
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = behavior.union([.canJoinAllSpaces, .fullScreenAuxiliary])
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let onEscape {  // ESC
            onEscape()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

extension CABasicAnimation {
    convenience init(keyPath: String, from: Any, to: Any) {
        self.init(keyPath: keyPath)
        fromValue = from
        toValue = to
    }
}

// MARK: - Window motion

/// The exit every animated Skryn window shares: its `close()` calls `run`, which plays the exit once and then
/// the real close (`finish`, which calls `super.close()`), so `windowWillClose` fires after the animation.
/// `willBegin` is posted as the exit starts: owners let go of the window then, so a new capture or panel can
/// open while the old one is still fading.
@MainActor
final class WindowExit {
    static let willBegin = Notification.Name("SkrynWindowExitWillBegin")
    private(set) var isRunning = false

    /// Plays `window`'s exit (none when it isn't on screen), then `finish`. Ignored while an exit is running.
    func run(_ window: NSWindow, scale: CGFloat, finish: @escaping @MainActor @Sendable () -> Void) {
        guard !isRunning else { return }
        isRunning = true
        NotificationCenter.default.post(name: Self.willBegin, object: window)
        guard window.isVisible else { return finish() }
        HUDMotion.hide(window, scale: scale, completion: finish)
    }
}

/// A panel that fades and grows in when presented and plays the reverse when closed (every close path:
/// Cmd+W, the close button, ESC), through `WindowExit`.
class AnimatedPanel: NSPanel {
    /// The panel grows from `entranceScale` as it opens and shrinks toward `exitScale` as it closes
    var entranceScale: CGFloat = 0.97
    var exitScale: CGFloat = 0.98
    private let exit = WindowExit()
    var isClosing: Bool { exit.isRunning }

    /// Shows the panel with the shared entrance (key); brings it forward if it's already up.
    func present() {
        guard !isClosing else { return }
        collectionBehavior.insert(.moveToActiveSpace)  // open on the Space the user is looking at
        // Panels hide whenever Skryn isn't active; Skryn's windows should stay like normal windows
        hidesOnDeactivate = false
        guard !isVisible else {
            makeKeyAndOrderFront(nil)
            orderFrontRegardless()  // in front even if macOS doesn't activate Skryn
            return
        }
        HUDMotion.show(self, scale: entranceScale, makeKey: true)
    }

    override func close() {
        exit.run(self, scale: exitScale) { [weak self] in self?.finishClose() }
    }

    /// Runs once the exit has played, just before the real close: release what the panel holds.
    func didFinishExit() {}

    private func finishClose() {
        didFinishExit()
        super.close()
    }
}
