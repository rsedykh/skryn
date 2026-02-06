import AppKit
import Carbon.HIToolbox
import ImageIO
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var annotationWindow: AnnotationWindow?
    private var hotKeyRef: EventHotKeyRef?
    private var settingsPanel: SettingsPanel?
    private var uploadTask: Task<Void, Never>?
    private var iconTimer: Timer?
    private var animationFrameIndex = 0
    private var uploadFailed = false
    private var lastUploadError: String?

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

        migrateModifierDefaults()
        installHotkeyHandler()
        registerHotkey()
    }

    private func migrateModifierDefaults() {
        let defaults = UserDefaults.standard
        // Already migrated
        if defaults.string(forKey: "modifierLocal") != nil { return }

        let oldMode = defaults.string(forKey: "saveMode")
        let hasKey = defaults.string(forKey: "uploadcarePublicKey") != nil

        if oldMode == "cloud" || (oldMode == nil && hasKey) {
            // Old user had cloud as default (Cmd) — preserve that mapping
            defaults.set("opt", forKey: "modifierLocal")
            defaults.set("ctrl", forKey: "modifierClipboard")
            defaults.set("cmd", forKey: "modifierCloud")
        } else {
            defaults.set("opt", forKey: "modifierLocal")
            defaults.set("cmd", forKey: "modifierClipboard")
            defaults.set("ctrl", forKey: "modifierCloud")
        }

        defaults.removeObject(forKey: "saveMode")
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showQuitMenu()
        } else {
            captureScreen()
        }
    }

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
        fileMenu.addItem(NSMenuItem(
            title: "Close", action: #selector(closeAnnotationWindow), keyEquivalent: "w"
        ))
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

    @objc private func closeAnnotationWindow() {
        annotationWindow?.close()
    }

    // MARK: - Right-Click Menu

    private func showQuitMenu() {
        let menu = NSMenu()

        if let recentItem = buildRecentUploadsMenuItem() {
            menu.addItem(recentItem)
            menu.addItem(.separator())
        }

        if let error = lastUploadError {
            let errorItem = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            errorItem.attributedTitle = NSAttributedString(
                string: error,
                attributes: [.foregroundColor: NSColor.red, .font: NSFont.menuFont(ofSize: 11)]
            )
            menu.addItem(errorItem)
            menu.addItem(.separator())
        }

        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(showSaveDestination), keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem(
            title: "Quit Skryn", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
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
    func handleAction(_ action: SaveAction, cgImage: CGImage) -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        let filename = "skryn-\(formatter.string(from: Date())).png"

        switch action {
        case .clipboard:
            let nsImage = NSImage(
                cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([nsImage])
            return true

        case .local:
            guard let pngData = pngData(from: cgImage) else {
                print("AppDelegate: failed to create PNG data")
                return true
            }
            saveLocally(pngData: pngData, filename: filename)
            return true

        case .cloud:
            guard let publicKey = UserDefaults.standard.string(forKey: "uploadcarePublicKey"),
                  !publicKey.isEmpty else {
                NSSound.beep()
                return false
            }
            guard let pngData = pngData(from: cgImage) else {
                print("AppDelegate: failed to create PNG data")
                return true
            }
            uploadToCloud(pngData: pngData, filename: filename, publicKey: publicKey)
            return true
        }
    }

    private func saveLocally(pngData: Data, filename: String) {
        let saveFolder: URL
        if let customPath = UserDefaults.standard.string(forKey: "saveFolderPath") {
            saveFolder = URL(fileURLWithPath: customPath)
        } else {
            saveFolder = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        }
        let fileURL = saveFolder.appendingPathComponent(filename)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try pngData.write(to: fileURL)
                print("Saved: \(fileURL.path)")
            } catch {
                print("AppDelegate: save failed — \(error.localizedDescription)")
            }
        }
    }

    private func uploadToCloud(pngData: Data, filename: String, publicKey: String) {
        guard let cachePath = UploadHistory.cachePNGData(pngData, filename: filename) else {
            print("AppDelegate: failed to cache PNG, falling back to local save")
            saveLocally(pngData: pngData, filename: filename)
            return
        }

        let upload = RecentUpload(filename: filename, cdnURL: nil, date: Date(), cacheFilePath: cachePath)
        UploadHistory.add(upload)

        lastUploadError = nil
        startIconAnimation()

        uploadTask?.cancel()
        uploadTask = Task {
            do {
                let cdnURL = try await UploadcareService.upload(
                    pngData: pngData, filename: filename, publicKey: publicKey
                )
                await MainActor.run {
                    UploadHistory.updateCDNURL(for: filename, url: cdnURL)
                    copyToClipboard(cdnURL)
                    stopIconAnimation(failed: false)
                    self.lastUploadError = nil
                    print("Uploaded: \(cdnURL)")
                }
            } catch {
                await MainActor.run {
                    stopIconAnimation(failed: true)
                    self.lastUploadError = "Upload failed: \(error.localizedDescription)"
                    // Fallback: save to desktop so the screenshot isn't lost
                    self.saveLocally(pngData: pngData, filename: filename)
                    print("Upload failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func uploadDroppedFile(_ url: URL) {
        guard let publicKey = UserDefaults.standard.string(forKey: "uploadcarePublicKey"),
              !publicKey.isEmpty else {
            showRejectedFileIcon()
            return
        }

        guard let fileData = try? Data(contentsOf: url) else { return }

        let filename = url.lastPathComponent
        let utType = UTType(filenameExtension: url.pathExtension) ?? .data
        let contentType = utType.preferredMIMEType ?? "application/octet-stream"

        guard let cachePath = UploadHistory.cachePNGData(fileData, filename: filename) else { return }

        let upload = RecentUpload(filename: filename, cdnURL: nil, date: Date(), cacheFilePath: cachePath)
        UploadHistory.add(upload)

        lastUploadError = nil
        startIconAnimation()

        uploadTask?.cancel()
        uploadTask = Task {
            do {
                let cdnURL = try await UploadcareService.upload(
                    fileData: fileData, filename: filename, contentType: contentType,
                    publicKey: publicKey
                )
                await MainActor.run {
                    UploadHistory.updateCDNURL(for: filename, url: cdnURL)
                    copyToClipboard(cdnURL)
                    stopIconAnimation(failed: false)
                    self.lastUploadError = nil
                    print("Uploaded: \(cdnURL)")
                }
            } catch {
                await MainActor.run {
                    stopIconAnimation(failed: true)
                    self.lastUploadError = "Upload failed: \(error.localizedDescription)"
                    print("Upload failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func showRejectedFileIcon() {
        statusItem.button?.image = NSImage(
            systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Invalid file"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.resetIcon()
        }
    }

    @objc private func retryUpload(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? RecentUploadBox,
              let publicKey = UserDefaults.standard.string(forKey: "uploadcarePublicKey"),
              !publicKey.isEmpty,
              let pngData = UploadHistory.cachedData(at: box.value.cacheFilePath) else { return }
        let upload = box.value

        lastUploadError = nil
        startIconAnimation()

        let filename = upload.filename
        uploadTask?.cancel()
        uploadTask = Task {
            do {
                let cdnURL = try await UploadcareService.upload(
                    pngData: pngData, filename: filename, publicKey: publicKey
                )
                await MainActor.run {
                    UploadHistory.updateCDNURL(for: filename, url: cdnURL)
                    copyToClipboard(cdnURL)
                    stopIconAnimation(failed: false)
                    self.lastUploadError = nil
                    print("Retry uploaded: \(cdnURL)")
                }
            } catch {
                await MainActor.run {
                    stopIconAnimation(failed: true)
                    self.lastUploadError = "Retry failed: \(error.localizedDescription)"
                    print("Retry failed: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func copyUploadURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        copyToClipboard(url)
    }

    @objc private func saveUploadToDesktop(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? RecentUploadBox,
              let data = UploadHistory.cachedData(at: box.value.cacheFilePath) else { return }
        let upload = box.value

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let fileURL = desktop.appendingPathComponent(upload.filename)
        try? data.write(to: fileURL)
        print("Saved to desktop: \(fileURL.path)")
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    // MARK: - Icon Animation

    private func startIconAnimation() {
        uploadFailed = false
        animationFrameIndex = 0

        iconTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self, !self.spinnerImages.isEmpty else { return }
            self.statusItem.button?.image = self.spinnerImages[
                self.animationFrameIndex % self.spinnerImages.count
            ]
            self.animationFrameIndex += 1
        }
    }

    private func stopIconAnimation(failed: Bool) {
        iconTimer?.invalidate()
        iconTimer = nil
        uploadFailed = failed

        if failed {
            statusItem.button?.image = NSImage(
                systemSymbolName: "camera", accessibilityDescription: "Skryn"
            )?.withSymbolConfiguration(.init(paletteColors: [.red]))
        } else {
            resetIcon()
        }
    }

    private func resetIcon() {
        statusItem.button?.image = NSImage(
            systemSymbolName: "camera", accessibilityDescription: "Skryn"
        )
    }

    // MARK: - Settings Panel

    @objc private func showSaveDestination() {
        if let existing = settingsPanel {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        NSApp.setActivationPolicy(.regular)
        installEditOnlyMenu()
        NSApp.activate(ignoringOtherApps: true)

        let panel = SettingsPanel()
        panel.delegate = self
        panel.onSettingsChanged = { [weak self] in
            self?.lastUploadError = nil
            self?.resetIcon()
            self?.registerHotkey()
        }
        settingsPanel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    private func installEditOnlyMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editMenu = NSMenu(title: "Edit")
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

        let defaults = UserDefaults.standard
        let keyCode = defaults.object(forKey: "hotkeyKeyCode") as? UInt32 ?? UInt32(kVK_ANSI_5)
        let mods = defaults.object(forKey: "hotkeyModifiers") as? UInt32 ?? UInt32(cmdKey | shiftKey)

        var hotKeyID = EventHotKeyID(signature: OSType(0x534B5259), id: 1)
        RegisterEventHotKey(
            keyCode,
            mods,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    fileprivate func hotkeyPressed() {
        if settingsPanel?.isRecordingHotkey == true {
            settingsPanel?.confirmCurrentHotkey()
            return
        }
        guard annotationWindow == nil else { return }
        captureScreen()
    }

    // MARK: - Capture

    private func captureScreen() {
        Task {
            guard let screenshot = await ScreenCapture.capture() else { return }

            await MainActor.run {
                showAnnotationWindow(with: screenshot)
            }
        }
    }

    private func showAnnotationWindow(with screenshot: NSImage) {
        guard let screen = NSScreen.main else { return }

        let window = AnnotationWindow(screen: screen, screenshot: screenshot)
        (window.contentView as? AnnotationView)?.appDelegate = self
        window.delegate = self
        annotationWindow = window
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Helpers

    private func pngData(from cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)
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
        }

        if annotationWindow == nil && settingsPanel == nil {
            NSApp.mainMenu = nil
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
        guard let urls = fileURLs(from: sender), !urls.isEmpty else { return false }
        for url in urls {
            appDelegate?.uploadDroppedFile(url)
        }
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
