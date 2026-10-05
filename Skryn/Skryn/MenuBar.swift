import AppKit
import UniformTypeIdentifiers

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

/// What a menu bar icon or menu tile does.
enum MenuBarAction: String, CaseIterable {
    case screenshot, area, record

    var title: String {
        switch self {
        case .screenshot: "Screenshot"
        case .area: "Screenshot of area"
        case .record: "Record screen"
        }
    }

    var symbol: String {
        switch self {
        case .screenshot: "camera"
        case .area: "rectangle.dashed"
        case .record: "record.circle"
        }
    }

    /// Recording needs macOS 15
    static var available: [MenuBarAction] {
        if #available(macOS 15.0, *) { return allCases }
        return [.screenshot, .area]
    }
}

/// Menu bar behavior (Settings → Menu Bar): which icons show, what clicking one does, and which
/// action tiles the menu starts with.
struct MenuBarSettings: Equatable {
    /// At least one; the first in `MenuBarAction` order is the main icon (upload progress, errors)
    var icons: [MenuBarAction] = [.screenshot]
    /// A click opens the menu instead of doing the icon's action (right-click always opens it)
    var clickOpensMenu = false
    var menuTiles: [MenuBarAction] = MenuBarAction.allCases

    private enum Key {
        static let icons = "menuBarIcons"
        static let clickOpensMenu = "menuBarClickOpensMenu"
        static let menuTiles = "menuBarTiles"
        static let legacyLayout = "menuBarLayout"  // "single" / "split" / "splitWithArea"
    }

    static var current: MenuBarSettings {
        get {
            let defaults = UserDefaults.standard
            var settings = MenuBarSettings()
            if let stored = defaults.stringArray(forKey: Key.icons) {
                settings.icons = stored.compactMap(MenuBarAction.init)
            } else if let legacy = defaults.string(forKey: Key.legacyLayout) {
                settings.icons = legacy == "single" ? [.screenshot]
                    : legacy == "split" ? [.screenshot, .record] : MenuBarAction.allCases
            }
            settings.clickOpensMenu = defaults.bool(forKey: Key.clickOpensMenu)
            if let stored = defaults.stringArray(forKey: Key.menuTiles) {
                settings.menuTiles = stored.compactMap(MenuBarAction.init)
            }
            return settings.normalized
        }
        set {
            let settings = newValue.normalized
            let defaults = UserDefaults.standard
            defaults.set(settings.icons.map(\.rawValue), forKey: Key.icons)
            defaults.set(settings.clickOpensMenu, forKey: Key.clickOpensMenu)
            defaults.set(settings.menuTiles.map(\.rawValue), forKey: Key.menuTiles)
            defaults.removeObject(forKey: Key.legacyLayout)
        }
    }

    /// Ordered like `MenuBarAction.allCases`, without what this Mac can't do, and never without an icon.
    var normalized: MenuBarSettings {
        var copy = self
        let available = MenuBarAction.available
        copy.icons = available.filter(icons.contains)
        if copy.icons.isEmpty { copy.icons = [.screenshot] }
        copy.menuTiles = available.filter(menuTiles.contains)
        return copy
    }
}
