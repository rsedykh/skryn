import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Recorded HUD that shows the shortcuts pressed during a screen recording (like KeyCastr).
/// Only shortcuts (⌘/⌃/⌥ held) and special keys are shown, so typed text and passwords stay out of the video.
@MainActor
final class KeystrokeOverlay {
    private static let visibleDuration: TimeInterval = 1.5
    private static let maxVisible = 3
    /// Room under the caps inside the window, so they can sink as they leave without being clipped
    private static let sinkRoom: CGFloat = 8
    private static let bottomInset: CGFloat = 40 - sinkRoom
    private static let windowHeight: CGFloat = 72 + sinkRoom
    private static let heldAlpha: CGFloat = 0.6

    @MainActor
    private final class Entry {
        let label: String
        var count = 1
        let chip: KeycapView
        var hideWork: DispatchWorkItem?

        init(label: String) {
            self.label = label
            chip = KeycapView(text: label)
        }

        var text: String { count > 1 ? "\(label) ×\(count)" : label }
    }

    private let window: OverlayPanel
    private let stack = NSStackView()
    private let heldChip = KeycapView(text: "")
    private var entries: [Entry] = []
    private var monitors: [Any] = []
    private let layout: KeyboardLayout?

    var windowID: CGWindowID { CGWindowID(window.windowNumber) }

    /// Starts listening and shows the (empty) HUD over the bottom center of `area`.
    /// Returns nil when Accessibility permission is missing, after asking macOS to show its prompt.
    /// `layoutID` names the keys with that keyboard layout instead of the active one.
    static func start(area: CaptureArea, layoutID: String?) -> KeystrokeOverlay? {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return nil }
        return KeystrokeOverlay(area: area.globalFrame, layout: layoutID.flatMap(KeyboardLayout.init(id:)))
    }

    private init(area: CGRect, layout: KeyboardLayout?) {
        self.layout = layout
        let frame = NSRect(x: area.minX, y: area.minY + Self.bottomInset, width: area.width, height: Self.windowHeight)
        window = OverlayPanel(frame: frame, level: .statusBar, behavior: [.stationary, .ignoresCycle])
        window.ignoresMouseEvents = true

        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        heldChip.isHidden = true
        heldChip.alphaValue = 0
        stack.addArrangedSubview(heldChip)

        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.sinkRoom)
        ])
        window.contentView = content
        window.alphaValue = 1
        window.orderFrontRegardless()
        installMonitors()
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    /// Stops listening; whatever is still on screen fades out with the window.
    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        entries.forEach { $0.hideWork?.cancel() }
        entries.removeAll()
        let window = window
        HUDMotion.hide(window) { window.orderOut(nil) }
    }

    // MARK: - Events

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .flagsChanged {
            showHeld(flags)
            return
        }
        // Unshifted character, so ⇧⌘4 reads "4", not "$": from the chosen layout, else the active one
        let characters = layout?.character(for: event.keyCode)
            ?? event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers
        guard let label = Self.label(keyCode: event.keyCode, characters: characters, modifiers: flags) else { return }
        // No fade here: the new cap pops in where the preview was, as if the preview became it
        heldChip.isHidden = true
        heldChip.alphaValue = 0
        show(label)
    }

    /// Previews held ⌘/⌃/⌥ before the key arrives, so slow shortcuts don't look like nothing happened.
    private func showHeld(_ flags: NSEvent.ModifierFlags) {
        let shown = flags.intersection([.control, .option, .shift, .command])
        let visible = !shown.isDisjoint(with: [.control, .option, .command])
        if visible { heldChip.text = modifierSymbols(shown) }
        // alphaValue is already the target while a fade runs, so a quick re-press revives a fading preview
        guard visible != (!heldChip.isHidden && heldChip.alphaValue > 0) else { return }
        if visible {
            relayout { self.heldChip.isHidden = false }
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = visible ? 0.12 : 0.1
            heldChip.animator().alphaValue = visible ? Self.heldAlpha : 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard !visible, self.heldChip.alphaValue == 0, !self.heldChip.isHidden else { return }
                self.relayout { self.heldChip.isHidden = true }
            }
        })
    }

    private func show(_ label: String) {
        if let last = entries.last, last.label == label {
            last.count += 1
            relayout { last.chip.setText(last.text) }
            last.chip.bump()
            scheduleHide(last)
            return
        }
        let entry = Entry(label: label)
        entries.append(entry)
        relayout { self.stack.insertArrangedSubview(entry.chip, at: self.stack.arrangedSubviews.count - 1) }
        entry.chip.popIn()
        if entries.count > Self.maxVisible { dismiss(entries[0]) }
        scheduleHide(entry)
    }

    private func scheduleHide(_ entry: Entry) {
        entry.hideWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak entry] in
            guard let self, let entry else { return }
            self.dismiss(entry)
        }
        entry.hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: work)
    }

    /// Fades and sinks the cap away; the others then glide into its place.
    private func dismiss(_ entry: Entry) {
        entry.hideWork?.cancel()
        entries.removeAll { $0 === entry }
        entry.chip.sinkOut { [weak self] in
            self?.relayout { entry.chip.removeFromSuperview() }
        }
    }

    /// Applies `change` to the stack, then slides the caps that moved from their old spots (FLIP),
    /// so inserting, removing or resizing one never makes the others jump.
    private func relayout(_ change: () -> Void) {
        let before = Dictionary(uniqueKeysWithValues: stack.arrangedSubviews.map { (ObjectIdentifier($0), $0.frame.minX) })
        change()
        window.contentView?.layoutSubtreeIfNeeded()
        guard !HUDMotion.reduceMotion else { return }
        for view in stack.arrangedSubviews where !view.isHidden {
            guard let oldX = before[ObjectIdentifier(view)], abs(oldX - view.frame.minX) > 0.5 else { continue }
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = oldX - view.frame.minX
            slide.toValue = 0
            slide.isAdditive = true
            slide.duration = HUDMotion.enterDuration
            slide.timingFunction = HUDMotion.enterTiming
            view.layer?.add(slide, forKey: "slide")
        }
    }

    // MARK: - Formatting

    private static let specialKeys: [Int: String] = {
        var keys: [Int: String] = [
            kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Escape: "⎋", kVK_Tab: "⇥",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Space: "␣",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Home: "↖", kVK_End: "↘"
        ]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (index, code) in fKeys.enumerated() { keys[code] = "F\(index + 1)" }
        return keys
    }()

    /// The HUD text for a key press, or nil when it must not be shown: plain, ⇧ and ⌥ typing
    /// (text, passwords — ⌥ types characters on many layouts, e.g. ⌥L = @ on German) and a lone Space.
    /// ⌥ still shows with special keys (⌥←). Modifiers in ⌃⌥⇧⌘ order, then the key.
    static func label(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> String? {
        let mods = modifiers.intersection([.control, .option, .shift, .command])
        let isShortcut = !mods.isDisjoint(with: [.control, .command])
        let isModified = isShortcut || mods.contains(.option)
        let key: String
        if let special = specialKeys[Int(keyCode)] {
            if Int(keyCode) == kVK_Space && !isModified { return nil }
            key = special
        } else {
            guard isShortcut, let characters, let first = characters.first,
                  !first.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            key = String(first).uppercased()
        }
        return modifierSymbols(mods) + key
    }
}

/// A keycap holding one combo: HUD surface and hairline, a 1px top highlight and a soft inner gradient
/// that make it read as a physical key.
private final class KeycapView: NSView {
    private static let radius: CGFloat = 12
    private let field = NSTextField(labelWithString: "")

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    init(text: String) {
        // A nonzero starting size, so the autoresizing highlight keeps its corner margins as the cap grows
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        wantsLayer = true
        HUDStyle.paintSurface(layer, radius: Self.radius)
        addSubview(SheenView(frame: bounds))
        // 1px highlight along the top edge, stopping short of the rounded corners
        let highlight = NSView(frame: NSRect(x: Self.radius, y: bounds.height - 1, width: bounds.width - 2 * Self.radius, height: 1))
        highlight.wantsLayer = true
        highlight.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        highlight.autoresizingMask = [.width, .minYMargin]
        addSubview(highlight)

        let base = NSFont.systemFont(ofSize: 28, weight: .semibold)
        field.font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 28) } ?? base
        field.textColor = .white
        field.stringValue = text
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Motion

    /// Pops in: grows from 0.85 while fading in.
    func popIn() {
        let group = CAAnimationGroup()
        group.animations = [CABasicAnimation(keyPath: "opacity", from: 0, to: 1)]
        if !HUDMotion.reduceMotion {
            group.animations?.append(CABasicAnimation(keyPath: "transform", from: NSValue(caTransform3D: scaled(0.85)),
                                                to: NSValue(caTransform3D: scaled(1))))
        }
        group.duration = HUDMotion.enterDuration * 1.2
        group.timingFunction = HUDMotion.enterTiming
        layer?.add(group, forKey: "enter")
    }

    /// Crossfades to the new text (e.g. ×2 → ×3).
    func setText(_ newText: String) {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.12
        field.layer?.add(fade, forKey: "text")
        text = newText
    }

    /// A tiny bump, so a repeated press reads as one more press.
    func bump() {
        guard !HUDMotion.reduceMotion else { return }
        let bump = CAKeyframeAnimation(keyPath: "transform")
        bump.values = [scaled(1), scaled(1.08), scaled(1)].map { NSValue(caTransform3D: $0) }
        bump.keyTimes = [0, 0.35, 1]
        bump.duration = 0.22
        bump.timingFunctions = [HUDMotion.enterTiming, CAMediaTimingFunction(name: .easeInEaseOut)]
        layer?.add(bump, forKey: "bump")
    }

    /// Fades out while sinking a few points, then runs `completion`.
    func sinkOut(completion: @escaping @MainActor () -> Void) {
        let group = CAAnimationGroup()
        group.animations = [CABasicAnimation(keyPath: "opacity", from: 1, to: 0)]
        let sink: CGFloat = superview?.isFlipped == true ? 6 : -6  // down on screen either way
        if !HUDMotion.reduceMotion { group.animations?.append(CABasicAnimation(keyPath: "transform.translation.y", from: 0, to: sink)) }
        group.duration = HUDMotion.exitDuration * 1.4
        group.timingFunction = HUDMotion.exitTiming
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        layer?.add(group, forKey: "exit")
        CATransaction.commit()
    }

    /// Scale around the cap's center (a view's layer is anchored at its corner).
    private func scaled(_ scale: CGFloat) -> CATransform3D {
        guard let layer else { return CATransform3DIdentity }
        let dx = (0.5 - layer.anchorPoint.x) * bounds.width
        let dy = (0.5 - layer.anchorPoint.y) * bounds.height
        let moved = CATransform3DMakeTranslation(dx, dy, 0)
        return CATransform3DTranslate(CATransform3DScale(moved, scale, scale, 1), -dx, -dy, 0)
    }
}

/// The keycap's inner light: a touch lighter at the top, darker at the bottom, like light falling on a key.
private final class SheenView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: NSColor.white.withAlphaComponent(0.07), ending: NSColor.black.withAlphaComponent(0.18))?
            .draw(in: bounds, angle: -90)
    }
}

/// A keyboard layout from the system's input sources, used to name keys independently of the active layout.
struct KeyboardLayout {
    let id: String
    let name: String
    /// The layout's `uchr` data, for `UCKeyTranslate`
    private let data: Data

    /// The keyboard layouts enabled in System Settings → Keyboard → Input Sources.
    static func enabled() -> [KeyboardLayout] {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return sources.compactMap(KeyboardLayout.init(source:))
    }

    /// Looks up an installed layout by input source ID; nil if it isn't installed anymore.
    init?(id: String) {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first else { return nil }
        self.init(source: source)
    }

    private init?(source: TISInputSource) {
        func property<T>(_ key: CFString, as type: T.Type) -> T? {
            guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
        }
        guard let id = property(kTISPropertyInputSourceID, as: String.self),
              let name = property(kTISPropertyLocalizedName, as: String.self),
              let data = property(kTISPropertyUnicodeKeyLayoutData, as: Data.self) else { return nil }
        self.id = id
        self.name = name
        self.data = data
    }

    /// The character the key types with no modifiers, e.g. "c" for kVK_ANSI_C on U.S.
    func character(for keyCode: UInt16) -> String? {
        data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
