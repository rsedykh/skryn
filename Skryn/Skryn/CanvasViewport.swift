import CoreGraphics

/// Zoom and pan of the screenshot inside the editor view (view space, y-down). Zoom 1 is the fit: the
/// image fills the view, which has its aspect. Zoomed in, the image always covers the view, so panning
/// stops at its edges.
struct CanvasViewport: Equatable {
    var viewSize: CGSize { didSet { clamp() } }
    let imageSize: CGSize
    private(set) var zoom: CGFloat = 1
    /// Where the image's top-left corner sits in the view
    private(set) var offset: CGPoint = .zero

    static let maxZoom: CGFloat = 8

    init(viewSize: CGSize, imageSize: CGSize) {
        self.viewSize = viewSize
        self.imageSize = imageSize
    }

    /// Screenshot points → view points
    var scale: CGFloat { viewSize.width / imageSize.width * zoom }
    /// Where the screenshot is drawn in the view
    var imageRect: CGRect {
        CGRect(x: offset.x, y: offset.y, width: imageSize.width * scale, height: imageSize.height * scale)
    }
    var isZoomed: Bool { zoom > 1 }

    /// Zooms to `newZoom` (clamped to fit…8×), keeping the image point under `anchor` where it is
    mutating func zoom(to newZoom: CGFloat, around anchor: CGPoint) {
        let imagePoint = CGPoint(x: (anchor.x - offset.x) / scale, y: (anchor.y - offset.y) / scale)
        zoom = min(max(newZoom, 1), Self.maxZoom)
        offset = CGPoint(x: anchor.x - imagePoint.x * scale, y: anchor.y - imagePoint.y * scale)
        clamp()
    }

    mutating func pan(by delta: CGVector) {
        offset.x += delta.dx
        offset.y += delta.dy
        clamp()
    }

    /// Back to the fit
    mutating func reset() {
        zoom = 1
        offset = .zero
    }

    private mutating func clamp() {
        let rect = imageRect
        offset.x = min(max(offset.x, viewSize.width - rect.width), 0)
        offset.y = min(max(offset.y, viewSize.height - rect.height), 0)
    }
}
