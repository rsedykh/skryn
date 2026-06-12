import AppKit
import ScreenCaptureKit

struct ScreenCapture {
    /// Returns the display ID of the given screen, falling back to the main display.
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return screen.deviceDescription[key] as? CGDirectDisplayID ?? CGMainDisplayID()
    }

    static func capture(displayID targetDisplayID: CGDirectDisplayID, scale: CGFloat) async -> NSImage? {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            print("ScreenCapture: failed to get shareable content — \(error)")
            return nil
        }

        guard let display = content.displays.first(where: { $0.displayID == targetDisplayID }) else {
            print("ScreenCapture: display not found")
            return nil
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
            return nil
        }

        let pointSize = NSSize(width: display.width, height: display.height)
        return NSImage(cgImage: cgImage, size: pointSize)
    }
}
