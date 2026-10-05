import AppKit
import Carbon.HIToolbox

/// Editing commands from the keyboard and the toolbar: single-key shortcuts, badges at the cursor,
/// nudging, color and width, duplicate. They act on the selection, else the hovered mark.
extension AnnotationView {
    /// Esc deselects first; with nothing selected it removes the crop
    func handleEscape() {
        if selectedIndex != nil {
            selectedIndex = nil
            return
        }
        for i in stride(from: annotations.count - 1, through: 0, by: -1) {
            if case .crop = annotations[i] { removeAnnotation(at: i) }
        }
    }

    /// Handles single-key shortcuts (no modifiers). Returns true if the key was consumed.
    func handleUnmodifiedKey(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_ANSI_U: // insert UTC timestamp at cursor
            insertTimestamp()
        case kVK_ANSI_T: // start typing text at cursor
            startTextAtCursor(keyCode: keyCode)
        case kVK_ANSI_C: // next palette color
            cycleColor()
        case kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket: // thinner / thicker
            stepWidth(thicker: Int(keyCode) == kVK_ANSI_RightBracket)
        default:
            if let tool = AnnotationTool(keyCode: keyCode) {
                selectedTool = tool
            } else if let digit = Self.digitKeyCodes[Int(keyCode)] {
                placeBadge(digit: digit)  // numbered badge at cursor
            } else {
                return false
            }
        }
        return true
    }

    /// Digits pressed within this of each other combine into one badge number
    static let badgeCombineInterval: TimeInterval = 0.5

    /// Layout-independent key codes for the digit row, 1 through 0
    private static let digitKeyCodes: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9, kVK_ANSI_0: 0,
    ]

    /// Places a numbered badge at the cursor. A digit pressed shortly after the
    /// previous one extends that badge's number instead (1, 2 → 12).
    func placeBadge(digit: Int) {
        let now = Date()
        if let last = lastBadge,
           now.timeIntervalSince(last.time) < Self.badgeCombineInterval,
           last.index < annotations.count,
           case .badge(let center, let number, let color) = annotations[last.index],
           number < 10 {
            let combined = Annotation.badge(center: center, number: number * 10 + digit, color: color)
            replaceAnnotation(at: last.index, with: combined, old: annotations[last.index])
            lastBadge = (last.index, now)
            return
        }

        guard let window = window else { return }
        let viewPoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let screenshotPoint = viewToScreenshot(viewPoint)
        addAnnotation(.badge(center: screenshotPoint, number: digit, color: drawingColor))
        lastBadge = (annotations.count - 1, now)
    }

    /// Layout-independent arrow key codes and their direction (screenshot space is y-down)
    static let nudgeOffsets: [Int: CGVector] = [
        kVK_LeftArrow: CGVector(dx: -1, dy: 0), kVK_RightArrow: CGVector(dx: 1, dy: 0),
        kVK_UpArrow: CGVector(dx: 0, dy: -1), kVK_DownArrow: CGVector(dx: 0, dy: 1),
    ]

    var isEditingText: Bool {
        if case .editingText = interactionState { return true }
        return false
    }

    /// Moves the selected (else hovered) annotation to the next palette color, or the drawing color
    /// when there's neither
    func cycleColor() {
        let target = selectedAnnotation != nil ? selectedIndex : hoveredAnnotationIndex
        if let idx = target, idx < annotations.count, let color = annotations[idx].color {
            applyColor(color.next, to: idx)
        } else {
            drawingColor = drawingColor.next
        }
    }

    /// A palette pick: recolors the selection (or the text being typed) and becomes the drawing color
    func applyColor(_ color: AnnotationColor) {
        if selectedAnnotation?.color != nil, let selectedIndex {
            applyColor(color, to: selectedIndex)
        } else {
            drawingColor = color
        }
        if case .editingText(let textView, _) = interactionState {
            styleTextView(textView)  // the text, or its label, takes the new color
            needsDisplay = true
        }
    }

    func applyColor(_ color: AnnotationColor, to index: Int) {
        drawingColor = color
        guard annotations[index].color != color else { return }
        replaceAnnotation(at: index, with: annotations[index].withColor(color), old: annotations[index])
        onStateChange?()
    }

    /// [ / ]: the selected (else hovered) mark one weight thinner or thicker, or the drawing width
    func stepWidth(thicker: Bool) {
        let target = selectedAnnotation != nil ? selectedIndex : hoveredAnnotationIndex
        if let idx = target, idx < annotations.count, let width = annotations[idx].strokeWidth {
            applyWidth(width.stepped(thicker: thicker), to: idx)
        } else {
            drawingWidth = drawingWidth.stepped(thicker: thicker)
        }
    }

    /// A width pick: rewidths the selection (if it has a line weight) and becomes the drawing width
    func applyWidth(_ width: StrokeWidth) {
        if selectedAnnotation?.strokeWidth != nil, let selectedIndex {
            applyWidth(width, to: selectedIndex)
        } else {
            drawingWidth = width
        }
    }

    func applyWidth(_ width: StrokeWidth, to index: Int) {
        drawingWidth = width
        guard annotations[index].strokeWidth != width else { return }
        replaceAnnotation(at: index, with: annotations[index].withStrokeWidth(width), old: annotations[index])
        onStateChange?()
    }

    /// ⌘D: a copy of the selection just below and to the right, which becomes the selection
    func duplicateSelection() {
        guard let annotation = selectedAnnotation else { return NSSound.beep() }
        if case .crop = annotation { return NSSound.beep() }  // only one crop at a time
        let offset = 12 / screenshotToViewScale()
        addAnnotation(annotation.offsetBy(dx: offset, dy: offset))
        selectedIndex = annotations.count - 1
    }
}
