import AppKit

enum AnnotationHitTestResult {
    case handle(index: Int, handle: AnnotationHandle)
    case body(index: Int)
    case none
}

enum Annotation: Equatable {
    case arrow(from: CGPoint, to: CGPoint)
    case line(from: CGPoint, to: CGPoint)
    case rectangle(rect: CGRect)
    case crop(rect: CGRect)
    case text(origin: CGPoint, width: CGFloat, content: String, fontSize: CGFloat)
}

enum AnnotationHandle {
    case from, to
    case topLeft, topRight, bottomLeft, bottomRight
    case left, right
}

extension Annotation {
    var handles: [(handle: AnnotationHandle, point: CGPoint)] {
        switch self {
        case .arrow(let from, let to), .line(let from, let to):
            return [(.from, from), (.to, to)]
        case .rectangle(let rect), .crop(let rect):
            return [
                (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
                (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
                (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
                (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY))
            ]
        case .text(let origin, let width, let content, let fontSize):
            let rect = Annotation.textBoundingRect(
                origin: origin, width: width, content: content, fontSize: fontSize
            )
            return [
                (.left, CGPoint(x: rect.minX, y: rect.midY)),
                (.right, CGPoint(x: rect.maxX, y: rect.midY))
            ]
        }
    }

    func moving(_ handle: AnnotationHandle, to point: CGPoint) -> Annotation {
        switch self {
        case .arrow(let from, let to):
            return handle == .from
                ? .arrow(from: point, to: to)
                : .arrow(from: from, to: point)
        case .line(let from, let to):
            return handle == .from
                ? .line(from: point, to: to)
                : .line(from: from, to: point)
        case .rectangle(let rect):
            let anchor = oppositeCorner(of: handle, in: rect)
            return .rectangle(rect: rectFromCorners(anchor, point))
        case .crop(let rect):
            let anchor = oppositeCorner(of: handle, in: rect)
            return .crop(rect: rectFromCorners(anchor, point))
        case .text(let origin, let width, let content, let fontSize):
            if handle == .left {
                let rightEdge = origin.x + width
                let newOriginX = min(point.x, rightEdge - 20)
                let newWidth = max(rightEdge - newOriginX, 20)
                return .text(
                    origin: CGPoint(x: newOriginX, y: origin.y),
                    width: newWidth, content: content, fontSize: fontSize
                )
            } else {
                let newWidth = max(point.x - origin.x, 20)
                return .text(origin: origin, width: newWidth, content: content, fontSize: fontSize)
            }
        }
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Annotation {
        switch self {
        case .arrow(let from, let to):
            return .arrow(
                from: CGPoint(x: from.x + dx, y: from.y + dy),
                to: CGPoint(x: to.x + dx, y: to.y + dy)
            )
        case .line(let from, let to):
            return .line(
                from: CGPoint(x: from.x + dx, y: from.y + dy),
                to: CGPoint(x: to.x + dx, y: to.y + dy)
            )
        case .rectangle(let rect):
            return .rectangle(rect: rect.offsetBy(dx: dx, dy: dy))
        case .crop(let rect):
            return .crop(rect: rect.offsetBy(dx: dx, dy: dy))
        case .text(let origin, let width, let content, let fontSize):
            return .text(
                origin: CGPoint(x: origin.x + dx, y: origin.y + dy),
                width: width, content: content, fontSize: fontSize
            )
        }
    }

    /// Returns true if the given screenshot-space point hits this annotation's body
    func bodyContains(_ point: CGPoint, hitRadius: CGFloat) -> Bool {
        switch self {
        case .arrow(let from, let to), .line(let from, let to):
            return distanceToSegment(point: point, a: from, b: to) <= hitRadius
        case .rectangle(let rect), .crop(let rect):
            return rect.contains(point)
        case .text(let origin, let width, let content, let fontSize):
            let rect = Annotation.textBoundingRect(
                origin: origin, width: width, content: content, fontSize: fontSize
            )
            return rect.contains(point)
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
