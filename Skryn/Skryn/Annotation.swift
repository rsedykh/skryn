import AppKit

enum AnnotationHitTestResult {
    case handle(index: Int, handle: AnnotationHandle)
    case body(index: Int)
    case none
}

/// The drawing palette, in toolbar order. C cycles through it.
enum AnnotationColor: String, CaseIterable, Equatable {
    case red, orange, yellow, green, blue, purple, black, white

    var nsColor: NSColor {
        switch self {
        case .red: return .red
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .black: return .black
        case .white: return .white
        }
    }

    var title: String { rawValue.capitalized }

    /// The next palette color, wrapping around (the C key)
    var next: AnnotationColor {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// Readable text on a fill of this color (badge numbers)
    var contrastingTextColor: NSColor { self == .yellow || self == .white ? .black : .white }
}

/// Line weight of arrows, lines, rectangles and ellipses. Medium is the original 3pt look.
enum StrokeWidth: Int, CaseIterable, Equatable {
    case thin, medium, thick

    var points: CGFloat {
        switch self {
        case .thin: 2
        case .medium: 3
        case .thick: 5
        }
    }

    /// Arrowhead length: 18pt at medium, scaled with the line so thin and thick stay in proportion
    var arrowHeadLength: CGFloat {
        switch self {
        case .thin: 13
        case .medium: 18
        case .thick: 25
        }
    }

    var title: String {
        switch self {
        case .thin: "Thin"
        case .medium: "Medium"
        case .thick: "Thick"
        }
    }

    /// One step thicker or thinner (the ] and [ keys), clamped at the ends
    func stepped(thicker: Bool) -> StrokeWidth {
        StrokeWidth(rawValue: rawValue + (thicker ? 1 : -1)) ?? self
    }
}

/// The typeface family of a text annotation (the system font's designs)
enum TextDesign: String, CaseIterable {
    case system, rounded, serif, mono

    var title: String {
        switch self {
        case .system: "Sans"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .mono: "Mono"
        }
    }

    var systemDesign: NSFontDescriptor.SystemDesign {
        switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .mono: .monospaced
        }
    }
}

/// How a text annotation is set: size, typeface, weight, and an optional filled label behind it.
/// The default is the original look: bold system font at 24pt, no label.
struct TextStyle: Hashable {
    var size: CGFloat = 24
    var design: TextDesign = .system
    var bold = true
    var background = false

    var font: NSFont { font(ofSize: size) }

    /// The style's font at another size (the live text view draws at the zoomed size)
    func font(ofSize size: CGFloat) -> NSFont {
        if design == .system { return bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size) }
        let base = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        guard let descriptor = base.fontDescriptor.withDesign(design.systemDesign) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Room between the text and the edge of its label (none without a label), growing with the size
    var labelPadding: CGSize {
        background ? CGSize(width: (size * 0.3).rounded(), height: (size * 0.1).rounded()) : .zero
    }

    var labelRadius: CGFloat { (size * 0.3).rounded() }

    /// The text on a fill of `color`: readable against it, like a badge's number
    func textColor(on color: AnnotationColor) -> NSColor {
        background ? color.contrastingTextColor : color.nsColor
    }
}

enum Annotation: Equatable {
    case arrow(from: CGPoint, to: CGPoint, color: AnnotationColor, width: StrokeWidth = .medium)
    case line(from: CGPoint, to: CGPoint, color: AnnotationColor, width: StrokeWidth = .medium)
    case rectangle(rect: CGRect, color: AnnotationColor, width: StrokeWidth = .medium)
    case ellipse(rect: CGRect, color: AnnotationColor, width: StrokeWidth = .medium)
    /// Translucent marker over a region, multiplied into the screenshot
    case highlight(rect: CGRect, color: AnnotationColor)
    case crop(rect: CGRect)
    case text(origin: CGPoint, width: CGFloat, content: String, style: TextStyle, color: AnnotationColor)
    case blur(rect: CGRect)
    case badge(center: CGPoint, number: Int, color: AnnotationColor)

    static let badgeRadius: CGFloat = 16

    /// Font sizes that Cmd+= / Cmd+- step through (roughly ×1.25 per step)
    static let textFontSizes: [CGFloat] = [12, 16, 20, 24, 32, 40, 48, 64, 80, 96, 128]

    /// Next size on the scale above or below `size`, clamped to the scale's ends
    static func steppedFontSize(_ size: CGFloat, larger: Bool) -> CGFloat {
        if larger {
            return textFontSizes.first { $0 > size } ?? textFontSizes.last ?? size
        }
        return textFontSizes.last { $0 < size } ?? textFontSizes.first ?? size
    }
}

enum AnnotationHandle {
    case from, to
    case topLeft, topRight, bottomLeft, bottomRight
    case left, right

    /// The handle that stays put while this one is dragged (what Shift constrains against)
    var opposite: AnnotationHandle? {
        switch self {
        case .from: .to
        case .to: .from
        case .topLeft: .bottomRight
        case .bottomRight: .topLeft
        case .topRight: .bottomLeft
        case .bottomLeft: .topRight
        case .left, .right: nil
        }
    }
}

extension Annotation {
    /// The annotation's color, or nil for colorless types (crop, blur)
    var color: AnnotationColor? {
        switch self {
        case .arrow(_, _, let color, _), .line(_, _, let color, _),
             .rectangle(_, let color, _), .ellipse(_, let color, _), .highlight(_, let color),
             .text(_, _, _, _, let color), .badge(_, _, let color):
            return color
        case .crop, .blur:
            return nil
        }
    }

    /// Returns a copy with the given color; unchanged for colorless types
    func withColor(_ newColor: AnnotationColor) -> Annotation {
        switch self {
        case .arrow(let from, let to, _, let width):
            return .arrow(from: from, to: to, color: newColor, width: width)
        case .line(let from, let to, _, let width):
            return .line(from: from, to: to, color: newColor, width: width)
        case .rectangle(let rect, _, let width):
            return .rectangle(rect: rect, color: newColor, width: width)
        case .ellipse(let rect, _, let width):
            return .ellipse(rect: rect, color: newColor, width: width)
        case .highlight(let rect, _):
            return .highlight(rect: rect, color: newColor)
        case .text(let origin, let width, let content, let style, _):
            return .text(origin: origin, width: width, content: content, style: style, color: newColor)
        case .badge(let center, let number, _):
            return .badge(center: center, number: number, color: newColor)
        case .crop, .blur:
            return self
        }
    }

    /// The line weight, or nil for annotations without one
    var strokeWidth: StrokeWidth? {
        switch self {
        case .arrow(_, _, _, let width), .line(_, _, _, let width),
             .rectangle(_, _, let width), .ellipse(_, _, let width):
            return width
        case .highlight, .crop, .text, .blur, .badge:
            return nil
        }
    }

    /// Returns a copy with the given line weight; unchanged for annotations without one
    func withStrokeWidth(_ width: StrokeWidth) -> Annotation {
        switch self {
        case .arrow(let from, let to, let color, _): .arrow(from: from, to: to, color: color, width: width)
        case .line(let from, let to, let color, _): .line(from: from, to: to, color: color, width: width)
        case .rectangle(let rect, let color, _): .rectangle(rect: rect, color: color, width: width)
        case .ellipse(let rect, let color, _): .ellipse(rect: rect, color: color, width: width)
        case .highlight, .crop, .text, .blur, .badge: self
        }
    }

    var handles: [(handle: AnnotationHandle, point: CGPoint)] {
        switch self {
        case .arrow(let from, let to, _, _), .line(let from, let to, _, _):
            return [(.from, from), (.to, to)]
        case .rectangle(let rect, _, _), .ellipse(let rect, _, _), .highlight(let rect, _), .crop(let rect),
             .blur(let rect):
            return [
                (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
                (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
                (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
                (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY))
            ]
        case .text(let origin, let width, let content, let style, _):
            let rect = Annotation.textFrame(origin: origin, width: width, content: content, style: style)
            return [
                (.left, CGPoint(x: rect.minX, y: rect.midY)),
                (.right, CGPoint(x: rect.maxX, y: rect.midY))
            ]
        case .badge:
            return []
        }
    }

    func moving(_ handle: AnnotationHandle, to point: CGPoint) -> Annotation {
        switch self {
        case .arrow(let from, let to, let color, let width):
            return handle == .from
                ? .arrow(from: point, to: to, color: color, width: width)
                : .arrow(from: from, to: point, color: color, width: width)
        case .line(let from, let to, let color, let width):
            return handle == .from
                ? .line(from: point, to: to, color: color, width: width)
                : .line(from: from, to: point, color: color, width: width)
        case .rectangle(let rect, let color, let width):
            let anchor = oppositeCorner(of: handle, in: rect)
            return .rectangle(rect: CGRect(spanning: anchor, point), color: color, width: width)
        case .ellipse(let rect, let color, let width):
            let anchor = oppositeCorner(of: handle, in: rect)
            return .ellipse(rect: CGRect(spanning: anchor, point), color: color, width: width)
        case .highlight(let rect, let color):
            let anchor = oppositeCorner(of: handle, in: rect)
            return .highlight(rect: CGRect(spanning: anchor, point), color: color)
        case .crop(let rect):
            let anchor = oppositeCorner(of: handle, in: rect)
            return .crop(rect: CGRect(spanning: anchor, point))
        case .blur(let rect):
            let anchor = oppositeCorner(of: handle, in: rect)
            return .blur(rect: CGRect(spanning: anchor, point))
        case .text(let origin, let width, let content, let style, let color):
            if handle == .left {
                let rightEdge = origin.x + width
                let newOriginX = min(point.x, rightEdge - 20)
                let newWidth = max(rightEdge - newOriginX, 20)
                return .text(
                    origin: CGPoint(x: newOriginX, y: origin.y),
                    width: newWidth, content: content, style: style, color: color
                )
            } else {
                let newWidth = max(point.x - origin.x, 20)
                return .text(origin: origin, width: newWidth, content: content,
                             style: style, color: color)
            }
        case .badge:
            return self
        }
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Annotation {
        switch self {
        case .arrow(let from, let to, let color, let width):
            return .arrow(
                from: CGPoint(x: from.x + dx, y: from.y + dy),
                to: CGPoint(x: to.x + dx, y: to.y + dy),
                color: color, width: width
            )
        case .line(let from, let to, let color, let width):
            return .line(
                from: CGPoint(x: from.x + dx, y: from.y + dy),
                to: CGPoint(x: to.x + dx, y: to.y + dy),
                color: color, width: width
            )
        case .rectangle(let rect, let color, let width):
            return .rectangle(rect: rect.offsetBy(dx: dx, dy: dy), color: color, width: width)
        case .ellipse(let rect, let color, let width):
            return .ellipse(rect: rect.offsetBy(dx: dx, dy: dy), color: color, width: width)
        case .highlight(let rect, let color):
            return .highlight(rect: rect.offsetBy(dx: dx, dy: dy), color: color)
        case .crop(let rect):
            return .crop(rect: rect.offsetBy(dx: dx, dy: dy))
        case .blur(let rect):
            return .blur(rect: rect.offsetBy(dx: dx, dy: dy))
        case .text(let origin, let width, let content, let style, let color):
            return .text(
                origin: CGPoint(x: origin.x + dx, y: origin.y + dy),
                width: width, content: content, style: style, color: color
            )
        case .badge(let center, let number, let color):
            return .badge(
                center: CGPoint(x: center.x + dx, y: center.y + dy),
                number: number, color: color
            )
        }
    }

    /// Whether `point` is on the annotation: within `hitRadius` of its outline (beyond the stroke's
    /// half-width) for lines, arrows, shapes and badges; anywhere inside for text and fills.
    func bodyContains(_ point: CGPoint, hitRadius: CGFloat) -> Bool {
        hitPrecision(at: point, tolerance: hitRadius) != nil
    }

    private func distanceToSegment(point: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let lengthSq = abx * abx + aby * aby
        if lengthSq == 0 { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * abx + (point.y - a.y) * aby) / lengthSq))
        let closestX = a.x + t * abx
        let closestY = a.y + t * aby
        return hypot(point.x - closestX, point.y - closestY)
    }

    private struct TextHeightCacheKey: Hashable {
        let width: CGFloat
        let content: String
        let style: TextStyle
    }

    private static var textHeightCache: [TextHeightCacheKey: CGFloat] = [:]

    /// Where the text itself is laid out: `origin` is its top-left, at least one and a half lines tall
    static func textBoundingRect(
        origin: CGPoint, width: CGFloat, content: String, style: TextStyle
    ) -> CGRect {
        let cacheKey = TextHeightCacheKey(width: width, content: content, style: style)
        let height: CGFloat
        if let cached = textHeightCache[cacheKey] {
            height = cached
        } else {
            let attrs: [NSAttributedString.Key: Any] = [.font: style.font]
            let boundingSize = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            let textRect = (content as NSString).boundingRect(
                with: boundingSize, options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs
            )
            height = max(textRect.height, style.size * 1.5)
            textHeightCache[cacheKey] = height
        }
        return CGRect(x: origin.x, y: origin.y, width: width, height: height)
    }

    /// The text's whole extent: its layout rect plus the label around it, if it has one. Hit testing,
    /// handles and the label's fill all use this.
    static func textFrame(origin: CGPoint, width: CGFloat, content: String, style: TextStyle) -> CGRect {
        let padding = style.labelPadding
        return textBoundingRect(origin: origin, width: width, content: content, style: style)
            .insetBy(dx: -padding.width, dy: -padding.height)
    }

    private func oppositeCorner(of handle: AnnotationHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight: return CGPoint(x: rect.minX, y: rect.minY)
        default: return CGPoint(x: rect.midX, y: rect.midY)
        }
    }
}

extension CGRect {
    /// The rect with `a` and `b` as opposite corners, in either order
    init(spanning a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

extension Annotation {
    /// How directly a point at this annotation hits it, for picking among overlapping ones: outlines
    /// (lines, arrows, shape edges, badges) by distance to the stroke; text, then area fills (blur,
    /// highlight) by area, so a small mark inside a big fill is the one you get.
    enum HitPrecision: Comparable {
        case stroke(distance: CGFloat)
        case text(area: CGFloat)
        case fill(area: CGFloat)
    }

    /// The precision of a hit at `point`, or nil if `point` isn't on the annotation. Strokes get
    /// `tolerance` beyond their visible half-width.
    func hitPrecision(at point: CGPoint, tolerance: CGFloat) -> HitPrecision? {
        let slack = tolerance + (strokeWidth?.points ?? StrokeWidth.medium.points) / 2
        switch self {
        case .arrow(let from, let to, _, _), .line(let from, let to, _, _):
            let distance = distanceToSegment(point: point, a: from, b: to)
            return distance <= slack ? .stroke(distance: distance) : nil
        case .rectangle(let rect, _, _), .crop(let rect):
            let distance = Self.distanceToBorder(of: rect, from: point)
            return distance <= slack ? .stroke(distance: distance) : nil
        case .ellipse(let rect, _, _):
            let distance = Self.distanceToEllipse(in: rect, from: point)
            return distance <= slack ? .stroke(distance: distance) : nil
        case .badge(let center, _, _):
            let distance = max(0, hypot(point.x - center.x, point.y - center.y) - Annotation.badgeRadius)
            return distance <= tolerance ? .stroke(distance: distance) : nil
        case .text(let origin, let width, let content, let style, _):
            let frame = Annotation.textFrame(origin: origin, width: width, content: content, style: style)
            return frame.contains(point) ? .text(area: frame.width * frame.height) : nil
        case .blur(let rect), .highlight(let rect, _):
            return rect.contains(point) ? .fill(area: rect.width * rect.height) : nil
        }
    }

    private static func distanceToBorder(of rect: CGRect, from point: CGPoint) -> CGFloat {
        if rect.contains(point) {
            return min(point.x - rect.minX, rect.maxX - point.x, point.y - rect.minY, rect.maxY - point.y)
        }
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    /// Approximate distance to the outline of the ellipse inscribed in `rect` (exact on the axes)
    private static func distanceToEllipse(in rect: CGRect, from point: CGPoint) -> CGFloat {
        let a = rect.width / 2, b = rect.height / 2
        guard a > 0, b > 0 else { return hypot(point.x - rect.midX, point.y - rect.midY) }
        let nx = (point.x - rect.midX) / a, ny = (point.y - rect.midY) / b
        let r = hypot(nx, ny)
        guard r > 0 else { return min(a, b) }
        // The outline point on the same ray from the center
        let ox = rect.midX + nx / r * a, oy = rect.midY + ny / r * b
        return hypot(point.x - ox, point.y - oy)
    }
}

extension Array where Element == Annotation {
    /// What a press at `point` grabs, the way people expect:
    /// 1. a handle of a `preferred` annotation (selected, then hovered): the handles you can see
    /// 2. the `selection`, if it's under the point at all, so it stays grabbable among overlapping marks,
    ///    else the most precisely hit body (`bodyCandidates`): the nearest outline, else the smallest fill;
    ///    on that mark's own handle, the handle
    /// 3. any annotation's handle, topmost first (grabbing a corner from just outside)
    func hitTest(
        _ point: CGPoint, handleRadius: CGFloat, bodyRadius: CGFloat,
        preferring preferred: [Int] = [], selection: Int? = nil
    ) -> AnnotationHitTestResult {
        for index in preferred where indices.contains(index) {
            if let handle = nearestHandle(of: index, to: point, within: handleRadius) {
                return .handle(index: index, handle: handle)
            }
        }
        let candidates = bodyCandidates(at: point, tolerance: bodyRadius)
        let picked = selection.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates.first
        if let picked {
            // On the picked mark's own handle (e.g. an arrow's tip), grab the handle
            if let handle = nearestHandle(of: picked, to: point, within: handleRadius) {
                return .handle(index: picked, handle: handle)
            }
            return .body(index: picked)
        }
        for index in indices.reversed() {
            if let handle = nearestHandle(of: index, to: point, within: handleRadius) {
                return .handle(index: index, handle: handle)
            }
        }
        return .none
    }

    /// Indices of every annotation under `point`, best hit first (ties go to the topmost). Clicking
    /// the selection again steps down this list, to reach marks underneath.
    func bodyCandidates(at point: CGPoint, tolerance: CGFloat) -> [Int] {
        indices.reversed()
            .compactMap { index in self[index].hitPrecision(at: point, tolerance: tolerance).map { (index, $0) } }
            .enumerated()
            .sorted { lhs, rhs in lhs.element.1 == rhs.element.1 ? lhs.offset < rhs.offset : lhs.element.1 < rhs.element.1 }
            .map(\.element.0)
    }

    private func nearestHandle(of index: Int, to point: CGPoint, within radius: CGFloat) -> AnnotationHandle? {
        self[index].handles
            .map { (handle: $0.handle, distance: hypot(point.x - $0.point.x, point.y - $0.point.y)) }
            .filter { $0.distance <= radius }
            .min { $0.distance < $1.distance }?
            .handle
    }
}
