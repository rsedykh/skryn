import AppKit

/// Wires the pieces together: menu bar icons and menu (`MenuBarController`, `StatusMenu`), shortcuts
/// (`HotkeyCenter`), windows (`WindowPresenter`), what to do with a result (`OutputDelivery`,
/// `UploadCoordinator`), what went wrong (`Problems`), and the capture and recording flows themselves.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()
    private let windows = WindowPresenter()
    private let problems = Problems()
    private lazy var hotkeys = HotkeyCenter { [weak self] in self?.hotkeyPressed($0) }
    private lazy var uploads = UploadCoordinator(problems: problems) { [weak self] in self?.showSettings() }
    private lazy var delivery = OutputDelivery(problems: problems, uploads: uploads)

    /// What capture is in flight; a new screenshot or recording starts only from `.idle`.
    private enum CapturePhase {
        case idle
        /// Picking an area for a screenshot, or taking it
        case capturingScreenshot
        /// Picking an area and the switches, counting down, starting the recorder
        case startingRecording
        case recording(RecordingSession)
        /// Writing the file out, until the result panel shows
        case finishingRecording

        var session: RecordingSession? {
            if case .recording(let session) = self { session } else { nil }
        }
        var isIdle: Bool { if case .idle = self { true } else { false } }
    }

    private var phase = CapturePhase.idle {
        didSet { renderMenuBar() }
    }
    private var isRecording: Bool { phase.session != nil }

    /// Everything that can start something: menu bar clicks, menu tiles, shortcuts, dropped images.
    private enum Request {
        case action(MenuBarAction)
        case open(URL)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.setUp()
        Defaults.migrate()
        problems.onChange = { [weak self] in self?.renderMenuBar() }
        uploads.onActivityChange = { [weak self] in self?.renderMenuBar() }
        windows.isCapturing = { [weak self] in self?.phase.isIdle == false }
        menuBar.onClick = { [weak self] in self?.menuBarClicked($0) }
        menuBar.onDrop = { [weak self] in self?.begin(.open($0)) }
        menuBar.setIcons(MenuBarSettings.current.icons)
        registerHotkeys()
        observeSettings()

        if !UserDefaults.standard.bool(forKey: Defaults.hasLaunchedBefore) {
            UserDefaults.standard.set(true, forKey: Defaults.hasLaunchedBefore)
            // Delay lets the activation policy change propagate to the window server
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showAbout()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // MARK: - Starting things

    /// The one gate for everything that starts something. A capture already under way (a double-pressed
    /// shortcut) wins.
    private func begin(_ request: Request) {
        guard !redirected(request), phase.isIdle else { return }
        switch request {
        case .action(.screenshot): captureScreen(area: false)
        case .action(.area): captureScreen(area: true)
        case .action(.record): if #available(macOS 15.0, *) { startRecording() }
        case .open(let url): openImage(url)
        }
    }

    /// The record action stops a recording in progress; otherwise nothing new starts while recording,
    /// and an open editor or recording result comes forward instead. True when `request` ends here.
    private func redirected(_ request: Request) -> Bool {
        let isOpen = if case .open = request { true } else { false }
        if case .action(.record) = request, isRecording {
            stopRecording()
        } else if isRecording {
            if isOpen { StatusHUD.show("Stop the recording first", style: .info) }
        } else if let editor = windows.editorWindow {
            editor.makeKeyAndOrderFront(nil)  // finish this one first
            NSApp.activate(ignoringOtherApps: true)
            if isOpen { StatusHUD.show("Finish the open one first", style: .info) }
        } else {
            return false
        }
        return true
    }

    private func menuBarClicked(_ click: MenuBarController.Click) {
        switch click {
        case .perform(let action): begin(.action(action))
        case .openMenu(let button): menuBar.popUp(makeMenu(), from: button)
        case .stopRecording: stopRecording()
        case .openRecordingMenu(let button):
            menuBar.popUp(StatusMenu.makeRecording(
                notice: problems.menuText,
                stop: { [weak self] in self?.stopRecording() },
                discard: { [weak self] in self?.stopRecording(discard: true) }
            ), from: button)
        }
    }

    private func makeMenu() -> NSMenu {
        let actions = StatusMenu.Actions(
            perform: { [weak self] in self?.begin(.action($0)) },
            copyLink: { [weak self] in self?.uploads.copyLink($0) },
            saveUpload: { [weak self] in self?.uploads.saveToDesktop($0) },
            retryUpload: { [weak self] in self?.uploads.retry($0) },
            openScreenRecordingSettings: { [weak self] in self?.openScreenRecordingSettings() },
            settings: { [weak self] in self?.showSettings() },
            about: { [weak self] in self?.showAbout() },
            quit: { NSApp.terminate(nil) }
        )
        let content = StatusMenu.Content(
            tiles: MenuBarSettings.current.menuTiles,
            shortcuts: Dictionary(uniqueKeysWithValues: MenuBarAction.available.map { ($0, $0.hotkey) }),
            recentUploads: UploadHistory.recentUploads(),
            errorText: problems.menuText,
            screenRecordingPermissionMissing: problems.screenRecordingPermissionMissing
        )
        return StatusMenu.make(content, actions: actions)
    }

    private func renderMenuBar() {
        menuBar.update(.init(
            recordingSince: phase.session?.startedAt, uploading: uploads.isUploading, failed: problems.marksIconRed
        ))
    }

    // MARK: - Windows

    private func showAbout() {
        windows.show(AboutPanel.self) { AboutPanel() }
    }

    private func showSettings() {
        windows.show(SettingsPanel.self) { SettingsPanel() }
    }

    private func openImage(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            StatusHUD.show("Couldn't open this image", detail: url.lastPathComponent, style: .failure)
            return
        }
        showEditor(with: image)
    }

    private func showEditor(with screenshot: NSImage, on screen: NSScreen? = nil) {
        guard let screen = screen ?? screenWithMouse() else { return }
        windows.present(AnnotationWindow(screen: screen, screenshot: screenshot) { [weak self] action, shot in
            self?.delivery.deliver(action, screenshot: shot) ?? false
        })
    }

    // MARK: - Settings and shortcuts

    /// Any Settings edit dismisses the notices in the menu (the user is fixing something), except those
    /// about the recording in progress and the shortcuts' own; shortcuts and icons are re-applied when
    /// they change.
    private func observeSettings() {
        let names = [
            Hotkey.didChange, MenuBarSettings.didChange, OutputSettings.didChange, RecordingOptions.didChange,
            SaveModifiers.didChange, UploadProviders.didChange, Defaults.saveFolderDidChange,
        ]
        for name in names {
            NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange(_:)), name: name, object: nil)
        }
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        problems.clear(except: isRecording ? [.recording, .hotkeys] : [.hotkeys])
        switch notification.name {
        case Hotkey.didChange: registerHotkeys()
        case MenuBarSettings.didChange: menuBar.setIcons(MenuBarSettings.current.icons)
        default: break
        }
    }

    /// Registers the shortcuts; the ones that couldn't be are listed in the menu, and a shortcut another
    /// app has gets a notification.
    private func registerHotkeys() {
        let failed = hotkeys.register()
        problems[.hotkeys] = failed.isEmpty ? nil : failed.map(\.message).joined(separator: "\n")
        for case .taken(let hotkey) in failed {
            Notifier.show(
                "Shortcut \(hotkey.displayString) is taken", detail: "Another app uses it \u{2014} pick another in Settings",
                style: .failure, action: .init(title: "Open Settings") { [weak self] in self?.showSettings() }
            )
        }
    }

    private func hotkeyPressed(_ action: MenuBarAction) {
        if let settings = windows.window(of: SettingsPanel.self), settings.isRecordingHotkey {
            settings.confirmCurrentHotkey()
            return
        }
        begin(.action(action))
    }

    // MARK: - Screenshot

    /// The screen the mouse cursor is on, falling back to the main screen.
    private func screenWithMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
    }

    /// Captures the display under the cursor, or with `area` an area the user drags out on it first.
    private func captureScreen(area: Bool) {
        guard let screen = screenWithMouse() else { return }
        phase = .capturingScreenshot
        Task {
            defer { phase = .idle }
            var picked = CaptureArea(screen: screen)
            if area {
                guard let selection = await SelectionOverlay.pickArea(on: screen, fullScreenVerb: "capture") else {
                    return
                }
                picked = selection
            }
            do {
                // Skryn's own windows (the picker included) are excluded from the capture
                let fullScreen = try await ScreenCapture.capture(displayID: picked.displayID, scale: picked.scale)
                guard let screenshot = area ? ScreenCapture.crop(fullScreen, to: picked.rect) : fullScreen else {
                    NSSound.beep()
                    StatusHUD.show("Couldn't capture that area", detail: "Try again", style: .failure)
                    return
                }
                problems[.capture] = nil
                showEditor(with: screenshot, on: NSScreen.screens.first { ScreenCapture.displayID(for: $0) == picked.displayID })
            } catch {
                reportCaptureFailure(error.localizedDescription)
            }
        }
    }

    /// A screenshot or recording that couldn't run: red icon, the reason in the menu, and a notification
    /// with the way out when it's the permission.
    private func reportCaptureFailure(_ reason: String) {
        let missingPermission = !CGPreflightScreenCaptureAccess()
        problems.report(.capture, reason, .notification(
            missingPermission ? "Skryn needs Screen Recording permission" : "Capture failed",
            detail: missingPermission ? "If Skryn is already listed, remove it and add it again" : reason,
            action: missingPermission
                ? .init(title: "Open Settings") { [weak self] in self?.openScreenRecordingSettings() } : nil
        ))
    }

    private func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        if let url { NSWorkspace.shared.open(url) }
    }

    // MARK: - Screen Recording

    /// Lets the user pick an area on the screen under the cursor and the recording switches, then
    /// records it until the menu bar icon (or the record shortcut) stops it.
    @available(macOS 15.0, *)
    private func startRecording() {
        guard let screen = screenWithMouse() else { return }
        phase = .startingRecording
        Task {
            do {
                guard let session = try await RecordingSession.begin(on: screen, onEnded: { self.recordingEnded($0) })
                else {
                    phase = .idle
                    return
                }
                phase = .recording(session)
                problems[.capture] = nil
                problems[.recording] = session.notices.isEmpty ? nil : session.notices.joined(separator: "\n")
                if let notice = problems[.recording] {  // e.g. keystrokes without Accessibility: say so now, not in the video
                    StatusHUD.show("Recording", detail: notice, symbol: "record.circle", style: .info)
                }
            } catch {
                phase = .idle
                reportCaptureFailure(error.localizedDescription)
            }
        }
    }

    /// The recording ended on its own: the error, or nil when the system's menu bar button stopped it.
    private func recordingEnded(_ error: Error?) {
        if let error {
            problems[.recording] = "Recording stopped: \(error.localizedDescription)"
            Notifier.show("Recording stopped", detail: error.localizedDescription, style: .failure)
        }
        stopRecording()
    }

    /// Stops the recording and shows the result panel, or deletes the video when `discard` is true.
    private func stopRecording(discard: Bool = false) {
        guard let session = phase.session else { return }
        phase = .finishingRecording
        Task {
            defer { phase = .idle }
            do {
                let videoURL = try await session.finish()
                if discard {
                    try? FileManager.default.removeItem(at: videoURL)
                    StatusHUD.show("Recording discarded", symbol: "trash", style: .info)
                } else {
                    showRecordingPanel(for: videoURL)
                }
            } catch {
                guard !discard else { return }
                problems[.capture] = "Recording failed: \(error.localizedDescription)"
                NSSound.beep()
                StatusHUD.show("Recording failed", detail: error.localizedDescription, style: .failure)
            }
        }
    }

    private func showRecordingPanel(for videoURL: URL) {
        let baseName = OutputDelivery.baseName(for: Date())
        windows.present(RecordingPanel(videoURL: videoURL) { [weak self] action, currentURL, progress in
            // `currentURL` is the trimmed copy when the user trimmed
            await self?.handleRecordingAction(action, videoURL: currentURL, baseName: baseName, progress: progress)
                ?? false
        })
    }

    /// Converts the recording to the format chosen in Settings → Output (the panel stays open meanwhile),
    /// then delivers it. Returns false to keep the panel open.
    private func handleRecordingAction(
        _ action: SaveAction, videoURL: URL, baseName: String, progress: @escaping VideoExporter.Progress
    ) async -> Bool {
        guard action != .cloud || uploads.isReady() else { return false }  // before converting for nothing
        let settings = OutputSettings.current
        let fileURL: URL
        do {
            fileURL = try await VideoExporter.export(videoURL, settings: settings, progress: progress)
        } catch {
            let message = "Couldn't convert to \(settings.videoFormat.title): \(error.localizedDescription)"
            problems.report(.save, message, .hud(message))
            return false
        }
        defer { if fileURL != videoURL { try? FileManager.default.removeItem(at: fileURL) } }
        return delivery.deliver(action, file: fileURL, filename: "\(baseName).\(settings.videoFormat.fileExtension)")
    }
}
