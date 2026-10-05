import AppKit
import UniformTypeIdentifiers

// MARK: - Menu Bar Drop Target

/// Sits on top of a status item button: clicks pass through (`hitTest` returns nil), dragged files land here.
final class StatusItemDropView: NSView {
    /// The first dropped image
    var onDrop: (URL) -> Void = { _ in }
    /// Something other than images is being dragged over the icon
    var onReject: () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard allFilesAreImages(sender) else {
            onReject()
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = fileURLs(from: sender), let url = urls.first else { return false }
        onDrop(url)
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

    /// The menu's action tiles
    var tileTitle: String {
        switch self {
        case .screenshot: "Screenshot"
        case .area: "Area"
        case .record: "Record"
        }
    }

    var tileSymbol: String { self == .screenshot ? "camera.fill" : symbol }

    var tint: NSColor {
        switch self {
        case .screenshot: .systemBlue
        case .area: .systemTeal
        case .record: .systemRed
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
struct MenuBarSettings: StoredSettings {
    /// At least one; the first in `MenuBarAction` order is the main icon (upload progress, errors)
    var icons: [MenuBarAction] = [.screenshot]
    /// A click opens the menu instead of doing the icon's action (right-click always opens it)
    var clickOpensMenu = false
    var menuTiles: [MenuBarAction] = MenuBarAction.allCases

    static let didChange = Notification.Name("MenuBarSettingsDidChange")

    static var fields: [StoredField<Self>] {
        [
            .rawList("menuBarIcons", \.icons),
            .value("menuBarClickOpensMenu", \.clickOpensMenu),
            .rawList("menuBarTiles", \.menuTiles),
        ]
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
