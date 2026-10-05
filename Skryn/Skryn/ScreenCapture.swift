import AppKit
import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case displayNotFound
    case failed(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Screen capture failed: Screen Recording permission is missing"
        case .displayNotFound: return "Screen capture failed: display not found"
        case .failed(let error): return "Screen capture failed: \(error.localizedDescription)"
        }
    }
}

/// An area of one screen, as the area picker returns it and the recorder and its overlays use it.
/// `rect` is in the screen's local points with a TOP-LEFT origin (the space of `SCStreamConfiguration.sourceRect`).
@MainActor
struct CaptureArea {
    let screen: NSScreen
    let rect: CGRect

    /// The whole screen
    init(screen: NSScreen) {
        self.init(screen: screen, rect: CGRect(origin: .zero, size: screen.frame.size))
    }

    init(screen: NSScreen, rect: CGRect) {
        self.screen = screen
        self.rect = rect
    }

    /// `rect` in AppKit global coordinates (bottom-left origin), for placing windows over it
    var globalFrame: CGRect { Self.globalFrame(of: rect, onScreenAt: screen.frame) }
    var displayID: CGDirectDisplayID { ScreenCapture.displayID(for: screen) }
    var scale: CGFloat { max(screen.backingScaleFactor, 1) }

    nonisolated static func globalFrame(of rect: CGRect, onScreenAt screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.minX + rect.minX, y: screenFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

struct ScreenCapture {
    /// Returns the display ID of the given screen, falling back to the main display.
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return screen.deviceDescription[key] as? CGDirectDisplayID ?? CGMainDisplayID()
    }

    static func capture(displayID targetDisplayID: CGDirectDisplayID, scale: CGFloat) async throws -> NSImage {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            print("ScreenCapture: failed to get shareable content — \(error)")
            throw CGPreflightScreenCaptureAccess() ? ScreenCaptureError.failed(error) : .permissionDenied
        }

        guard let display = content.displays.first(where: { $0.displayID == targetDisplayID }) else {
            print("ScreenCapture: display not found")
            throw ScreenCaptureError.displayNotFound
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excludedApps = content.applications.filter { $0.processID == ownPID }

        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.scalesToFit = false
        config.showsCursor = false

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            print("ScreenCapture: capture failed — \(error)")
            throw ScreenCaptureError.failed(error)
        }

        let pointSize = NSSize(width: display.width, height: display.height)
        return NSImage(cgImage: cgImage, size: pointSize)
    }

    /// Cuts `rect` (points, top-left origin, a `CaptureArea.rect`) out of a full-display capture.
    static func crop(_ image: NSImage, to rect: CGRect) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              image.size.width > 0 else { return nil }
        let scale = CGFloat(cgImage.width) / image.size.width
        let pixelRect = CGRect(
            x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale
        ).integral
        guard let cropped = cgImage.cropping(to: pixelRect) else { return nil }
        return NSImage(cgImage: cropped, size: rect.size)
    }
}
