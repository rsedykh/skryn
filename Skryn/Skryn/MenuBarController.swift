import AppKit

/// The menu bar icons: one `NSStatusItem` per icon enabled in Settings → Menu Bar, what a click on one
/// means, the menu dropping from it, and every image and title they show (`render` is the only writer).
/// The first enabled icon is the main one: it spins while uploading and turns red after a failure.
/// While recording, the record icon (else the main one) is the red stop button with the elapsed time.
@MainActor
final class MenuBarController: NSObject {
    struct State: Equatable {
        var recordingSince: Date?
        var uploading = false
        var failed = false
    }

    enum Click {
        /// A click on an icon that does its action
        case perform(MenuBarAction)
        /// A right-click, or any click when clicks open the menu
        case openMenu(NSStatusBarButton)
        /// The stop button: a click stops the recording, a right-click asks
        case stopRecording, openRecordingMenu(NSStatusBarButton)
    }

    var onClick: (Click) -> Void = { _ in }
    var onDrop: (URL) -> Void = { _ in }

    private var items: [MenuBarAction: NSStatusItem] = [:]
    /// Icons to show once recording ends (an icon is the stop button meanwhile)
    private var pendingIcons: [MenuBarAction]?
    private var state = State()
    /// Ticks while uploading or recording: spinner frames and the elapsed time
    private var timer: Timer?
    private var spinnerFrame = 0
    private var showsRejectedFile = false

    private var mainItem: NSStatusItem? { MenuBarAction.allCases.lazy.compactMap { self.items[$0] }.first }
    private var recordingItem: NSStatusItem? { items[.record] ?? mainItem }

    private let spinnerImages: [NSImage] = [
        "arrow.up", "arrow.up.right", "arrow.right", "arrow.down.right",
        "arrow.down", "arrow.down.left", "arrow.left", "arrow.up.left",
    ].compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: "Uploading") }

    private let stopImage: NSImage? = {
        let image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop Recording")?
            .withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))
        image?.isTemplate = false  // menu bar images are templates (one color) unless told otherwise
        return image
    }()

    /// Shows `icons` (in `MenuBarAction` order); waits while recording.
    func setIcons(_ icons: [MenuBarAction]) {
        pendingIcons = icons
        applyPendingIcons()
    }

    func update(_ newState: State) {
        guard newState != state else { return }
        if newState.uploading && !state.uploading { spinnerFrame = 0 }
        state = newState
        applyPendingIcons()
        let needsTimer = state.uploading || state.recordingSince != nil
        if needsTimer && timer == nil {
            let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)  // keep ticking while a menu is open
            self.timer = timer
        } else if !needsTimer {
            timer?.invalidate()
            timer = nil
        }
        render()
    }

    /// Opens `menu` from `button`'s icon (the main icon when nil).
    func popUp(_ menu: NSMenu, from button: NSStatusBarButton?) {
        guard let item = items.values.first(where: { $0.button === button }) ?? mainItem else { return }
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// A warning icon for two seconds after something other than an image was dragged onto an icon.
    private func flashRejectedFile() {
        StatusHUD.show("Only images can be opened here", style: .failure)
        showsRejectedFile = true
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.showsRejectedFile = false
            self?.render()
        }
    }

    // MARK: - Items

    private func applyPendingIcons() {
        guard state.recordingSince == nil, let icons = pendingIcons else { return }
        pendingIcons = nil
        // Created in order, each to the left of the last: Record ends up leftmost, Screenshot rightmost
        for action in MenuBarAction.allCases {
            items[action] = syncItem(items[action], wanted: icons.contains(action), action: action)
        }
        render()
    }

    private func syncItem(_ item: NSStatusItem?, wanted: Bool, action: MenuBarAction) -> NSStatusItem? {
        guard wanted else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            return nil
        }
        if let item { return item }
        let newItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        newItem.autosaveName = "skryn.\(action.rawValue)"  // macOS keeps the user's ⌘-drag arrangement
        guard let button = newItem.button else { return newItem }
        button.toolTip = action.title
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let dropView = StatusItemDropView(frame: button.bounds)  // any icon takes dropped images
        dropView.onDrop = { [weak self] in self?.onDrop($0) }
        dropView.onReject = { [weak self] in self?.flashRejectedFile() }
        dropView.autoresizingMask = [.width, .height]
        button.addSubview(dropView)
        return newItem
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let isRightClick = event.type == .rightMouseUp
        if state.recordingSince != nil, sender === recordingItem?.button {
            onClick(isRightClick ? .openRecordingMenu(sender) : .stopRecording)
        } else if isRightClick || MenuBarSettings.current.clickOpensMenu {
            onClick(.openMenu(sender))
        } else {
            onClick(.perform(items.first { $0.value.button === sender }?.key ?? .screenshot))
        }
    }

    // MARK: - Rendering

    private func tick() {
        if state.uploading { spinnerFrame += 1 }
        render()
    }

    /// Priority: the stop button and timer, then the upload spinner, the rejected-file warning, the red
    /// failed icon, and the plain icon.
    private func render() {
        let main = mainItem
        let recording = recordingItem
        for (action, item) in items {
            guard let button = item.button else { continue }
            if let start = state.recordingSince, item === recording {
                setLength(NSStatusItem.variableLength, of: item)
                button.imagePosition = .imageLeading
                button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                button.image = stopImage
                button.title = " " + Self.elapsedString(Date().timeIntervalSince(start))
                continue
            }
            setLength(NSStatusItem.squareLength, of: item)
            button.title = ""
            button.image = image(for: action, isMain: item === main)
        }
    }

    private func image(for action: MenuBarAction, isMain: Bool) -> NSImage? {
        if isMain && state.uploading && !spinnerImages.isEmpty {
            return spinnerImages[spinnerFrame % spinnerImages.count]
        }
        if isMain && showsRejectedFile {
            return NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Invalid file")
        }
        let icon = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)
        guard isMain && state.failed else { return icon }
        let failedIcon = icon?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        failedIcon?.isTemplate = false  // templates are drawn in one color, which would drop the red
        return failedIcon
    }

    private func setLength(_ length: CGFloat, of item: NSStatusItem) {
        if item.length != length { item.length = length }
    }

    /// "0:07", "12:34", "1:02:03"
    static func elapsedString(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
