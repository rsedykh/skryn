import AppKit

/// One on/off switch on the options bar.
private struct RecordingToggle {
    let title: String
    let onSymbol: String
    let offSymbol: String
    /// Follows the title in the hover hint: "Microphone — record your mic"
    let detail: String
    let option: WritableKeyPath<RecordingOptions, Bool>
    var device: RecordingChoice?

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

/// The recording switches on a `HUDBar`, in the screenshot toolbar's look, bound to `RecordingOptions.current`:
/// the area picker's accessory when recording. Swallows clicks so they never start a selection.
final class RecordingOptionsBar: NSView {
    private struct Item {
        let toggle: RecordingToggle
        let button: SwitchButton
        let chevron: ChevronButton?
    }
    private var items: [Item] = []
    /// The choice whose menu is open (`NSMenu.popUp` returns once it has closed)
    private var pendingChoice: RecordingChoice?

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        self.shadow = shadow
        let bar = HUDBar(groups: RecordingToggle.all.map { $0.map(makeItem) })
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

    /// An icon switch; one with a device menu gets a small chevron right after it.
    private func makeItem(_ toggle: RecordingToggle) -> NSView {
        let button = SwitchButton(title: toggle.title)
        button.hint = toggle.hint
        button.handler = { [weak self] in self?.toggle(toggle.option) }
        guard let device = toggle.device else {
            items.append(Item(toggle: toggle, button: button, chevron: nil))
            return button
        }
        let chevron = ChevronButton(device: device)
        chevron.handler = { [weak self, weak chevron] in
            guard let self, let chevron else { return }
            self.showDeviceMenu(from: chevron)
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
                    HUDMotion.crossfade(view, duration: 0.15)
                }
            }
            item.button.symbol = isOn ? item.toggle.onSymbol : item.toggle.offSymbol
            item.button.isOn = isOn
            item.chevron?.isOn = isOn
        }
    }

    private func toggle(_ option: WritableKeyPath<RecordingOptions, Bool>) {
        var options = RecordingOptions.current
        options[keyPath: option].toggle()
        RecordingOptions.current = options
        refresh(animated: true) // `current` skips the notification when nothing changed
    }

    private func showDeviceMenu(from sender: ChevronButton) {
        let device = sender.device
        let selectedID = RecordingOptions.current[keyPath: device.selection]
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
            item.state = item.representedObject as? String == selectedID ? .on : .off
        }
        pendingChoice = device
        HUDHint.shared.hide()  // the menu would cover it
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender)
    }

    @objc private func pickDevice(_ sender: NSMenuItem) {
        guard let choice = pendingChoice else { return }
        var options = RecordingOptions.current
        options[keyPath: choice.selection] = sender.representedObject as? String
        options[keyPath: choice.option] = true
        RecordingOptions.current = options
    }
}

/// Small chevron right after a switch that opens its device menu; a faint tile on hover.
private final class ChevronButton: HUDHintButton {
    let device: RecordingChoice
    var isOn = false { didSet { refresh() } }

    init(device: RecordingChoice) {
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

    override func hoverChanged() { refresh() }

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

    override func hoverChanged() { refresh() }

    private func refresh() {
        contentTintColor = isOn ? .white : NSColor.white.withAlphaComponent(0.4)
        dot.opacity = isOn ? 0.9 : 0
        layer?.backgroundColor = isHovered ? NSColor.white.withAlphaComponent(0.1).cgColor : nil
        setAccessibilityValue(isOn ? "On" : "Off")
    }
}
