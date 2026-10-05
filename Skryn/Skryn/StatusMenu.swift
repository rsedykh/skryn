import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The status item's right-click menu: a row of action tiles (Screenshot, Area, Record), an optional
/// notice, recent uploads with thumbnails, then Settings / About / Quit.
///
/// Item images aren't drawn in this status-item menu, so everything visual is a custom view (mouse only):
/// tiles, the "Recent Uploads" header and upload rows. Settings / About / Quit stay native, so keyboard
/// navigation and ⌘, / ⌘Q work.
@MainActor
enum StatusMenu {
    struct Shortcut { let keyCode: UInt32; let modifiers: UInt32 }  // Carbon, like Defaults.hotkey

    struct Actions {
        /// Each tile appears only when its action is set (Settings → Menu bar → Menu buttons; no Record on macOS 14)
        var screenshot: (() -> Void)?
        var areaScreenshot: (() -> Void)?
        var record: (() -> Void)?
        var copyLink: (RecentUpload) -> Void
        var saveUpload: (RecentUpload) -> Void  // ⌥-click
        var retryUpload: (RecentUpload) -> Void  // uploads without a link
        var openScreenRecordingSettings: () -> Void
        var settings: () -> Void
        var about: () -> Void
        var quit: () -> Void
    }

    struct Content {
        var screenshotShortcut: Shortcut
        var areaShortcut: Shortcut
        var recordShortcut: Shortcut?
        var recentUploads: [RecentUpload]
        var errorText: String?
        var screenRecordingPermissionMissing: Bool
    }

    /// Content width of every custom view, and their side inset (lines up with native item text).
    static let width: CGFloat = 300
    static let inset: CGFloat = 14
    static let inlineUploads = 6

    static func make(_ content: Content, actions: Actions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let tiles = tilesItem(content, actions: actions) { menu.addItem(tiles) }

        if let error = content.errorText {
            menu.addItem(.separator())
            menu.addItem(viewItem(NoticeView(text: error, symbol: "exclamationmark.triangle.fill", tint: .systemOrange)))
            if content.screenRecordingPermissionMissing {
                menu.addItem(item("Open Screen Recording Settings\u{2026}", handler: actions.openScreenRecordingSettings))
                menu.addItem(viewItem(NoticeView(
                    text: "If Skryn is already listed, remove it and add it again", symbol: nil, tint: nil
                )))
            }
        }

        if !content.recentUploads.isEmpty {
            menu.addItem(.separator())
            addUploads(content.recentUploads, to: menu, actions: actions)
        }

        menu.addItem(.separator())
        let settings = item("Settings\u{2026}", handler: actions.settings)
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(item("About Skryn", handler: actions.about))
        menu.addItem(.separator())
        let quit = item("Quit Skryn", handler: actions.quit)
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        // With the tiles switched off, the menu would open on a separator
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
        return menu
    }

    // MARK: - Tiles

    /// The enabled action tiles, or nil when they're all switched off.
    private static func tilesItem(_ content: Content, actions: Actions) -> NSMenuItem? {
        var tiles: [ActionTile] = []
        if let screenshot = actions.screenshot {
            tiles.append(ActionTile(title: "Screenshot", symbol: "camera.fill", shortcut: content.screenshotShortcut,
                                    tint: .systemBlue, action: screenshot))
        }
        if let area = actions.areaScreenshot {
            tiles.append(ActionTile(title: "Area", symbol: "rectangle.dashed", shortcut: content.areaShortcut,
                                    tint: .systemTeal, action: area))
        }
        if let record = actions.record {
            tiles.append(ActionTile(title: "Record", symbol: "record.circle", shortcut: content.recordShortcut,
                                    tint: .systemRed, action: record))
        }
        return tiles.isEmpty ? nil : viewItem(TileRow(tiles: tiles))
    }

    // MARK: - Uploads

    private static func addUploads(_ uploads: [RecentUpload], to menu: NSMenu, actions: Actions) {
        menu.addItem(viewItem(SectionHeader(title: "Recent Uploads")))
        for upload in uploads.prefix(inlineUploads) {
            menu.addItem(viewItem(UploadRow(upload: upload, actions: actions)))
        }
        guard uploads.count > inlineUploads else { return }
        let more = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for upload in uploads.dropFirst(inlineUploads) {
            submenu.addItem(viewItem(UploadRow(upload: upload, actions: actions)))
        }
        more.submenu = submenu
        menu.addItem(more)
    }

    static let ageFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func shortHost(_ link: String) -> String {
        guard let host = URL(string: link)?.host else { return link }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - Item helpers

    /// Closes the whole menu (submenus included), then runs `action` once it's gone, so a screenshot
    /// never captures the menu.
    fileprivate static func closeMenu(of view: NSView, then action: @escaping () -> Void) {
        var menu = view.enclosingMenuItem?.menu
        while let parent = menu?.supermenu { menu = parent }
        menu?.cancelTracking()
        DispatchQueue.main.async { action() }
    }

    private static func item(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let trampoline = MenuHandler(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuHandler.fire), keyEquivalent: "")
        item.target = trampoline
        item.representedObject = trampoline  // the target is weak; this keeps the handler alive
        return item
    }

    private static func viewItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }
}

/// Target for closure-based menu items.
private final class MenuHandler: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

/// A layer-backed rounded rectangle whose (semantic) color resolves at draw time, so it follows light/dark.
/// Fade it with `animator().alphaValue`.
private final class FillView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }

    init(color: NSColor, radius: CGFloat) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = color.cgColor }
}

// MARK: - Tile row

/// The menu's top row: action tiles side by side, inset to line up with the menu's text.
private final class TileRow: NSView {
    static let top: CGFloat = 6
    static let bottom: CGFloat = 6
    static let gap: CGFloat = 8
    static let tileHeight: CGFloat = 74

    init(tiles: [ActionTile]) {
        let width = StatusMenu.width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.tileHeight + Self.top + Self.bottom))
        let count = CGFloat(tiles.count)
        let tileWidth = (width - StatusMenu.inset * 2 - Self.gap * (count - 1)) / count
        for (index, tile) in tiles.enumerated() {
            tile.frame = NSRect(x: StatusMenu.inset + CGFloat(index) * (tileWidth + Self.gap), y: Self.bottom,
                                width: tileWidth, height: Self.tileHeight)
            addSubview(tile)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A Control Center–style tile: a tinted circular badge with a white symbol, the title and the global
/// shortcut, on a barely-there fill. Hover lifts the fill and brightens the badge; press deepens the
/// fill and shrinks the tile a touch. A click closes the menu first, then runs the action.
private final class ActionTile: NSView {
    private static let badgeSide: CGFloat = 30
    private let action: () -> Void
    private let fill = FillView(color: .textColor, radius: 12)
    private let glow = FillView(color: .white, radius: ActionTile.badgeSide / 2)
    private var hovered = false { didSet { refresh() } }
    private var pressed = false { didSet { refresh() } }

    init(title: String, symbol: String, shortcut: StatusMenu.Shortcut?, tint: NSColor, action: @escaping () -> Void) {
        self.action = action
        let shortcutText = shortcut.map { hotkeyDisplayString(keyCode: $0.keyCode, carbonModifiers: $0.modifiers) }
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(fill)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        let shortcutLabel = NSTextField(labelWithString: shortcutText ?? " ")
        shortcutLabel.font = .systemFont(ofSize: 10.5)
        shortcutLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [makeBadge(symbol: symbol, tint: tint), titleLabel, shortcutLabel])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.setCustomSpacing(6, after: stack.arrangedSubviews[0])
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil
        ))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityHelp(shortcutText.map { "Shortcut \($0)" })
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func makeBadge(symbol: String, tint: NSColor) -> NSView {
        let side = Self.badgeSide
        let badge = FillView(color: tint, radius: side / 2)
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: side),
            badge.heightAnchor.constraint(equalToConstant: side),
        ])
        glow.frame = NSRect(x: 0, y: 0, width: side, height: side)
        badge.addSubview(glow)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        icon.contentTintColor = .white
        icon.frame = glow.frame
        badge.addSubview(icon)
        return badge
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) { pressed = contains(event) }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        if contains(event) { perform() }
    }

    override func accessibilityPerformPress() -> Bool {
        perform()
        return true
    }

    private func contains(_ event: NSEvent) -> Bool { bounds.contains(convert(event.locationInWindow, from: nil)) }

    private func perform() { StatusMenu.closeMenu(of: self, then: action) }

    private func refresh() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            fill.animator().alphaValue = pressed ? 0.16 : hovered ? 0.11 : 0.055
            glow.animator().alphaValue = hovered ? 0.18 : 0
        }
        guard let layer else { return }
        // Scale about the center, whatever the layer's anchor point is.
        let scale: CGFloat = pressed ? 0.98 : 1
        let dx = (0.5 - layer.anchorPoint.x) * bounds.width
        let dy = (0.5 - layer.anchorPoint.y) * bounds.height
        layer.setAffineTransform(CGAffineTransform(translationX: dx, y: dy)
            .scaledBy(x: scale, y: scale).translatedBy(x: -dx, y: -dy))
    }
}

// MARK: - Uploads

/// "Recent Uploads": a small secondary label at the menu's text inset.
private final class SectionHeader: NSView {
    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: StatusMenu.width, height: 24))
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: StatusMenu.inset, y: 3, width: StatusMenu.width - StatusMenu.inset * 2, height: 15)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// One recent upload: thumbnail, file name, "host · age" (or the retry hint). Hover draws a native-looking
/// selection highlight. Click copies the link (⌥-click saves to Desktop); a failed upload retries.
private final class UploadRow: NSView {
    static let height: CGFloat = 46
    private let upload: RecentUpload
    private let actions: StatusMenu.Actions
    private let nameLabel: NSTextField
    private let detailLabel: NSTextField
    private let detailColor: NSColor
    private var hovered = false { didSet { refresh() } }

    init(upload: RecentUpload, actions: StatusMenu.Actions) {
        self.upload = upload
        self.actions = actions
        let failed = upload.cdnURL == nil
        let age = StatusMenu.ageFormatter.localizedString(for: upload.date, relativeTo: Date())
        let detail = upload.cdnURL.map { "\(StatusMenu.shortHost($0)) \u{00B7} \(age)" }
            ?? "Upload failed \u{2014} click to retry"
        detailColor = failed ? .systemOrange : .secondaryLabelColor
        nameLabel = NSTextField(labelWithString: upload.filename)
        detailLabel = NSTextField(labelWithString: detail)
        super.init(frame: NSRect(x: 0, y: 0, width: StatusMenu.width, height: Self.height))
        layoutContent(failed: failed)
        toolTip = failed ? "Click to retry the upload"
            : "Click to copy the link. \u{2325}-click to save to Desktop."
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil
        ))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(upload.filename), \(detail)")
        setAccessibilityHelp(toolTip)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func layoutContent(failed: Bool) {
        let inset = StatusMenu.inset
        let side = ThumbnailView.side
        let thumb = ThumbnailView(path: upload.cacheFilePath)
        thumb.frame = NSRect(x: inset, y: (Self.height - side) / 2, width: side, height: side)
        addSubview(thumb)
        if failed {
            let badge = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle.fill",
                                                   accessibilityDescription: nil) ?? NSImage())
            badge.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
                .applying(.init(paletteColors: [.white, .systemRed]))
            badge.frame = NSRect(x: thumb.frame.maxX - 9, y: thumb.frame.minY - 3, width: 13, height: 13)
            addSubview(badge)
        }
        let textX = thumb.frame.maxX + 10
        let textWidth = StatusMenu.width - textX - inset
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.frame = NSRect(x: textX, y: 23, width: textWidth, height: 17)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.frame = NSRect(x: textX, y: 7, width: textWidth, height: 14)
        addSubview(nameLabel)
        addSubview(detailLabel)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        perform(save: event.modifierFlags.contains(.option))
    }

    override func accessibilityPerformPress() -> Bool {
        perform(save: false)
        return true
    }

    private func perform(save: Bool) {
        let upload = upload
        let actions = actions
        StatusMenu.closeMenu(of: self) {
            if upload.cdnURL == nil {
                actions.retryUpload(upload)
            } else if save {
                actions.saveUpload(upload)
            } else {
                actions.copyLink(upload)
            }
        }
    }

    private func refresh() {
        nameLabel.textColor = hovered ? .white : .labelColor
        detailLabel.textColor = hovered ? NSColor.white.withAlphaComponent(0.75) : detailColor
        needsDisplay = true
    }
}

/// A rounded thumbnail with a hairline edge: a placeholder symbol on a quaternary fill until the
/// thumbnail is decoded, then the image crossfades in.
private final class ThumbnailView: NSView {
    static let side: CGFloat = 34
    private let placeholder = NSImageView()
    private var image: CGImage?

    init(path: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.contentsGravity = .resizeAspectFill
        let symbol = Thumbnails.isVideo(path) ? "play.rectangle" : "photo"
        placeholder.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        placeholder.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        placeholder.contentTintColor = .secondaryLabelColor
        placeholder.frame = bounds
        addSubview(placeholder)
        image = Thumbnails.load(path) { [weak self] image in self?.show(image) }
        placeholder.isHidden = image != nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.contents = image
    }

    private func show(_ image: CGImage) {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.2
        layer?.add(fade, forKey: "contents")
        self.image = image
        layer?.contents = image
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            placeholder.animator().alphaValue = 0
        }
    }
}

/// Thumbnails for upload rows, decoded off the main thread (downsampled, never full size) and cached by path.
@MainActor
private enum Thumbnails {
    // ponytail: unbounded, but upload history keeps at most 10 entries; prune if that grows
    private static var cache: [String: CGImage] = [:]

    /// The cached thumbnail, or nil after starting a decode that calls `deliver` when it's ready.
    static func load(_ path: String, deliver: @escaping @MainActor (CGImage) -> Void) -> CGImage? {
        if let cached = cache[path] { return cached }
        let video = isVideo(path)
        let pixels = Int(ThumbnailView.side * 3)
        Task {
            let image = await Task.detached {
                video ? await videoFrame(path, maxPixels: pixels) : downsampled(path, maxPixels: pixels)
            }.value
            guard let image else { return }
            cache[path] = image
            deliver(image)
        }
        return nil
    }

    static func isVideo(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        return UTType(filenameExtension: ext)?.conforms(to: .movie) ?? false
    }

    nonisolated private static func downsampled(_ path: String, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated private static func videoFrame(_ path: String, maxPixels: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        return try? await generator.image(at: .zero).image
    }
}

// MARK: - Notice

/// Small wrapped secondary text with an optional leading symbol: errors and hints.
private final class NoticeView: NSView {
    init(text: String, symbol: String?, tint: NSColor?) {
        let inset = StatusMenu.inset
        let textX = inset + (symbol == nil ? 0 : 20)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        let textWidth = StatusMenu.width - textX - inset
        label.preferredMaxLayoutWidth = textWidth
        let textHeight = ceil(label.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        super.init(frame: NSRect(x: 0, y: 0, width: StatusMenu.width, height: textHeight + 8))
        label.frame = NSRect(x: textX, y: 4, width: textWidth, height: textHeight)
        addSubview(label)
        if let symbol {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: "Warning")
                ?? NSImage())
            icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
            icon.contentTintColor = tint
            icon.frame = NSRect(x: inset, y: textHeight + 4 - 15, width: 16, height: 15)
            addSubview(icon)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
