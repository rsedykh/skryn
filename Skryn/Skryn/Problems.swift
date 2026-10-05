import AppKit

/// What went wrong, one slot per kind, shown together in the menu. Each flow sets and clears only its own
/// slot, so a hotkey conflict isn't erased by a successful upload, and the other way round.
@MainActor
final class Problems {
    /// In menu order
    enum Slot: CaseIterable {
        /// A screenshot or recording that couldn't run (red icon; may be the Screen Recording permission)
        case capture
        /// Notices about the recording in progress, or why it stopped
        case recording
        /// The last upload failed (red icon)
        case upload
        /// Saving or copying failed
        case save
        /// Shortcuts that couldn't be registered
        case hotkeys
    }

    /// How the user hears about a failure right away, besides the menu
    enum Feedback {
        case hud(String, detail: String? = nil)
        case notification(String, detail: String? = nil, action: Notifier.Action? = nil)
    }

    private var messages: [Slot: String] = [:]
    /// Called after every change (the menu bar icon follows `marksIconRed`)
    var onChange: () -> Void = {}

    subscript(slot: Slot) -> String? {
        get { messages[slot] }
        set {
            guard messages[slot] != newValue else { return }
            messages[slot] = newValue
            onChange()
        }
    }

    /// Clears every slot but `kept`.
    func clear(except kept: Set<Slot> = []) {
        let before = messages
        messages = messages.filter { kept.contains($0.key) }
        if messages != before { onChange() }
    }

    /// Everything that's wrong, one per line, or nil.
    var menuText: String? {
        let lines = Slot.allCases.compactMap { messages[$0] }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The main menu bar icon turns red after a failed capture or upload.
    var marksIconRed: Bool { messages[.capture] != nil || messages[.upload] != nil }

    /// A failed capture with Screen Recording not granted: the menu offers to open its settings.
    var screenRecordingPermissionMissing: Bool { messages[.capture] != nil && !CGPreflightScreenCaptureAccess() }

    /// Stores `message` in `slot`, beeps, and tells the user through `feedback`.
    func report(_ slot: Slot, _ message: String, _ feedback: Feedback) {
        self[slot] = message
        NSSound.beep()
        print("Skryn: \(message)")
        switch feedback {
        case .hud(let title, let detail):
            StatusHUD.show(title, detail: detail, style: .failure)
        case .notification(let title, let detail, let action):
            Notifier.show(title, detail: detail, style: .failure, action: action)
        }
    }
}
