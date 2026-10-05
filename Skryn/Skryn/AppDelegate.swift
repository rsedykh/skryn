import AppKit
import Carbon.HIToolbox
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One menu bar icon per action enabled in Settings → Menu Bar (`MenuBarSettings`)
    private var statusItems: [MenuBarAction: NSStatusItem] = [:]
    /// The main icon (the first enabled one): it also shows upload progress and errors
    private var statusItem: NSStatusItem {
        MenuBarAction.allCases.lazy.compactMap { self.statusItems[$0] }.first!
    }
    /// The icon that turns into the stop button and timer while recording
    private var recordingStatusItem: NSStatusItem { statusItems[.record] ?? statusItem }
    /// The icon whose click opened the menu, so the menu drops from it
    private var menuSourceButton: NSStatusBarButton?
    private var annotationWindow: AnnotationWindow?
    private var hotKeyRef: EventHotKeyRef?
    private var recordHotKeyRef: EventHotKeyRef?
    private var areaHotKeyRef: EventHotKeyRef?
    /// Key codes and modifiers last registered, so unchanged shortcuts aren't re-registered (and re-reported)
    private var registeredHotkeys: [UInt32]?
    private var settingsPanel: SettingsPanel?
    private var aboutPanel: AboutPanel?
    private var recordingPanel: RecordingPanel?
    /// Keeps the screenshot toolbar's undo state current; removed when the editor closes
    private var annotationToolbar: AnnotationToolbar?
    private var annotationBackdrop: EditorBackdrop?
    private var toolbarObservers: [NSObjectProtocol] = []
    /// The temp file shown in `recordingPanel`; deleted when the panel closes.
    private var recordingURL: URL?
    /// Stops the screen recording in progress and returns the finished file. Nil when not recording.
    /// A closure because `ScreenRecorder` is macOS 15+ and stored properties can't be availability-gated.
    private var stopActiveRecording: (() async throws -> URL)? {
        didSet {
            updateElapsedTime()
            if stopActiveRecording == nil { applyMenuBarLayout() }  // a change made while recording
        }
    }
    private var recordingStartedAt: Date?
    private var elapsedTimer: Timer?
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    private var iconTimer: Timer?
    private var animationFrameIndex = 0
    private var isCapturing = false
    private var uploadFailed = false
    private var captureFailed = false
    /// Shown in the right-click menu: upload, save, capture, or hotkey problems
    private var lastError: String?

    private let spinnerSymbols = [
        "arrow.up", "arrow.up.right", "arrow.right", "arrow.down.right",
        "arrow.down", "arrow.down.left", "arrow.left", "arrow.up.left"
    ]
    private lazy var spinnerImages: [NSImage] = spinnerSymbols.compactMap {
        NSImage(systemSymbolName: $0, accessibilityDescription: "Uploading")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.setUp()
        applyMenuBarLayout()  // creates the menu bar icons
        installHotkeyHandler()
        registerHotkey()

        if !UserDefaults.standard.bool(forKey: Defaults.hasLaunchedBefore) {
            UserDefaults.standard.set(true, forKey: Defaults.hasLaunchedBefore)
            // Delay lets the activation policy change propagate to the window server
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showAbout()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let isRightClick = event.type == .rightMouseUp

        if stopActiveRecording != nil, sender === recordingStatusItem.button {
            if isRightClick { showRecordingMenu() } else { stopRecording() }
        } else if isRightClick || MenuBarSettings.current.clickOpensMenu {
            showQuitMenu(from: sender)
        } else {
            perform(statusItems.first { $0.value.button === sender }?.key ?? .screenshot)
        }
    }

    private func perform(_ action: MenuBarAction) {
        switch action {
        case .screenshot: captureScreen()
        case .area: captureScreen(area: true)
        case .record: if #available(macOS 15.0, *) { startRecording() }
        }
    }

    // MARK: - Menu Bar Icons

    /// Adds or removes menu bar icons to match `MenuBarSettings.current`.
    /// Waits while recording (an icon is the stop button then).
    private func applyMenuBarLayout() {
        guard stopActiveRecording == nil else { return }
        let icons = MenuBarSettings.current.icons
        // Created in order, each to the left of the last: Record ends up leftmost, Screenshot rightmost
        for action in MenuBarAction.allCases {
            statusItems[action] = syncItem(statusItems[action], wanted: icons.contains(action), action: action)
        }
        updateIdleIcon()
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
        button.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)
        button.toolTip = action.title
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let dropView = StatusItemDropView(frame: button.bounds)  // any icon takes dropped images
        dropView.appDelegate = self
        dropView.autoresizingMask = [.width, .height]
        button.addSubview(dropView)
        return newItem
    }

    /// Installs the app's main menu. Used by every window we show (annotation, settings,
    /// about) so shortcuts keep working whichever window was opened last. Items whose
    /// action has no responder in the key window's chain are disabled automatically.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "Quit Skryn", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        ))
        let appItem = NSMenuItem(title: "Skryn", action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileMenu = NSMenu(title: "File")
        let closeItem = NSMenuItem(title: "Close", action: #selector(closeKeyWindow), keyEquivalent: "w")
        closeItem.target = self
        fileMenu.addItem(closeItem)
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(
            title: "Undo", action: #selector(AnnotationView.undo(_:)), keyEquivalent: "z"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Redo", action: #selector(AnnotationView.redo(_:)), keyEquivalent: "Z"
        ))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(
            title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"
        ))
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    /// Borderless windows don't support `performClose(_:)`, so Close calls `close()` directly
    @objc private func closeKeyWindow() {
        // While a sheet is up the sheet is key; close its parent so its own close() logic runs
        let keyWindow = NSApp.keyWindow.map { $0.sheetParent ?? $0 }
        (keyWindow ?? annotationWindow)?.close()
    }

    // MARK: - Right-Click Menu

    private func showQuitMenu(from button: NSStatusBarButton? = nil) {
        menuSourceButton = button
        let tiles = MenuBarSettings.current.menuTiles
        var actions = StatusMenu.Actions(
            screenshot: tiles.contains(.screenshot) ? { [weak self] in self?.captureScreen() } : nil,
            areaScreenshot: tiles.contains(.area) ? { [weak self] in self?.captureScreen(area: true) } : nil,
            record: nil,
            copyLink: { [weak self] in self?.copyUploadLink($0) },
            saveUpload: { [weak self] in self?.saveUploadToDesktop($0) },
            retryUpload: { [weak self] in self?.retryUpload($0) },
            openScreenRecordingSettings: { [weak self] in self?.openScreenRecordingSettings() },
            settings: { [weak self] in self?.showSaveDestination() },
            about: { [weak self] in self?.showAbout() },
            quit: { NSApp.terminate(nil) }
        )
        if #available(macOS 15.0, *), tiles.contains(.record) {
            actions.record = { [weak self] in self?.startRecording() }
        }
        let content = StatusMenu.Content(
            screenshotShortcut: .init(keyCode: Defaults.hotkey.keyCode, modifiers: Defaults.hotkey.modifiers),
            areaShortcut: .init(keyCode: Defaults.areaHotkey.keyCode, modifiers: Defaults.areaHotkey.modifiers),
            recordShortcut: .init(keyCode: Defaults.recordHotkey.keyCode, modifiers: Defaults.recordHotkey.modifiers),
            recentUploads: UploadHistory.recentUploads(),
            errorText: lastError,
            screenRecordingPermissionMissing: lastError != nil && captureFailed && !CGPreflightScreenCaptureAccess()
        )
        popUp(StatusMenu.make(content, actions: actions))
    }

    /// Right-click while recording: stop (keep the video) or discard it.
    private func showRecordingMenu() {
        let menu = NSMenu()
        // Notices from starting the recording (e.g. no Accessibility permission for keystrokes)
        if let notice = lastError {
            let noticeItem = NSMenuItem(title: notice, action: nil, keyEquivalent: "")
            noticeItem.attributedTitle = NSAttributedString(
                string: notice,
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 11)]
            )
            menu.addItem(noticeItem)
            menu.addItem(.separator())
        }
        let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecordingFromMenu), keyEquivalent: "")
        stopItem.target = self
        stopItem.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: "Stop")
        menu.addItem(stopItem)
        let discardItem = NSMenuItem(
            title: "Discard Recording", action: #selector(discardRecordingFromMenu), keyEquivalent: ""
        )
        discardItem.target = self
        discardItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Discard")
        menu.addItem(discardItem)
        popUp(menu)
    }

    /// Opens `menu` from the icon that was clicked (the main icon by default).
    private func popUp(_ menu: NSMenu) {
        let item = statusItems.values.first { $0.button === menuSourceButton } ?? statusItem
        menuSourceButton = nil
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func stopRecordingFromMenu() {
        stopRecording()
    }

    @objc private func discardRecordingFromMenu() {
        stopRecording(discard: true)
    }

    // MARK: - Save / Upload

    /// Performs the given save action. Returns false if the action cannot proceed
    /// (e.g. cloud upload without a key configured), so the caller can keep the window open.
    @discardableResult
    func handleAction(_ action: SaveAction, cgImage: CGImage, pixelsPerPoint: CGFloat, captureDate: Date) -> Bool {
        let settings = OutputSettings.current
        let filename = "skryn-\(Self.filenameFormatter.string(from: captureDate)).\(settings.imageFormat.fileExtension)"
        let pointSize = CGSize(
            width: CGFloat(cgImage.width) / max(pixelsPerPoint, 1), height: CGFloat(cgImage.height) / max(pixelsPerPoint, 1)
        )

        switch action {
        case .clipboard:
            // PNG first for apps and browsers that prefer it; TIFF for older AppKit consumers
            guard let pngData = imageData(from: cgImage, type: .png),
                  let tiffData = imageData(from: cgImage, type: .tiff) else {
                reportSaveFailure("Copy failed: could not encode image")
                return false
            }
            let item = NSPasteboardItem()
            item.setData(pngData, forType: .png)
            item.setData(tiffData, forType: .tiff)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([item])
            StatusHUD.show("Copied", symbol: "doc.on.clipboard")
            return true

        case .local:
            guard let data = encode(cgImage, pointSize: pointSize, settings: settings, failure: "Save failed") else {
                return false
            }
            guard let fileURL = saveLocally(data: data, filename: filename) else { return false }
            notifySaved(fileURL)
            return true

        case .cloud:
            if let problem = UploadProviders.current.setupProblem {
                notifyUploadSetup(problem)
                return false
            }
            guard let data = encode(cgImage, pointSize: pointSize, settings: settings, failure: "Upload failed") else {
                return false
            }
            return uploadToCloud(data: data, filename: filename)
        }
    }

    /// The screenshot in the format chosen under Settings → Output; reports and returns nil on failure.
    private func encode(_ cgImage: CGImage, pointSize: CGSize, settings: OutputSettings, failure: String) -> Data? {
        do {
            return try ImageEncoder.encode(cgImage, pointSize: pointSize, settings: settings)
        } catch {
            reportSaveFailure("\(failure): \(error.localizedDescription)")
            return nil
        }
    }

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter
    }()

    /// Writes the encoded image into the save folder; returns where it went, or nil after reporting the failure.
    @discardableResult
    private func saveLocally(data: Data, filename: String) -> URL? {
        let saveFolder = Defaults.saveFolder
        let fileURL = saveFolder.appendingPathComponent(filename)

        do {
            try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
            try data.write(to: fileURL)
            print("Saved: \(fileURL.path)")
            return fileURL
        } catch {
            reportSaveFailure("Save failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Copies a finished file (a cached upload or a recording) into `folder` (the save folder by default).
    @discardableResult
    private func saveLocally(copyingFrom source: URL, filename: String, to folder: URL = Defaults.saveFolder) -> URL? {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: destination)  // overwrite, like Data.write
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            reportSaveFailure("Save failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func mimeType(forFilename filename: String) -> String {
        UTType(filenameExtension: (filename as NSString).pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }

    private func reportSaveFailure(_ message: String) {
        lastError = message
        NSSound.beep()
        StatusHUD.show(message, style: .failure)
        print("AppDelegate: \(message)")
    }

    // MARK: - Feedback

    // Feedback: immediate results of what the user just did go to `StatusHUD`; results that arrive
    // later (upload links, upload failures) or need a button go to `Notifier` (native notifications).

    private func notifySaved(_ fileURL: URL, title: String? = nil) {
        StatusHUD.show(
            title ?? "Saved to \(fileURL.deletingLastPathComponent().lastPathComponent)",
            detail: fileURL.lastPathComponent, symbol: "square.and.arrow.down"
        )
    }

    /// Upload pressed before the chosen service is set up: say what's missing and open Settings.
    private func notifyUploadSetup(_ problem: String) {
        NSSound.beep()
        StatusHUD.show("Upload isn't set up", detail: problem, style: .failure)
        showSaveDestination()
    }

    private func uploadToCloud(data: Data, filename: String) -> Bool {
        guard let cachePath = UploadHistory.cacheData(data, filename: filename) else {
            print("AppDelegate: failed to cache PNG, falling back to local save")
            guard let fileURL = saveLocally(data: data, filename: filename) else { return false }
            notifySaved(fileURL, title: "Couldn't upload \u{2014} saved instead")
            return true
        }

        startCloudUpload(cachePath: cachePath, filename: filename)
        return true
    }

    /// Records the cached file in Recent Uploads and uploads it, saving locally if the upload fails.
    private func startCloudUpload(cachePath: String, filename: String) {
        let upload = RecentUpload(filename: filename, cdnURL: nil, date: Date(), cacheFilePath: cachePath)
        UploadHistory.add(upload)
        performUpload(cachePath: cachePath, filename: filename, fallbackSave: true)
    }

    func openDroppedImage(_ url: URL) {
        if stopActiveRecording != nil {
            StatusHUD.show("Stop the recording first", style: .info)
            return
        }
        if isWindowClosing {  // the editor/panel is animating out: open this right after
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeRetryDelay) { [weak self] in
                self?.openDroppedImage(url)
            }
            return
        }
        if let busyWindow = openEditorWindow {
            busyWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            StatusHUD.show("Finish the open one first", style: .info)
            return
        }
        guard !isCapturing else { return }
        guard let image = NSImage(contentsOf: url) else {
            StatusHUD.show("Couldn't open this image", detail: url.lastPathComponent, style: .failure)
            return
        }
        showAnnotationWindow(with: image)
    }

    func showRejectedFileIcon() {
        statusItem.button?.image = NSImage(
            systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Invalid file"
        )
        StatusHUD.show("Only images can be opened here", style: .failure)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.updateIdleIcon()
        }
    }

    private func retryUpload(_ upload: RecentUpload) {
        if let problem = UploadProviders.current.setupProblem {
            notifyUploadSetup(problem)
            return
        }
        guard FileManager.default.fileExists(atPath: upload.cacheFilePath) else {
            StatusHUD.show("This file is no longer available", detail: upload.filename, style: .failure)
            return
        }
        performUpload(cachePath: upload.cacheFilePath, filename: upload.filename, fallbackSave: false)
    }

    /// Shared upload logic: animates icon, runs async upload, updates history, handles errors.
    /// If `fallbackSave` is true, saves locally on upload failure.
    private func performUpload(cachePath: String, filename: String, fallbackSave: Bool) {
        let uploadID = UUID()
        let provider = UploadProviders.current  // a Settings change mid-upload doesn't switch providers
        if uploadTasks.isEmpty {
            uploadFailed = false
            captureFailed = false
            lastError = nil
        }
        startIconAnimation()
        StatusHUD.show("Uploading to \(provider.title)\u{2026}", detail: filename, symbol: "icloud.and.arrow.up", style: .info)

        // Task inherits the main actor from this @MainActor class
        let task = Task {
            do {
                let link = try await provider.upload(
                    fileURL: URL(fileURLWithPath: cachePath), filename: filename,
                    contentType: Self.mimeType(forFilename: filename)
                )
                UploadHistory.updateCDNURL(for: filename, url: link)
                copyToClipboard(link)
                if !uploadFailed {
                    lastError = nil
                }
                finishUpload(id: uploadID, failed: false)
                Notifier.show(
                    "Link copied", detail: link,
                    action: .init(title: "Open") {
                        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
                    }
                )
                print("Uploaded: \(link)")
            } catch {
                lastError = "Upload failed: \(error.localizedDescription)"
                finishUpload(id: uploadID, failed: true)
                reportUploadFailure(error, cachePath: cachePath, filename: filename, fallbackSave: fallbackSave)
            }
        }
        uploadTasks[uploadID] = task
    }

    private func reportUploadFailure(_ error: Error, cachePath: String, filename: String, fallbackSave: Bool) {
        print("Upload failed: \(error.localizedDescription)")
        NSSound.beep()
        guard fallbackSave else {
            Notifier.show("Upload failed", detail: error.localizedDescription, style: .failure)
            return
        }
        guard let saved = saveLocally(copyingFrom: URL(fileURLWithPath: cachePath), filename: filename) else {
            // saveLocally reported its own failure; keep both in the menu and say both in the notification
            lastError = "Upload failed: \(error.localizedDescription) \u{2014} saving locally failed too"
            Notifier.show("Upload and local save failed", detail: error.localizedDescription, style: .failure)
            return
        }
        Notifier.show(
            "Upload failed \u{2014} saved to \(saved.deletingLastPathComponent().lastPathComponent)",
            detail: error.localizedDescription, style: .failure,
            action: .init(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
        )
    }

    private func copyUploadLink(_ upload: RecentUpload) {
        guard let url = upload.cdnURL else { return }
        copyToClipboard(url)
        StatusHUD.show("Link copied", detail: url, symbol: "link")
    }

    private func saveUploadToDesktop(_ upload: RecentUpload) {
        let source = URL(fileURLWithPath: upload.cacheFilePath)
        if let saved = saveLocally(copyingFrom: source, filename: upload.filename, to: Defaults.desktopFolder) {
            notifySaved(saved)
        }
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    // MARK: - About Panel

    @objc private func showAbout() {
        if let existing = aboutPanel {
            if existing.isClosing {  // reopen once the close finishes
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeRetryDelay) { [weak self] in self?.showAbout() }
            } else {
                existing.present()
            }
            return
        }

        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        NSApp.activate(ignoringOtherApps: true)

        let panel = AboutPanel()
        panel.delegate = self
        aboutPanel = panel
        panel.present()
    }

    // MARK: - Settings Panel

    @objc private func showSaveDestination() {
        if let existing = settingsPanel {
            if existing.isClosing {  // reopen once the close finishes
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeRetryDelay) { [weak self] in
                    self?.showSaveDestination()
                }
            } else {
                existing.present()
            }
            return
        }

        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        NSApp.activate(ignoringOtherApps: true)

        let panel = SettingsPanel()
        panel.delegate = self
        panel.onSettingsChanged = { [weak self] in
            guard let self else { return }
            if stopActiveRecording == nil {  // keep notices about the recording in progress
                lastError = nil
            }
            uploadFailed = false
            captureFailed = false
            updateIdleIcon()
            registerHotkey()
            applyMenuBarLayout()
        }
        settingsPanel = panel
        panel.present()
    }

    // MARK: - Global Hotkey

    private func installHotkeyHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            delegate.hotkeyPressed(id: hotKeyID.id)
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
    }

    private static let screenshotHotkeyID: UInt32 = 1
    private static let recordHotkeyID: UInt32 = 2
    private static let areaHotkeyID: UInt32 = 3

    private func unregisterHotkey() {
        for ref in [hotKeyRef, recordHotKeyRef, areaHotKeyRef].compactMap({ $0 }) {
            UnregisterEventHotKey(ref)
        }
        hotKeyRef = nil
        recordHotKeyRef = nil
        areaHotKeyRef = nil
    }

    /// Registers the screenshot and area hotkeys, and the recording hotkey where recording is available (macOS 15+).
    /// Does nothing when the shortcuts haven't changed since the last call (Settings calls this on every edit).
    private func registerHotkey() {
        let wanted = [Defaults.hotkey, Defaults.areaHotkey, Defaults.recordHotkey].flatMap { [$0.keyCode, $0.modifiers] }
        guard wanted != registeredHotkeys else { return }
        registeredHotkeys = wanted
        unregisterHotkey()
        hotKeyRef = register(Defaults.hotkey, id: Self.screenshotHotkeyID)
        // Shortcuts saved before area/recording existed can equal their defaults (⇧⌘4, ⇧⌘6):
        // the earlier shortcut keeps the key and the other stays in the menu
        if Defaults.areaHotkey == Defaults.hotkey {
            lastError = "Area screenshot shortcut matches the screenshot shortcut \u{2014} change one in Settings"
        } else {
            areaHotKeyRef = register(Defaults.areaHotkey, id: Self.areaHotkeyID)
        }
        if #available(macOS 15.0, *) {
            if Defaults.recordHotkey == Defaults.hotkey || Defaults.recordHotkey == Defaults.areaHotkey {
                lastError = "Record shortcut matches a screenshot shortcut \u{2014} change one in Settings"
            } else {
                recordHotKeyRef = register(Defaults.recordHotkey, id: Self.recordHotkeyID)
            }
        }
    }

    private func register(_ hotkey: (keyCode: UInt32, modifiers: UInt32), id: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534B5259), id: id)
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr || ref == nil {
            let shortcut = hotkeyDisplayString(keyCode: hotkey.keyCode, carbonModifiers: hotkey.modifiers)
            lastError = "Hotkey \(shortcut) unavailable — it may be taken by another app"
            Notifier.show(
                "Shortcut \(shortcut) is taken", detail: "Another app uses it \u{2014} pick another in Settings",
                style: .failure, action: .init(title: "Open Settings") { [weak self] in self?.showSaveDestination() }
            )
        }
        return ref
    }

    fileprivate func hotkeyPressed(id: UInt32) {
        if settingsPanel?.isRecordingHotkey == true {
            settingsPanel?.confirmCurrentHotkey()
            return
        }
        if id == Self.recordHotkeyID, #available(macOS 15.0, *) {
            // The record hotkey also stops a recording in progress
            if stopActiveRecording != nil {
                stopRecording()
            } else if let busyWindow = recordingPanel ?? annotationWindow {
                busyWindow.makeKeyAndOrderFront(nil)  // finish this one first
                NSApp.activate(ignoringOtherApps: true)
            } else {
                startRecording()
            }
            return
        }
        captureScreen(area: id == Self.areaHotkeyID)
    }

    // MARK: - Capture

    /// Longer than the windows' exit animation (`HUDMotion.exitDuration`), so a retry finds it gone
    private static let closeRetryDelay: TimeInterval = 0.25

    /// The screenshot editor or recording result window, unless it's already animating closed
    private var openEditorWindow: NSWindow? {
        if let annotationWindow, !annotationWindow.isClosing { return annotationWindow }
        if let recordingPanel, !recordingPanel.isClosing { return recordingPanel }
        return nil
    }

    private var isWindowClosing: Bool {
        annotationWindow?.isClosing == true || recordingPanel?.isClosing == true
    }

    /// The screen the mouse cursor is on, falling back to the main screen.
    private func screenWithMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
    }

    /// Captures the display under the cursor. `isCapturing` blocks a second capture
    /// (e.g. a double-pressed hotkey) from opening another window while this one is in flight.
    /// Captures the display under the cursor, or with `area` an area the user drags out on it first.
    private func captureScreen(area: Bool = false) {
        if isWindowClosing {  // the editor/panel is animating out: capture right after
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeRetryDelay) { [weak self] in
                self?.captureScreen(area: area)
            }
            return
        }
        if let busyWindow = openEditorWindow {
            busyWindow.makeKeyAndOrderFront(nil)  // finish this one first
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard !isCapturing, stopActiveRecording == nil, let screen = screenWithMouse() else { return }
        let displayID = ScreenCapture.displayID(for: screen)
        let scale = max(screen.backingScaleFactor, 1)
        isCapturing = true
        Task {
            defer { isCapturing = false }
            var rect: CGRect?
            if area {
                guard let picked = await SelectionOverlay.pickArea(on: screen, for: .screenshot) else { return }
                rect = picked
            }
            do {
                // Skryn's own windows (the picker included) are excluded from the capture
                let fullScreen = try await ScreenCapture.capture(displayID: displayID, scale: scale)
                var screenshot = fullScreen
                if let rect {
                    guard let cropped = ScreenCapture.crop(fullScreen, to: rect) else {
                        NSSound.beep()
                        StatusHUD.show("Couldn't capture that area", detail: "Try again", style: .failure)
                        return
                    }
                    screenshot = cropped
                }
                if captureFailed {
                    captureFailed = false
                    lastError = nil
                    updateIdleIcon()
                }
                let target = NSScreen.screens.first { ScreenCapture.displayID(for: $0) == displayID }
                showAnnotationWindow(with: screenshot, on: target)
            } catch {
                captureFailed = true
                lastError = error.localizedDescription
                NSSound.beep()
                updateIdleIcon()
                notifyCaptureFailure(error)
            }
        }
    }

    /// Capture and recording failures: the reason, plus the way out when it's the permission.
    private func notifyCaptureFailure(_ error: Error) {
        let missingPermission = !CGPreflightScreenCaptureAccess()
        Notifier.show(
            missingPermission ? "Skryn needs Screen Recording permission" : "Capture failed",
            detail: missingPermission ? "If Skryn is already listed, remove it and add it again" : error.localizedDescription,
            style: .failure,
            action: missingPermission
                ? .init(title: "Open Settings") { [weak self] in self?.openScreenRecordingSettings() } : nil
        )
    }

    @objc private func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        if let url { NSWorkspace.shared.open(url) }
    }

    private func showAnnotationWindow(with screenshot: NSImage, on screen: NSScreen? = nil) {
        guard let screen = screen ?? screenWithMouse() else { return }

        let window = AnnotationWindow(screen: screen, screenshot: screenshot)
        window.delegate = self
        annotationWindow = window
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        let backdrop = EditorBackdrop(screen: screen)
        annotationBackdrop = backdrop
        if let view = window.contentView as? AnnotationView {
            view.appDelegate = self
            attachToolbar(to: window, view: view)
        }
        // Backdrop, image, then toolbar animate in as one sequence (falls back to a plain show)
        if let toolbar = annotationToolbar {
            window.present(backdrop: backdrop, toolbar: toolbar)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The editor's toolbar: a child window under the image that drives the view and follows its state.
    private func attachToolbar(to window: NSWindow, view: AnnotationView) {
        let toolbar = AnnotationToolbar()
        toolbar.onSelectTool = { [weak view] in view?.selectedTool = $0 }
        toolbar.onSelectColor = { [weak view] in view?.setDrawingColor($0) }
        toolbar.onUndo = { [weak view] in view?.undo(nil) }
        toolbar.onRedo = { [weak view] in view?.redo(nil) }
        toolbar.onAction = { [weak view] in view?.perform($0) }
        toolbar.onClose = { [weak window] in window?.close() }

        let refresh = { [weak view, weak toolbar] in
            guard let view, let toolbar else { return }
            toolbar.update(AnnotationToolbar.State(
                tool: view.selectedTool, color: view.drawingColor,
                canUndo: view.undoManager?.canUndo ?? false, canRedo: view.undoManager?.canRedo ?? false
            ))
        }
        view.onStateChange = refresh
        // Undo availability changes with every edit (checkpoint), undo, and redo
        toolbarObservers = [.NSUndoManagerCheckpoint, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange]
            .map { name in
                NotificationCenter.default.addObserver(forName: name, object: view.undoManager, queue: .main) { _ in
                    MainActor.assumeIsolated { refresh() }
                }
            }
        refresh()
        annotationToolbar = toolbar  // placed and shown by AnnotationWindow.present
    }

    // MARK: - Helpers

    private func imageData(from cgImage: CGImage, type: UTType) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

extension AppDelegate {
    // MARK: - Recording Timer

    /// While recording, the menu bar item shows the elapsed time next to the stop icon.
    private func updateElapsedTime() {
        guard !statusItems.isEmpty, let button = recordingStatusItem.button else { return }
        guard stopActiveRecording != nil else {
            elapsedTimer?.invalidate()
            elapsedTimer = nil
            recordingStartedAt = nil
            button.title = ""
            recordingStatusItem.length = NSStatusItem.squareLength
            return
        }
        guard elapsedTimer == nil else { return }
        recordingStartedAt = Date()
        recordingStatusItem.length = NSStatusItem.variableLength
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderElapsedTime() }
        }
        RunLoop.main.add(timer, forMode: .common)  // keep ticking while a menu is open
        elapsedTimer = timer
        renderElapsedTime()
    }

    private func renderElapsedTime() {
        guard let start = recordingStartedAt else { return }
        recordingStatusItem.button?.title = " " + Self.elapsedString(Date().timeIntervalSince(start))
    }

    /// "0:07", "12:34", "1:02:03"
    static func elapsedString(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Icon Animation

    private func startIconAnimation() {
        guard iconTimer == nil else { return }
        animationFrameIndex = 0

        // Scheduled on the main run loop, so the callback is already on the main actor
        iconTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // The single icon is the stop button while recording; split, the camera can still spin
                guard let self, !self.spinnerImages.isEmpty,
                      self.stopActiveRecording == nil || self.recordingStatusItem !== self.statusItem else { return }
                self.statusItem.button?.image = self.spinnerImages[
                    self.animationFrameIndex % self.spinnerImages.count
                ]
                self.animationFrameIndex += 1
            }
        }
    }

    private func finishUpload(id: UUID, failed: Bool) {
        uploadTasks[id] = nil
        if failed {
            uploadFailed = true
        }
        if uploadTasks.isEmpty {
            iconTimer?.invalidate()
            iconTimer = nil
            updateIdleIcon()
        }
    }

    /// Shows the resting icon: a red stop button while recording (it wins over the upload spinner),
    /// red when the last upload or capture failed, normal otherwise. No-op while the upload spinner is running.
    private func updateIdleIcon() {
        let main = statusItem
        for (action, item) in statusItems {
            if stopActiveRecording != nil && item === recordingStatusItem {
                let stopIcon = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop Recording")?
                    .withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))
                stopIcon?.isTemplate = false  // menu bar images are templates (one color) unless told otherwise
                item.button?.image = stopIcon
                continue
            }
            if item === main && iconTimer != nil { continue }  // the upload spinner owns it
            let icon = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)
            guard item === main, uploadFailed || captureFailed else {
                item.button?.image = icon
                continue
            }
            let failedIcon = icon?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            failedIcon?.isTemplate = false  // templates are drawn in one color, which would drop the red
            item.button?.image = failedIcon
        }
    }
}

extension AppDelegate {
    // MARK: - Screen Recording

    /// Lets the user pick an area on the screen under the cursor and the recording switches, then
    /// records it until the menu bar icon (or the record hotkey) stops it. `isCapturing` covers the
    /// steps before recording starts.
    @available(macOS 15.0, *)
    @objc private func startRecording() {
        guard stopActiveRecording == nil, recordingPanel == nil, annotationWindow == nil,
              !isCapturing, let screen = screenWithMouse() else { return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            guard let rect = await SelectionOverlay.pickArea(on: screen) else { return }
            let options = RecordingOptions.current

            var overlays = await RecordingOverlays.show(screen: screen, area: rect, options: options)
            let tearDown = overlays.tearDown
            if options.countdown, await !overlays.frame.countdown() {
                tearDown()
                return
            }

            let recorder = ScreenRecorder(
                displayID: ScreenCapture.displayID(for: screen), sourceRect: rect,
                scale: max(screen.backingScaleFactor, 1), options: options,
                capturedWindowIDs: overlays.capturedWindowIDs
            )
            // The recorder keeps what it captured so far; stopping collects it
            recorder.onUnexpectedStop = { error in
                if let error {  // nil: stopped with the system's menu bar button, not a problem
                    self.lastError = "Recording stopped: \(error.localizedDescription)"
                    Notifier.show("Recording stopped", detail: error.localizedDescription, style: .failure)
                }
                self.stopRecording()
            }
            do {
                try await recorder.start()
            } catch {
                tearDown()
                captureFailed = true
                lastError = error.localizedDescription
                NSSound.beep()
                updateIdleIcon()
                notifyCaptureFailure(error)
                return
            }
            if recorder.microphoneUnavailable {
                overlays.notices.append("Microphone access denied — recording without the mic")
            }
            stopActiveRecording = {
                defer { tearDown() }  // after the stream stops, so the last frames still show them
                return try await recorder.stop()
            }
            if captureFailed {
                captureFailed = false
            }
            lastError = overlays.notices.isEmpty ? nil : overlays.notices.joined(separator: "\n")
            updateIdleIcon()
            if let notice = lastError {  // e.g. keystrokes without Accessibility: say so now, not in the video
                StatusHUD.show("Recording", detail: notice, symbol: "record.circle", style: .info)
            }
        }
    }

    /// Stops the recording and shows the result panel, or deletes the video when `discard` is true.
    private func stopRecording(discard: Bool = false) {
        guard let stop = stopActiveRecording else { return }
        stopActiveRecording = nil
        isCapturing = true  // until the panel shows, so a new capture can't start mid-finalize
        updateIdleIcon()
        Task {
            defer { isCapturing = false }
            do {
                let videoURL = try await stop()
                if discard {
                    try? FileManager.default.removeItem(at: videoURL)
                    StatusHUD.show("Recording discarded", symbol: "trash", style: .info)
                } else {
                    showRecordingPanel(for: videoURL)
                }
            } catch {
                guard !discard else { return }
                captureFailed = true
                lastError = "Recording failed: \(error.localizedDescription)"
                NSSound.beep()
                updateIdleIcon()
                StatusHUD.show("Recording failed", detail: error.localizedDescription, style: .failure)
            }
        }
    }

    private func showRecordingPanel(for videoURL: URL) {
        let filename = "skryn-\(Self.filenameFormatter.string(from: Date())).mp4"
        let panel = RecordingPanel(
            videoURL: videoURL,
            onAction: { [weak self] action, currentURL in
                // `currentURL` is the trimmed copy when the user trimmed
                self?.handleRecordingAction(action, videoURL: currentURL, filename: filename) ?? false
            },
            onDiscard: {}  // the original temp file is deleted when the panel closes
        )
        panel.delegate = self
        recordingPanel = panel
        recordingURL = videoURL
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        panel.present()  // sizes to the video, then grows in
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Same contract as `handleAction`: returns false to keep the panel open.
    private func handleRecordingAction(_ action: SaveAction, videoURL: URL, filename: String) -> Bool {
        let settings = OutputSettings.current
        if action == .cloud, let problem = UploadProviders.current.setupProblem {
            notifyUploadSetup(problem)
            return false
        }
        let baseName = (filename as NSString).deletingPathExtension
        let name = "\(baseName).\(settings.videoFormat.fileExtension)"
        guard settings.videoFormat != .mp4H264 || !settings.retina else {
            return deliverRecording(action, fileURL: videoURL, filename: name)  // already in its final form
        }
        // The panel deletes `videoURL` when it closes, so convert from a copy (an instant clone on APFS)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("skryn-\(UUID().uuidString).mp4")
        do {
            try FileManager.default.copyItem(at: videoURL, to: work)
        } catch {
            reportSaveFailure("Couldn't prepare the recording: \(error.localizedDescription)")
            return false
        }
        StatusHUD.show(
            "Converting to \(settings.videoFormat.title)\u{2026}", symbol: "arrow.triangle.2.circlepath", style: .info
        )
        Task {
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                let converted = try await VideoExporter.export(work, settings: settings)
                defer { if converted != work { try? FileManager.default.removeItem(at: converted) } }
                _ = deliverRecording(action, fileURL: converted, filename: name)
            } catch {
                // Never lose the recording: keep the original MP4
                if let saved = saveLocally(copyingFrom: work, filename: "\(baseName).mp4") {
                    notifySaved(saved, title: "Couldn't convert \u{2014} saved as MP4")
                }
            }
        }
        return true
    }

    /// Saves, copies, or uploads a recording file that's already in its output format.
    private func deliverRecording(_ action: SaveAction, fileURL videoURL: URL, filename: String) -> Bool {
        switch action {
        case .local:
            guard let fileURL = saveLocally(copyingFrom: videoURL, filename: filename) else { return false }
            notifySaved(fileURL)
            return true

        case .clipboard:
            // A video can't go on the pasteboard as data; copy it as a file, like Finder does.
            // The temp folder outlives the clipboard in practice and the system cleans it up.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Skryn", isDirectory: true)
            let fileURL = dir.appendingPathComponent(filename)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: videoURL, to: fileURL)
            } catch {
                reportSaveFailure("Copy failed: \(error.localizedDescription)")
                return false
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([fileURL as NSURL])
            StatusHUD.show("Video copied", detail: "Paste it into a message, document, or Finder", symbol: "doc.on.clipboard")
            return true

        case .cloud:
            if let problem = UploadProviders.current.setupProblem {
                notifyUploadSetup(problem)
                return false
            }
            guard let cachePath = UploadHistory.cacheFile(copyingFrom: videoURL, filename: filename) else {
                guard let fileURL = saveLocally(copyingFrom: videoURL, filename: filename) else { return false }
                notifySaved(fileURL, title: "Couldn't upload \u{2014} saved instead")
                return true
            }
            startCloudUpload(cachePath: cachePath, filename: filename)
            return true
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        let window = notification.object as AnyObject
        if window === annotationWindow {
            annotationToolbar?.close()
            annotationToolbar = nil
            annotationBackdrop?.close()
            annotationBackdrop = nil
            annotationWindow = nil
            toolbarObservers.forEach(NotificationCenter.default.removeObserver)
            toolbarObservers = []
        } else if window === settingsPanel {
            settingsPanel = nil
        } else if window === aboutPanel {
            aboutPanel = nil
        } else if window === recordingPanel {
            recordingPanel = nil
            if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
            recordingURL = nil
        }

        if annotationWindow == nil && settingsPanel == nil && aboutPanel == nil && recordingPanel == nil {
            NSApp.mainMenu = nil
            // Hiding the app would also hide the recording frame, keystrokes and camera bubble
            if stopActiveRecording == nil && !isCapturing {
                // Hiding would hide every Skryn window, the HUD confirming the action included
                if StatusHUD.isShowing { NSApp.deactivate() } else { NSApp.hide(nil) }
            }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
