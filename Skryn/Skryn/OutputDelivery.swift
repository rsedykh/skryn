import AppKit

/// The three save actions for screenshots and recordings: save to the folder, copy, or upload.
/// Every result is first a file in its output format; only copying a screenshot skips that
/// (the clipboard always gets PNG + TIFF).
@MainActor
struct OutputDelivery {
    let problems: Problems
    let uploads: UploadCoordinator

    /// "skryn-20250102030405" (UTC), the name of every saved or uploaded file before its extension
    static func baseName(for date: Date) -> String {
        "skryn-\(filenameFormatter.string(from: date))"
    }

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter
    }()

    /// Returns false when the action can't proceed (upload not set up, a failure), so the window stays open.
    func deliver(_ action: SaveAction, screenshot shot: RenderedScreenshot) -> Bool {
        if action == .clipboard { return copy(shot.cgImage) }
        guard action != .cloud || uploads.isReady() else { return false }
        let settings = OutputSettings.current
        let ext = settings.imageFormat.fileExtension
        let scale = max(shot.pixelsPerPoint, 1)
        let pointSize = CGSize(width: CGFloat(shot.cgImage.width) / scale, height: CGFloat(shot.cgImage.height) / scale)
        let file = FileManager.default.skrynTemporaryFile(extension: ext)
        do {
            try ImageEncoder.encode(shot.cgImage, pointSize: pointSize, settings: settings).write(to: file)
        } catch {
            let failure = action == .cloud ? "Upload failed" : "Save failed"
            reportSaveFailure("\(failure): \(error.localizedDescription)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: file) }
        return deliver(action, file: file, filename: "\(Self.baseName(for: shot.captureDate)).\(ext)")
    }

    /// Saves, copies, or uploads a file already in its output format (for `.cloud`, the caller checked
    /// `uploads.isReady()`). The file stays where it is; each action makes its own copy.
    func deliver(_ action: SaveAction, file: URL, filename: String) -> Bool {
        switch action {
        case .local:
            guard let saved = Self.saveCopy(of: file, as: filename, problems: problems) else { return false }
            Self.announceSaved(saved)
            return true

        case .clipboard:
            // A video can't go on the pasteboard as data; copy it as a file, like Finder does.
            // The temp folder outlives the clipboard in practice and the system cleans it up.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Skryn", isDirectory: true)
            let copy = dir.appendingPathComponent(filename)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: file, to: copy)
            } catch {
                reportSaveFailure("Copy failed: \(error.localizedDescription)")
                return false
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([copy as NSURL])
            StatusHUD.show("Video copied", detail: "Paste it into a message, document, or Finder", symbol: "doc.on.clipboard")
            return true

        case .cloud:
            guard let cachePath = UploadHistory.cacheFile(copyingFrom: file, filename: filename) else {
                guard let saved = Self.saveCopy(of: file, as: filename, problems: problems) else { return false }
                Self.announceSaved(saved, title: "Couldn't upload \u{2014} saved instead")
                return true
            }
            uploads.start(cachePath: cachePath, filename: filename)
            return true
        }
    }

    /// PNG first for apps and browsers that prefer it; TIFF for older AppKit consumers
    private func copy(_ image: CGImage) -> Bool {
        guard let png = ImageEncoder.imageData(from: image, type: .png),
              let tiff = ImageEncoder.imageData(from: image, type: .tiff) else {
            reportSaveFailure("Copy failed: could not encode image")
            return false
        }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        StatusHUD.show("Copied", symbol: "doc.on.clipboard")
        return true
    }

    private func reportSaveFailure(_ message: String) {
        problems.report(.save, message, .hud(message))
    }

    // MARK: - Shared with uploads

    /// Copies `source` into `folder` (the save folder by default), replacing a file of the same name.
    /// Returns where it went, or nil after reporting the failure.
    static func saveCopy(
        of source: URL, as filename: String, in folder: URL = Defaults.saveFolder, problems: Problems
    ) -> URL? {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            print("Saved: \(destination.path)")
            return destination
        } catch {
            let message = "Save failed: \(error.localizedDescription)"
            problems.report(.save, message, .hud(message))
            return nil
        }
    }

    static func announceSaved(_ fileURL: URL, title: String? = nil) {
        StatusHUD.show(
            title ?? "Saved to \(fileURL.deletingLastPathComponent().lastPathComponent)",
            detail: fileURL.lastPathComponent, symbol: "square.and.arrow.down"
        )
    }
}
