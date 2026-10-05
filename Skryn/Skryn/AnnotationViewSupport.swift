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
