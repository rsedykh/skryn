import AppKit
import Carbon.HIToolbox

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

    /// Single key that selects the tool (no modifiers): its label and layout-independent key code.
    /// T and the digits keep their type-at-cursor / badge-at-cursor behavior, so text and badge have none.
    var selectionKey: (label: String, keyCode: Int)? {
        switch self {
        case .arrow: ("A", kVK_ANSI_A)
        case .line: ("L", kVK_ANSI_L)
        case .rectangle: ("R", kVK_ANSI_R)
        case .ellipse: ("O", kVK_ANSI_O)
        case .blur: ("B", kVK_ANSI_B)
        case .crop: ("X", kVK_ANSI_X)
        case .text, .badge: nil
        }
    }

    /// Modifiers that draw this tool on drag whatever is selected; nil for tools without one
    var dragModifiers: NSEvent.ModifierFlags? {
        switch self {
        case .line: .shift
        case .rectangle: .command
        case .ellipse: [.shift, .command]
        case .blur: .control
        case .crop: .option
        case .arrow, .text, .badge: nil
        }
    }

    /// The drag shortcut that draws this tool whatever is selected, e.g. "⌘ Drag"
    var modifierHint: String? {
        switch self {
        case .text: return "T"
        case .badge: return "1\u{2013}0"
        default:
            guard let modifiers = dragModifiers else { return nil }
            // Apple's glyph order: ⌃ ⌥ ⇧ ⌘
            let glyphs: [(NSEvent.ModifierFlags, String)] = [
                (.control, "\u{2303}"), (.option, "\u{2325}"), (.shift, "\u{21E7}"), (.command, "\u{2318}"),
            ]
            return glyphs.filter { modifiers.contains($0.0) }.map(\.1).joined() + " Drag"
        }
    }

    /// Text and numbers are placed with a click; the rest are drawn by dragging.
    var isClickTool: Bool { self == .text || self == .badge }

    /// The tool whose selection key this is (no modifiers held)
    init?(keyCode: UInt16) {
        guard let tool = Self.allCases.first(where: { $0.selectionKey?.keyCode == Int(keyCode) }) else { return nil }
        self = tool
    }

    /// The tool a modifier-drag draws, or nil with no drawing modifiers held. Checked in this order, so
    /// ⇧⌘ is the ellipse (not the rectangle or line) and ⌥ wins over ⌘ and ⌃.
    init?(modifiers: NSEvent.ModifierFlags) {
        let precedence: [AnnotationTool] = [.ellipse, .crop, .rectangle, .blur, .line]
        guard let tool = precedence.first(where: { $0.dragModifiers.map(modifiers.contains) ?? false }) else {
            return nil
        }
        self = tool
    }

    /// The annotation a drag from `start` to `end` draws; nil for tools placed by clicking.
    func annotation(from start: CGPoint, to end: CGPoint, color: AnnotationColor) -> Annotation? {
        let rect = CGRect(spanning: start, end)
        switch self {
        case .arrow: return .arrow(from: start, to: end, color: color)
        case .line: return .line(from: start, to: end, color: color)
        case .rectangle: return .rectangle(rect: rect, color: color)
        case .ellipse: return .ellipse(rect: rect, color: color)
        case .blur: return .blur(rect: rect)
        case .crop: return .crop(rect: rect)
        case .text, .badge: return nil
        }
    }
}
