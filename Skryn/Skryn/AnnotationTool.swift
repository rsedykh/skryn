import AppKit
import Carbon.HIToolbox

/// What a plain drag or click does in the screenshot editor. The toolbar picks one; holding a
/// modifier at mouse-down picks the matching tool for that drag regardless (see `init?(modifiers:)`).
enum AnnotationTool: CaseIterable {
    case arrow, line, rectangle, ellipse, text, badge, highlight, blur, crop

    var title: String {
        switch self {
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .text: "Text"
        case .badge: "Number"
        case .highlight: "Highlight"
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
        case .highlight: "highlighter"
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
        case .highlight: ("H", kVK_ANSI_H)
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
        case .arrow, .text, .badge, .highlight: nil
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
    /// `width` applies to the stroked shapes (arrow, line, rectangle, ellipse).
    func annotation(
        from start: CGPoint, to end: CGPoint, color: AnnotationColor, width: StrokeWidth = .medium
    ) -> Annotation? {
        let rect = CGRect(spanning: start, end)
        switch self {
        case .arrow: return .arrow(from: start, to: end, color: color, width: width)
        case .line: return .line(from: start, to: end, color: color, width: width)
        case .rectangle: return .rectangle(rect: rect, color: color, width: width)
        case .ellipse: return .ellipse(rect: rect, color: color, width: width)
        case .highlight: return .highlight(rect: rect, color: color)
        case .blur: return .blur(rect: rect)
        case .crop: return .crop(rect: rect)
        case .text, .badge: return nil
        }
    }

    /// Lines and arrows: Shift snaps them to 45° steps; everything else to squares and circles
    var constrainsAngle: Bool { self == .arrow || self == .line }

    /// `point` adjusted for Shift held while dragging from `anchor`: snapped to the nearest 45° keeping
    /// its length (`angular`), or pushed out to a square with the longer side.
    static func constrained(_ point: CGPoint, from anchor: CGPoint, angular: Bool) -> CGPoint {
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        if angular {
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let length = hypot(dx, dy)
            return CGPoint(x: anchor.x + (length * cos(angle)).rounded(), y: anchor.y + (length * sin(angle)).rounded())
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: anchor.x + (dx < 0 ? -side : side), y: anchor.y + (dy < 0 ? -side : side))
    }
}
