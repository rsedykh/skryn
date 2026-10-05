import AppKit

/// A Skryn window that animates in with `present()`.
@MainActor
protocol PresentableWindow: NSWindow {
    func present()
}

extension AnimatedPanel: PresentableWindow {}
extension AnnotationWindow: PresentableWindow {}

/// Skryn's windows (editor, recording result, Settings, About) and the app mode they need: while one is
/// open the app shows in Cmd+Tab with the main menu and comes to the front; when the last one has closed
/// it goes back to menu bar only and hands focus back.
///
/// A window counts as gone as soon as its exit animation starts (`WindowExit.willBegin`), so the next
/// capture or panel can open while it fades; the app mode changes once it has really closed.
@MainActor
final class WindowPresenter: NSObject, NSWindowDelegate {
    /// True while a capture or recording is in progress: hiding the app would hide its overlays too
    var isCapturing: () -> Bool = { false }
    private var windows: [NSWindow] = []

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(exitWillBegin(_:)), name: WindowExit.willBegin, object: nil
        )
    }

    /// The open window of this type, if any.
    func window<W: NSWindow>(of type: W.Type) -> W? {
        windows.lazy.compactMap { $0 as? W }.first
    }

    /// The open screenshot editor or recording result (only one at a time)
    var editorWindow: NSWindow? { window(of: AnnotationWindow.self) ?? window(of: RecordingPanel.self) }

    /// The open window of this type, brought forward, or a new one from `make`.
    func show<W: PresentableWindow>(_ type: W.Type, make: () -> W) {
        if let existing = window(of: type) {
            existing.present()
        } else {
            present(make())
        }
    }

    func present(_ window: some PresentableWindow) {
        window.delegate = self
        windows.append(window)
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = makeMainMenu()
        NSApp.activate(ignoringOtherApps: true)
        window.present()
    }

    @objc private func exitWillBegin(_ notification: Notification) {
        windows.removeAll { $0 === notification.object as AnyObject }
    }

    func windowWillClose(_ notification: Notification) {
        windows.removeAll { $0 === notification.object as AnyObject }
        guard windows.isEmpty else { return }  // another window opened while this one was leaving
        NSApp.mainMenu = nil
        // Hiding the app would also hide the recording frame, keystrokes and camera bubble
        if !isCapturing() {
            // Hiding would hide every Skryn window, the HUD confirming the action included
            if StatusHUD.isShowing { NSApp.deactivate() } else { NSApp.hide(nil) }
        }
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Main menu

    /// One main menu for every window, so shortcuts keep working whichever window was opened last.
    /// Items whose action has no responder in the key window's chain are disabled automatically.
    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        addSubmenu("Skryn", to: mainMenu, items: [
            NSMenuItem(title: "Quit Skryn", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ])
        let closeItem = NSMenuItem(title: "Close", action: #selector(closeKeyWindow), keyEquivalent: "w")
        closeItem.target = self
        addSubmenu("File", to: mainMenu, items: [closeItem])
        addSubmenu("Edit", to: mainMenu, items: [
            NSMenuItem(title: "Undo", action: #selector(AnnotationView.undo(_:)), keyEquivalent: "z"),
            NSMenuItem(title: "Redo", action: #selector(AnnotationView.redo(_:)), keyEquivalent: "Z"),
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ])
        return mainMenu
    }

    private func addSubmenu(_ title: String, to mainMenu: NSMenu, items: [NSMenuItem]) {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        mainMenu.addItem(item)
    }

    /// Borderless windows don't support `performClose(_:)`, so Close calls `close()` directly
    @objc private func closeKeyWindow() {
        // While a sheet is up the sheet is key; close its parent so its own close() logic runs
        let keyWindow = NSApp.keyWindow.map { $0.sheetParent ?? $0 }
        (keyWindow ?? window(of: AnnotationWindow.self))?.close()
    }
}
