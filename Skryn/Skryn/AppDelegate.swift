import AppKit
import Carbon.HIToolbox
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var annotationWindow: AnnotationWindow?
    private var hotKeyRef: EventHotKeyRef?
    private var settingsPanel: SettingsPanel?
    private var aboutPanel: AboutPanel?
    private var recordingPanel: RecordingPanel?
    /// The temp file shown in `recordingPanel`; deleted when the panel closes.
    private var recordingURL: URL?
    /// Stops the screen recording in progress and returns the finished file. Nil when not recording.
    /// A closure because `ScreenRecorder` is macOS 15+ and stored properties can't be availability-gated.
    private var stopActiveRecording: (() async throws -> URL)?
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Skryn")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            let dropView = StatusItemDropView(frame: button.bounds)
            dropView.appDelegate = self
            dropView.autoresizingMask = [.width, .height]
            button.addSubview(dropView)
        }

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

        if stopActiveRecording != nil {
            stopRecording()
        } else if event.type == .rightMouseUp {
            showQuitMenu()
        } else {
            captureScreen()
        }
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

    private func showQuitMenu() {
        let menu = NSMenu()

        if let recentItem = buildRecentUploadsMenuItem() {
            menu.addItem(recentItem)
            menu.addItem(.separator())
        }

        if let error = lastError {
            let errorItem = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            errorItem.attributedTitle = NSAttributedString(
                string: error,
                attributes: [.foregroundColor: NSColor.red, .font: NSFont.menuFont(ofSize: 11)]
            )
            menu.addItem(errorItem)
            if captureFailed && !CGPreflightScreenCaptureAccess() {
                let openItem = NSMenuItem(
                    title: "Open Screen Recording Settings…",
                    action: #selector(openScreenRecordingSettings), keyEquivalent: ""
                )
                openItem.target = self
                menu.addItem(openItem)
                let hint = NSMenuItem(
                    title: "If Skryn is already listed, remove it and add it again", action: nil, keyEquivalent: ""
                )
                hint.attributedTitle = NSAttributedString(
                    string: hint.title,
                    attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 11)]
                )
                menu.addItem(hint)
            }
            menu.addItem(.separator())
        }

        if #available(macOS 15.0, *) {
            let recordItem = NSMenuItem(
                title: "Record Screen…", action: #selector(startRecording), keyEquivalent: ""
            )
            recordItem.target = self
            recordItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record")
            menu.addItem(recordItem)
            menu.addItem(.separator())
        }

        let settingsItem = NSMenuItem(
            title: "Settings", action: #selector(showSaveDestination), keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(
            title: "About", action: #selector(showAbout), keyEquivalent: ""
        )
        aboutItem.target = self
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About")
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem(
            title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        ))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildRecentUploadsMenuItem() -> NSMenuItem? {
        let uploads = UploadHistory.recentUploads()
        guard !uploads.isEmpty else { return nil }

        let recentItem = NSMenuItem(title: "Recent Uploads", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()

        for upload in uploads {
            if let cdnURL = upload.cdnURL {
                let item = NSMenuItem(
                    title: upload.filename, action: #selector(copyUploadURL(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = cdnURL

                let altItem = NSMenuItem(
                    title: "Save \(upload.filename) to Desktop",
                    action: #selector(saveUploadToDesktop(_:)),
                    keyEquivalent: ""
                )
                altItem.target = self
                altItem.representedObject = RecentUploadBox(upload)
                altItem.isAlternate = true
                altItem.keyEquivalentModifierMask = .option

                recentMenu.addItem(item)
                recentMenu.addItem(altItem)
            } else {
                let item = NSMenuItem(
                    title: upload.filename, action: #selector(retryUpload(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = RecentUploadBox(upload)
                item.attributedTitle = NSAttributedString(
                    string: upload.filename,
                    attributes: [.foregroundColor: NSColor.red]
                )
                recentMenu.addItem(item)
            }
        }

        recentItem.submenu = recentMenu
        return recentItem
    }

    // MARK: - Save / Upload

    /// Performs the given save action. Returns false if the action cannot proceed
    /// (e.g. cloud upload without a key configured), so the caller can keep the window open.
    @discardableResult
    func handleAction(_ action: SaveAction, cgImage: CGImage, captureDate: Date) -> Bool {
        let filename = "skryn-\(Self.filenameFormatter.string(from: captureDate)).png"

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
            return true

        case .local:
            guard let pngData = imageData(from: cgImage, type: .png) else {
                reportSaveFailure("Save failed: could not create PNG data")
                return false
            }
            return saveLocally(pngData: pngData, filename: filename)

        case .cloud:
            guard let publicKey = Defaults.publicKey else {
                NSSound.beep()
                return false
            }
            guard let pngData = imageData(from: cgImage, type: .png) else {
                reportSaveFailure("Upload failed: could not create PNG data")
                return false
            }
            return uploadToCloud(pngData: pngData, filename: filename, publicKey: publicKey)
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

    @discardableResult
    private func saveLocally(pngData: Data, filename: String) -> Bool {
        let saveFolder = Defaults.saveFolder
        let fileURL = saveFolder.appendingPathComponent(filename)

        do {
            try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
            try pngData.write(to: fileURL)
            print("Saved: \(fileURL.path)")
            return true
        } catch {
            reportSaveFailure("Save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Copies a finished file (a cached upload or a recording) into the save folder.
    @discardableResult
    private func saveLocally(copyingFrom source: URL, filename: String) -> Bool {
        let saveFolder = Defaults.saveFolder
        do {
            try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
            let destination = saveFolder.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: destination)  // overwrite, like Data.write
            try FileManager.default.copyItem(at: source, to: destination)
            return true
        } catch {
            reportSaveFailure("Save failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func mimeType(forFilename filename: String) -> String {
        UTType(filenameExtension: (filename as NSString).pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }

    private func reportSaveFailure(_ message: String) {
        lastError = message
        NSSound.beep()
        print("AppDelegate: \(message)")
    }

    private func uploadToCloud(pngData: Data, filename: String, publicKey: String) -> Bool {
        guard let cachePath = UploadHistory.cachePNGData(pngData, filename: filename) else {
            print("AppDelegate: failed to cache PNG, falling back to local save")
            return saveLocally(pngData: pngData, filename: filename)
        }

        startCloudUpload(cachePath: cachePath, filename: filename, publicKey: publicKey)
        return true
    }

    /// Records the cached file in Recent Uploads and uploads it, saving locally if the upload fails.
    private func startCloudUpload(cachePath: String, filename: String, publicKey: String) {
        let upload = RecentUpload(filename: filename, cdnURL: nil, date: Date(), cacheFilePath: cachePath)
        UploadHistory.add(upload)
        performUpload(cachePath: cachePath, filename: filename, publicKey: publicKey, fallbackSave: true)
    }

    func openDroppedImage(_ url: URL) {
        guard annotationWindow == nil, !isCapturing else { return }
        guard let image = NSImage(contentsOf: url) else { return }
        showAnnotationWindow(with: image)
    }

    func showRejectedFileIcon() {
        statusItem.button?.image = NSImage(
            systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Invalid file"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.updateIdleIcon()
        }
    }

    @objc private func retryUpload(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? RecentUploadBox,
              let publicKey = Defaults.publicKey,
              FileManager.default.fileExists(atPath: box.value.cacheFilePath) else { return }

        performUpload(
            cachePath: box.value.cacheFilePath, filename: box.value.filename,
            publicKey: publicKey, fallbackSave: false
        )
    }

    /// Shared upload logic: animates icon, runs async upload, updates history, handles errors.
    /// If `fallbackSave` is true, saves locally on upload failure.
    private func performUpload(cachePath: String, filename: String, publicKey: String, fallbackSave: Bool) {
        let uploadID = UUID()
        let cdnBase = UploadcareService.cdnBase(forPublicKey: publicKey)
        if uploadTasks.isEmpty {
            uploadFailed = false
            captureFailed = false
            lastError = nil
        }
        startIconAnimation()

        // Task inherits the main actor from this @MainActor class
        let task = Task {
            do {
                let cdnURL = try await UploadcareService.upload(
                    fileURL: URL(fileURLWithPath: cachePath), filename: filename,
                    contentType: Self.mimeType(forFilename: filename), publicKey: publicKey, cdnBase: cdnBase
                )
                UploadHistory.updateCDNURL(for: filename, url: cdnURL)
                copyToClipboard(cdnURL)
                if !uploadFailed {
                    lastError = nil
                }
                finishUpload(id: uploadID, failed: false)
                print("Uploaded: \(cdnURL)")
            } catch {
                lastError = "Upload failed: \(error.localizedDescription)"
                if fallbackSave {
                    saveLocally(copyingFrom: URL(fileURLWithPath: cachePath), filename: filename)
                }
                finishUpload(id: uploadID, failed: true)
                print("Upload failed: \(error.localizedDescription)")
            }
        }
        uploadTasks[uploadID] = task
    }

    @objc private func copyUploadURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        copyToClipboard(url)
    }

    @objc private func saveUploadToDesktop(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? RecentUploadBox else { return }
        let upload = box.value

        let fileURL = Defaults.desktopFolder.appendingPathComponent(upload.filename)
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: upload.cacheFilePath), to: fileURL)
            print("Saved to desktop: \(fileURL.path)")
        } catch {
            NSSound.beep()
            print("AppDelegate: save to desktop failed — \(error.localizedDescription)")
        }
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    // MARK: - Icon Animation

    private func startIconAnimation() {
        guard iconTimer == nil else { return }
        animationFrameIndex = 0

        // Scheduled on the main run loop, so the callback is already on the main actor
        iconTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.spinnerImages.isEmpty, self.stopActiveRecording == nil else { return }
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
        if stopActiveRecording != nil {
            let stopIcon = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop Recording")
            statusItem.button?.image = stopIcon?.withSymbolConfiguration(.init(paletteColors: [.red]))
            return
        }
        guard iconTimer == nil else { return }
        let icon = NSImage(systemSymbolName: "camera", accessibilityDescription: "Skryn")
        statusItem.button?.image = (uploadFailed || captureFailed)
            ? icon?.withSymbolConfiguration(.init(paletteColors: [.red]))
            : icon
    }

    // MARK: - About Panel

    @objc private func showAbout() {
        if let existing = aboutPanel {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        NSApp.activate(ignoringOtherApps: true)

        let panel = AboutPanel()
        panel.delegate = self
        aboutPanel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - Settings Panel

    @objc private func showSaveDestination() {
        if let existing = settingsPanel {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        NSApp.activate(ignoringOtherApps: true)

        let panel = SettingsPanel()
        panel.delegate = self
        panel.onSettingsChanged = { [weak self] in
            guard let self else { return }
            lastError = nil
            uploadFailed = false
            captureFailed = false
            updateIdleIcon()
            registerHotkey()
        }
        settingsPanel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - Global Hotkey

    private func installHotkeyHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            delegate.hotkeyPressed()
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

    private func unregisterHotkey() {
        if let existing = hotKeyRef {
            UnregisterEventHotKey(existing)
            hotKeyRef = nil
        }
    }

    private func registerHotkey() {
        unregisterHotkey()

        let (keyCode, mods) = Defaults.hotkey

        let hotKeyID = EventHotKeyID(signature: OSType(0x534B5259), id: 1)
        let status = RegisterEventHotKey(
            keyCode,
            mods,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr || hotKeyRef == nil {
            let shortcut = hotkeyDisplayString(keyCode: keyCode, carbonModifiers: mods)
            lastError = "Hotkey \(shortcut) unavailable — it may be taken by another app"
        }
    }

    fileprivate func hotkeyPressed() {
        if settingsPanel?.isRecordingHotkey == true {
            settingsPanel?.confirmCurrentHotkey()
            return
        }
        captureScreen()
    }

    // MARK: - Capture

    /// The screen the mouse cursor is on, falling back to the main screen.
    private func screenWithMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
    }

    /// Captures the display under the cursor. `isCapturing` blocks a second capture
    /// (e.g. a double-pressed hotkey) from opening another window while this one is in flight.
    private func captureScreen() {
        guard annotationWindow == nil, !isCapturing, let screen = screenWithMouse() else { return }
        let displayID = ScreenCapture.displayID(for: screen)
        let scale = max(screen.backingScaleFactor, 1)
        isCapturing = true
        Task {
            defer { isCapturing = false }
            do {
                let screenshot = try await ScreenCapture.capture(displayID: displayID, scale: scale)
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
            }
        }
    }

    @objc private func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        if let url { NSWorkspace.shared.open(url) }
    }

    private func showAnnotationWindow(with screenshot: NSImage, on screen: NSScreen? = nil) {
        guard let screen = screen ?? screenWithMouse() else { return }

        let window = AnnotationWindow(screen: screen, screenshot: screenshot)
        (window.contentView as? AnnotationView)?.appDelegate = self
        window.delegate = self
        annotationWindow = window
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Screen Recording

    /// Lets the user pick an area on the screen under the cursor, then records it until the
    /// menu bar icon is clicked. `isCapturing` covers the area-picking step.
    @available(macOS 15.0, *)
    @objc private func startRecording() {
        guard stopActiveRecording == nil, recordingPanel == nil, annotationWindow == nil,
              !isCapturing, let screen = screenWithMouse() else { return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            guard let rect = await SelectionOverlay.pickArea(on: screen) else { return }

            let recorder = ScreenRecorder(
                displayID: ScreenCapture.displayID(for: screen), sourceRect: rect,
                scale: max(screen.backingScaleFactor, 1)
            )
            // The recorder keeps what it captured so far; stopping collects it
            recorder.onUnexpectedStop = { error in
                self.lastError = "Recording stopped: \(error.localizedDescription)"
                self.stopRecording()
            }
            do {
                try await recorder.start()
            } catch {
                captureFailed = true
                lastError = error.localizedDescription
                NSSound.beep()
                updateIdleIcon()
                return
            }
            stopActiveRecording = { try await recorder.stop() }
            if captureFailed {
                captureFailed = false
                lastError = nil
            }
            updateIdleIcon()
        }
    }

    private func stopRecording() {
        guard let stop = stopActiveRecording else { return }
        stopActiveRecording = nil
        isCapturing = true  // until the panel shows, so a new capture can't start mid-finalize
        updateIdleIcon()
        Task {
            defer { isCapturing = false }
            do {
                showRecordingPanel(for: try await stop())
            } catch {
                captureFailed = true
                lastError = "Recording failed: \(error.localizedDescription)"
                NSSound.beep()
                updateIdleIcon()
            }
        }
    }

    private func showRecordingPanel(for videoURL: URL) {
        let filename = "skryn-\(Self.filenameFormatter.string(from: Date())).mp4"
        let panel = RecordingPanel(
            videoURL: videoURL,
            onAction: { [weak self] action in
                self?.handleRecordingAction(action, videoURL: videoURL, filename: filename) ?? false
            },
            onDiscard: {}  // the temp file is deleted when the panel closes
        )
        panel.delegate = self
        recordingPanel = panel
        recordingURL = videoURL
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Same contract as `handleAction`: returns false to keep the panel open.
    private func handleRecordingAction(_ action: SaveAction, videoURL: URL, filename: String) -> Bool {
        switch action {
        case .local:
            return saveLocally(copyingFrom: videoURL, filename: filename)

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
            return true

        case .cloud:
            guard let publicKey = Defaults.publicKey else {
                NSSound.beep()
                return false
            }
            guard let cachePath = UploadHistory.cacheFile(copyingFrom: videoURL, filename: filename) else {
                return saveLocally(copyingFrom: videoURL, filename: filename)
            }
            startCloudUpload(cachePath: cachePath, filename: filename, publicKey: publicKey)
            return true
        }
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

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        let window = notification.object as AnyObject
        if window === annotationWindow {
            annotationWindow = nil
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
            NSApp.hide(nil)
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Menu Bar Drop Target

final class StatusItemDropView: NSView {
    weak var appDelegate: AppDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard allFilesAreImages(sender) else {
            appDelegate?.showRejectedFileIcon()
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = fileURLs(from: sender), let url = urls.first else { return false }
        appDelegate?.openDroppedImage(url)
        return true
    }

    private func allFilesAreImages(_ info: any NSDraggingInfo) -> Bool {
        guard let urls = fileURLs(from: info), !urls.isEmpty else { return false }
        return urls.allSatisfy { url in
            guard let utType = UTType(filenameExtension: url.pathExtension) else { return false }
            return utType.conforms(to: .image)
        }
    }

    private func fileURLs(from info: any NSDraggingInfo) -> [URL]? {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }
}
