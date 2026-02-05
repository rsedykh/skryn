import AppKit
import ScreenCaptureKit

struct ScreenCapture {
    static func capture() async -> NSImage? {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            print("ScreenCapture: failed to get shareable content — \(error)")
            return nil
        }

        let mainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) else {
            print("ScreenCapture: main display not found")
            return nil
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excludedApps = content.applications.filter { $0.processID == ownPID }

        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = display.width * 2
        config.height = display.height * 2
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
