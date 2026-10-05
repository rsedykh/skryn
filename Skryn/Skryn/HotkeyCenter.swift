import Carbon.HIToolbox

/// The global shortcuts: one Carbon hot key per available `MenuBarAction`, read from `MenuBarAction.hotkey`.
@MainActor
final class HotkeyCenter {
    /// Why an action's shortcut isn't registered
    enum Problem: Equatable {
        /// Same shortcut as an action earlier in `MenuBarAction` order, which keeps it
        case conflict(MenuBarAction, with: MenuBarAction)
        /// Another app (or macOS) has it
        case taken(Hotkey)

        var message: String {
            switch self {
            case let .conflict(action, earlier):
                "\(Self.name(action).capitalizedFirst) shortcut matches the \(Self.name(earlier)) shortcut "
                    + "\u{2014} change one in Settings"
            case .taken(let hotkey):
                "Hotkey \(hotkey.displayString) unavailable \u{2014} it may be taken by another app"
            }
        }

        private static func name(_ action: MenuBarAction) -> String {
            switch action {
            case .screenshot: "screenshot"
            case .area: "area screenshot"
            case .record: "record"
            }
        }
    }

    private let onPress: (MenuBarAction) -> Void
    private var refs: [EventHotKeyRef] = []
    /// "SKRY"
    private static let signature = OSType(0x534B5259)

    init(onPress: @escaping (MenuBarAction) -> Void) {
        self.onPress = onPress
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { center.pressed(id: hotKeyID.id) }
            return noErr
        }
        // ponytail: never removed; the center lives as long as the app
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// Registers every available action's shortcut afresh and returns what couldn't be registered.
    func register() -> [Problem] {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        var problems: [Problem] = []
        let actions = MenuBarAction.available
        for (index, action) in actions.enumerated() {
            let hotkey = action.hotkey
            // Shortcuts saved before area/recording existed can equal their defaults (⇧⌘4, ⇧⌘6):
            // the earlier action keeps the key and the other stays in the menu
            if let earlier = actions[..<index].first(where: { $0.hotkey == hotkey }) {
                problems.append(.conflict(action, with: earlier))
                continue
            }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: Self.id(of: action))
            let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { problems.append(.taken(hotkey)) }
        }
        return problems
    }

    private static func id(of action: MenuBarAction) -> UInt32 {
        UInt32(MenuBarAction.allCases.firstIndex(of: action) ?? 0) + 1
    }

    private func pressed(id: UInt32) {
        guard let action = MenuBarAction.allCases.first(where: { Self.id(of: $0) == id }) else { return }
        onPress(action)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
