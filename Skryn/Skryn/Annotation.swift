import Foundation

enum Annotation {
    case arrow(from: CGPoint, to: CGPoint)
    case rectangle(rect: CGRect)
    case crop(rect: CGRect)
}
