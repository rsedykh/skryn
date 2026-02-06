import Foundation

enum Annotation {
    case arrow(from: CGPoint, to: CGPoint)
    case line(from: CGPoint, to: CGPoint)
    case rectangle(rect: CGRect)
    case crop(rect: CGRect)
}

enum AnnotationHandle {
    case from, to
    case topLeft, topRight, bottomLeft, bottomRight
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
        }
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
