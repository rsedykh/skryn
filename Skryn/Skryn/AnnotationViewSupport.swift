import AppKit

/// NSTextView with its own undo manager, isolated from the parent view's undo stack.
/// Prevents stale text-editing undo operations from crashing after the text view is removed.
final class IsolatedUndoTextView: NSTextView {
    private let _ownUndoManager = UndoManager()
    override var undoManager: UndoManager? { _ownUndoManager }

    /// Key that opened this editor (T). Its auto-repeat is swallowed so holding T
    /// a moment too long doesn't type a stray "t".
    var swallowsRepeatOfKeyCode: UInt16?

    override func keyDown(with event: NSEvent) {
        if event.isARepeat, event.keyCode == swallowsRepeatOfKeyCode { return }
        swallowsRepeatOfKeyCode = nil
        super.keyDown(with: event)
    }
}

/// The first-run hint pill over the top of the editor canvas (HUD look)
@MainActor
enum EditorHint {
    static func make() -> NSView {
        let label = NSTextField(labelWithString:
            "Drag to draw \u{00B7} \u{21E7} straightens \u{00B7} T text \u{00B7} 1\u{2013}9 numbers \u{00B7} click a mark to edit")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = HUDStyle.dimmed
        label.translatesAutoresizingMaskIntoConstraints = false
        let pill = NSView()
        pill.wantsLayer = true
        pill.appearance = NSAppearance(named: .darkAqua)
        HUDStyle.paintSurface(pill.layer, radius: 13)
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 26),
        ])
        return pill
    }
}
