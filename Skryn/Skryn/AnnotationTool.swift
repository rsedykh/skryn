import AppKit

/// What a plain drag or click does in the screenshot editor. The toolbar picks one; holding a
/// modifier at mouse-down picks the matching tool for that drag regardless (see `init?(modifiers:)`).
enum AnnotationTool: CaseIterable {
    case arrow, line, rectangle, ellipse, text, badge, blur, crop

    var title: String {
        switch self {
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .text: "Text"
        case .badge: "Number"
        case .blur: "Blur"
        case .crop: "Crop"
        }
    }

    var symbolName: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .badge: "1.circle"
        case .blur: "checkerboard.rectangle"
        case .crop: "crop"
        }
    }

    /// Single key that selects the tool (no modifiers). T and the digits keep their
    /// type-at-cursor / badge-at-cursor behavior, so text and badge have no selection key.
    var key: Character? {
        switch self {
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .ellipse: "o"
        case .blur: "b"
        case .crop: "x"
        case .text, .badge: nil
        }
    }

    /// The drag shortcut that draws this tool whatever is selected, e.g. "⌘ Drag"
    var modifierHint: String? {
        switch self {
        case .arrow: nil
        case .line: "\u{21E7} Drag"
        case .rectangle: "\u{2318} Drag"
        case .ellipse: "\u{21E7}\u{2318} Drag"
        case .blur: "\u{2303} Drag"
        case .crop: "\u{2325} Drag"
        case .text: "T"
        case .badge: "1\u{2013}0"
        }
    }

    /// Text and numbers are placed with a click; the rest are drawn by dragging.
    var isClickTool: Bool { self == .text || self == .badge }

    /// The tool a modifier-drag draws, or nil with no drawing modifiers held.
    init?(modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) && modifiers.contains(.shift) {
            self = .ellipse
        } else if modifiers.contains(.option) {
            self = .crop
        } else if modifiers.contains(.command) {
            self = .rectangle
        } else if modifiers.contains(.control) {
            self = .blur
        } else if modifiers.contains(.shift) {
            self = .line
        } else {
            return nil
        }
    }
}
