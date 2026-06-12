import AppKit

enum AnnotationHitTestResult {
    case handle(index: Int, handle: AnnotationHandle)
    case body(index: Int)
    case none
}

enum AnnotationColor: String, Equatable {
    case red
    case blue

    var nsColor: NSColor {
        switch self {
        case .red: return .red
        case .blue: return .systemBlue
        }
    }

    var toggled: AnnotationColor { self == .red ? .blue : .red }
}

enum Annotation: Equatable {
    case arrow(from: CGPoint, to: CGPoint, color: AnnotationColor)
    case line(from: CGPoint, to: CGPoint, color: AnnotationColor)
    case rectangle(rect: CGRect, color: AnnotationColor)
    case ellipse(rect: CGRect, color: AnnotationColor)
    case crop(rect: CGRect)
    case text(origin: CGPoint, width: CGFloat, content: String, fontSize: CGFloat, color: AnnotationColor)
    case blur(rect: CGRect)
    case badge(center: CGPoint, number: Int, color: AnnotationColor)

    static let badgeRadius: CGFloat = 16
}

enum AnnotationHandle {
    case from, to
    case topLeft, topRight, bottomLeft, bottomRight
    case left, right
}

extension Annotation {
    /// The annotation's color, or nil for colorless types (crop, blur)
    var color: AnnotationColor? {
        switch self {
        case .arrow(_, _, let color), .line(_, _, let color),
             .rectangle(_, let color), .ellipse(_, let color),
             .text(_, _, _, _, let color), .badge(_, _, let color):
            return color
        case .crop, .blur:
            return nil
        }
    }

    /// Returns a copy with the given color; unchanged for colorless types
    func withColor(_ newColor: AnnotationColor) -> Annotation {
        switch self {
        case .arrow(let from, let to, _):
            return .arrow(from: from, to: to, color: newColor)
        case .line(let from, let to, _):
            return .line(from: from, to: to, color: newColor)
        case .rectangle(let rect, _):
            return .rectangle(rect: rect, color: newColor)
        case .ellipse(let rect, _):
            return .ellipse(rect: rect, color: newColor)
        case .text(let origin, let width, let content, let fontSize, _):
            return .text(origin: origin, width: width, content: content,
                         fontSize: fontSize, color: newColor)
        case .badge(let center, let number, _):
            return .badge(center: center, number: number, color: newColor)
        case .crop, .blur:
            return self
        }
    }

    var handles: [(handle: AnnotationHandle, point: CGPoint)] {
        switch self {
        case .arrow(let from, let to, _), .line(let from, let to, _):
            return [(.from, from), (.to, to)]
        case .rectangle(let rect, _), .ellipse(let rect, _), .crop(let rect), .blur(let rect):
            return [
                (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
                (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
                (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
                (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY))
            ]
        case .text(let origin, let width, let content, let fontSize, _):
            let rect = Annotation.textBoundingRect(
                origin: origin, width: width, content: content, fontSize: fontSize
            )
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
        case .arrow(let from, let to, let color):
            return handle == .from
                ? .arrow(from: point, to: to, color: color)
                : .arrow(from: from, to: point, color: color)
        case .line(let from, let to, let color):
            return handle == .from
                ? .line(from: point, to: to, color: color)
                : .line(from: from, to: point, color: color)
        case .rectangle(let rect, let color):
            let anchor = oppositeCorner(of: handle, in: rect)
            return .rectangle(rect: rectFromCorners(anchor, point), color: color)
        case .ellipse(let rect, let color):
            let anchor = oppositeCorner(of: handle, in: rect)
            return .ellipse(rect: rectFromCorners(anchor, point), color: color)
        case .crop(let rect):
            let anchor = oppositeCorner(of: handle, in: rect)
            return .crop(rect: rectFromCorners(anchor, point))
        case .blur(let rect):
            let anchor = oppositeCorner(of: handle, in: rect)
            return .blur(rect: rectFromCorners(anchor, point))
        case .text(let origin, let width, let content, let fontSize, let color):
            if handle == .left {
                let rightEdge = origin.x + width
                let newOriginX = min(point.x, rightEdge - 20)
                let newWidth = max(rightEdge - newOriginX, 20)
                return .text(
                    origin: CGPoint(x: newOriginX, y: origin.y),
                    width: newWidth, content: content, fontSize: fontSize, color: color
                )
            } else {
                let newWidth = max(point.x - origin.x, 20)
                return .text(origin: origin, width: newWidth, content: content,
                             fontSize: fontSize, color: color)
            }
        case .badge:
            return self
        }
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Annotation {
        switch self {
        case .arrow(let from, let to, let color):
            return .arrow(
                from: CGPoint(x: from.x + dx, y: from.y + dy),
                to: CGPoint(x: to.x + dx, y: to.y + dy),
                color: color
            )
        case .line(let from, let to, let color):
            return .line(
                from: CGPoint(x: from.x + dx, y: from.y + dy),
                to: CGPoint(x: to.x + dx, y: to.y + dy),
                color: color
            )
        case .rectangle(let rect, let color):
            return .rectangle(rect: rect.offsetBy(dx: dx, dy: dy), color: color)
        case .ellipse(let rect, let color):
            return .ellipse(rect: rect.offsetBy(dx: dx, dy: dy), color: color)
        case .crop(let rect):
            return .crop(rect: rect.offsetBy(dx: dx, dy: dy))
        case .blur(let rect):
            return .blur(rect: rect.offsetBy(dx: dx, dy: dy))
        case .text(let origin, let width, let content, let fontSize, let color):
            return .text(
                origin: CGPoint(x: origin.x + dx, y: origin.y + dy),
                width: width, content: content, fontSize: fontSize, color: color
            )
        case .badge(let center, let number, let color):
            return .badge(
                center: CGPoint(x: center.x + dx, y: center.y + dy),
                number: number, color: color
            )
        }
    }

    /// Returns true if the given screenshot-space point hits this annotation's body
    func bodyContains(_ point: CGPoint, hitRadius: CGFloat) -> Bool {
        switch self {
        case .arrow(let from, let to, _), .line(let from, let to, _):
            return distanceToSegment(point: point, a: from, b: to) <= hitRadius
        case .rectangle(let rect, _), .crop(let rect), .blur(let rect):
            return rect.contains(point)
        case .ellipse(let rect, _):
            let halfWidth = rect.width / 2 + hitRadius
            let halfHeight = rect.height / 2 + hitRadius
            guard halfWidth > 0, halfHeight > 0 else { return false }
            let nx = (point.x - rect.midX) / halfWidth
            let ny = (point.y - rect.midY) / halfHeight
            return nx * nx + ny * ny <= 1
        case .text(let origin, let width, let content, let fontSize, _):
            let rect = Annotation.textBoundingRect(
                origin: origin, width: width, content: content, fontSize: fontSize
            )
            return rect.contains(point)
        case .badge(let center, _, _):
            return hypot(point.x - center.x, point.y - center.y) <= Annotation.badgeRadius + hitRadius
        }
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
        let fontSize: CGFloat
    }

    private static var textHeightCache: [TextHeightCacheKey: CGFloat] = [:]

    static func textBoundingRect(
        origin: CGPoint, width: CGFloat, content: String, fontSize: CGFloat
    ) -> CGRect {
        let cacheKey = TextHeightCacheKey(width: width, content: content, fontSize: fontSize)
        let height: CGFloat
        if let cached = textHeightCache[cacheKey] {
            height = cached
        } else {
            let font = NSFont.boldSystemFont(ofSize: fontSize)
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let boundingSize = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            let textRect = (content as NSString).boundingRect(
                with: boundingSize, options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs
            )
            height = max(textRect.height, fontSize * 1.5)
            textHeightCache[cacheKey] = height
        }
        return CGRect(x: origin.x, y: origin.y, width: width, height: height)
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

    private func rectFromCorners(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }
}
