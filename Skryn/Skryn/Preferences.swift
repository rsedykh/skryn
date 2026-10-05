import AppKit
import Carbon.HIToolbox

/// UserDefaults keys and default values shared across the app
enum Defaults {
    static let saveFolderPath = "saveFolderPath"
    static let hasLaunchedBefore = "hasLaunchedBefore"
    /// How many editors have shown the canvas hint (it stops after a few)
    static let editorHintCount = "editorHintCount"

    /// Posted when `saveFolder` is changed
    static let saveFolderDidChange = Notification.Name("SaveFolderDidChange")

    static var desktopFolder: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Where local saves go: the custom folder if one is set, otherwise the Desktop
    static var saveFolder: URL {
        get {
            guard let path = UserDefaults.standard.string(forKey: saveFolderPath) else { return desktopFolder }
            return URL(fileURLWithPath: path)
        }
        set {
            if newValue.path == desktopFolder.path {
                UserDefaults.standard.removeObject(forKey: saveFolderPath)
            } else {
                UserDefaults.standard.set(newValue.path, forKey: saveFolderPath)
            }
            NotificationCenter.default.post(name: saveFolderDidChange, object: nil)
        }
    }

    /// Drops keys earlier versions wrote and nothing reads anymore. Runs once at launch.
    static func migrate() {
        UserDefaults.standard.removeObject(forKey: "saveMode")
        UserDefaults.standard.removeObject(forKey: "uploadcareCdnBase")  // the CDN now comes from the public key
    }
}

// MARK: - Stored settings

/// A settings struct kept in UserDefaults one key per field, so a field added later falls back to its
/// default without touching the others. `current` reads and writes it; writes post `didChange`.
protocol StoredSettings: Equatable {
    init()
    static var fields: [StoredField<Self>] { get }
    static var didChange: Notification.Name { get }
    /// Clamps or repairs values; applied on every read and write
    var normalized: Self { get }
}

extension StoredSettings {
    var normalized: Self { self }

    static var current: Self {
        get {
            var settings = Self()
            for field in fields { field.load(&settings, .standard) }
            return settings.normalized
        }
        set {
            let settings = newValue.normalized
            guard settings != current else { return }
            for field in fields { field.save(settings, .standard) }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}

/// One field of a `StoredSettings` struct and its UserDefaults key. A missing or unreadable value
/// keeps the field's default.
struct StoredField<Settings> {
    let load: (inout Settings, UserDefaults) -> Void
    let save: (Settings, UserDefaults) -> Void

    /// A property-list value: Bool, Int, Double, String
    static func value<Value>(_ key: String, _ path: WritableKeyPath<Settings, Value>) -> Self {
        Self(
            load: { settings, defaults in
                if let value = defaults.object(forKey: key) as? Value { settings[keyPath: path] = value }
            },
            save: { settings, defaults in defaults.set(settings[keyPath: path], forKey: key) }
        )
    }

    /// An optional string; nil removes the key
    static func optional(_ key: String, _ path: WritableKeyPath<Settings, String?>) -> Self {
        Self(
            load: { settings, defaults in settings[keyPath: path] = defaults.string(forKey: key) },
            save: { settings, defaults in defaults.set(settings[keyPath: path], forKey: key) }
        )
    }

    /// An enum stored as its raw value
    static func raw<Value: RawRepresentable>(_ key: String, _ path: WritableKeyPath<Settings, Value>) -> Self {
        Self(
            load: { settings, defaults in
                if let raw = defaults.object(forKey: key) as? Value.RawValue, let value = Value(rawValue: raw) {
                    settings[keyPath: path] = value
                }
            },
            save: { settings, defaults in defaults.set(settings[keyPath: path].rawValue, forKey: key) }
        )
    }

    /// A list of string enums; unknown entries are skipped
    static func rawList<Value: RawRepresentable>(
        _ key: String, _ path: WritableKeyPath<Settings, [Value]>
    ) -> Self where Value.RawValue == String {
        Self(
            load: { settings, defaults in
                if let stored = defaults.stringArray(forKey: key) {
                    settings[keyPath: path] = stored.compactMap(Value.init)
                }
            },
            save: { settings, defaults in defaults.set(settings[keyPath: path].map(\.rawValue), forKey: key) }
        )
    }
}

// MARK: - Save actions

enum SaveModifier: String, CaseIterable {
    case cmd
    case opt
    case ctrl

    var label: String {
        switch self {
        case .cmd: return "\u{2318}\u{23CE}"
        case .opt: return "\u{2325}\u{23CE}"
        case .ctrl: return "\u{2303}\u{23CE}"
        }
    }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .cmd: return .command
        case .opt: return .option
        case .ctrl: return .control
        }
    }
}

/// The modifier+Return key of each save action (Settings → After Capture); never two actions on one key.
struct SaveModifiers: StoredSettings {
    var local = SaveModifier.opt
    var clipboard = SaveModifier.cmd
    var cloud = SaveModifier.ctrl

    static let didChange = Notification.Name("SaveModifiersDidChange")
    static var fields: [StoredField<Self>] {
        SaveAction.allCases.map { .raw($0.defaultsKey, $0.modifierPath) }
    }

    subscript(action: SaveAction) -> SaveModifier {
        get { self[keyPath: action.modifierPath] }
        set { self[keyPath: action.modifierPath] = newValue }
    }

    /// `action` takes `modifier`; the action that had it takes over `action`'s previous one.
    func assigning(_ modifier: SaveModifier, to action: SaveAction) -> SaveModifiers {
        var copy = self
        if let other = SaveAction.allCases.first(where: { $0 != action && self[$0] == modifier }) {
            copy[other] = self[action]
        }
        copy[action] = modifier
        return copy
    }
}

enum SaveAction: CaseIterable {
    case local, clipboard, cloud

    var defaultsKey: String {
        switch self {
        case .local: return "modifierLocal"
        case .clipboard: return "modifierClipboard"
        case .cloud: return "modifierCloud"
        }
    }

    fileprivate var modifierPath: WritableKeyPath<SaveModifiers, SaveModifier> {
        switch self {
        case .local: \.local
        case .clipboard: \.clipboard
        case .cloud: \.cloud
        }
    }

    var configuredModifier: SaveModifier { SaveModifiers.current[self] }

    /// Gives this action `modifier`, swapping with the action that had it.
    func assign(_ modifier: SaveModifier) {
        SaveModifiers.current = SaveModifiers.current.assigning(modifier, to: self)
    }

    static func action(for flags: NSEvent.ModifierFlags) -> SaveAction? {
        let relevant = flags.intersection([.command, .option, .control])
        let modifiers = SaveModifiers.current
        return allCases.first { modifiers[$0].flags == relevant }
    }

    /// The emphasized action, run by plain Return: Upload once the upload service is set up, else Save.
    /// Read it when needed: the service can be set up in Settings while a window is open.
    @MainActor static var primary: SaveAction { UploadProviders.current.setupProblem == nil ? .cloud : .local }

    /// The button title in the editor toolbar and the recording panel
    var title: String {
        switch self {
        case .local: "Save"
        case .clipboard: "Copy"
        case .cloud: "Upload"
        }
    }

    var symbolName: String {
        switch self {
        case .local: "square.and.arrow.down"
        case .clipboard: "doc.on.doc"
        case .cloud: "icloud.and.arrow.up"
        }
    }
}

// MARK: - Global shortcuts

/// A global shortcut: Carbon key code and Carbon modifier mask.
struct Hotkey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// Posted when any action's shortcut is changed
    static let didChange = Notification.Name("HotkeyDidChange")

    var displayString: String { hotkeyDisplayString(keyCode: keyCode, carbonModifiers: modifiers) }
}

extension MenuBarAction {
    /// UserDefaults keys of this action's shortcut. Stored since before area and recording existed: never rename.
    private var hotkeyKeys: (keyCode: String, modifiers: String) {
        switch self {
        case .screenshot: ("hotkeyKeyCode", "hotkeyModifiers")
        case .area: ("areaHotkeyKeyCode", "areaHotkeyModifiers")
        case .record: ("recordHotkeyKeyCode", "recordHotkeyModifiers")
        }
    }

    /// ⇧⌘5, ⇧⌘4 (taken over from macOS while Skryn runs), ⇧⌘6
    var defaultHotkey: Hotkey {
        let key = switch self {
        case .screenshot: kVK_ANSI_5
        case .area: kVK_ANSI_4
        case .record: kVK_ANSI_6
        }
        return Hotkey(keyCode: UInt32(key), modifiers: UInt32(cmdKey | shiftKey))
    }

    /// The configured shortcut, falling back to the default. Setting it posts `Hotkey.didChange`.
    var hotkey: Hotkey {
        get {
            let defaults = UserDefaults.standard
            return Hotkey(
                keyCode: defaults.object(forKey: hotkeyKeys.keyCode) as? UInt32 ?? defaultHotkey.keyCode,
                modifiers: defaults.object(forKey: hotkeyKeys.modifiers) as? UInt32 ?? defaultHotkey.modifiers
            )
        }
        nonmutating set {
            guard newValue != hotkey else { return }
            UserDefaults.standard.set(newValue.keyCode, forKey: hotkeyKeys.keyCode)
            UserDefaults.standard.set(newValue.modifiers, forKey: hotkeyKeys.modifiers)
            NotificationCenter.default.post(name: Hotkey.didChange, object: nil)
        }
    }
}
