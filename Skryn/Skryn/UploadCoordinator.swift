import AppKit
import UniformTypeIdentifiers

/// Uploads cached files with the chosen provider, keeps Recent Uploads up to date, copies the link, and
/// handles what the menu offers for a recent upload (copy the link, save to Desktop, retry).
@MainActor
final class UploadCoordinator {
    /// What happens to the file when its upload fails
    enum Fallback {
        /// A new upload: save it to the save folder instead
        case saveLocally
        /// A retry from the menu: just say so (the file stays in Recent Uploads)
        case notify
    }

    /// Called when uploads start or the last one finishes (the menu bar icon spins meanwhile)
    var onActivityChange: () -> Void = {}
    private(set) var isUploading = false {
        didSet { if isUploading != oldValue { onActivityChange() } }
    }

    private let problems: Problems
    private let showSettings: () -> Void
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(problems: Problems, showSettings: @escaping () -> Void) {
        self.problems = problems
        self.showSettings = showSettings
    }

    /// True when the chosen service is set up; otherwise says what's missing and opens Settings.
    func isReady() -> Bool {
        guard let problem = UploadProviders.current.setupProblem else { return true }
        NSSound.beep()
        StatusHUD.show("Upload isn't set up", detail: problem, style: .failure)
        showSettings()
        return false
    }

    /// Records a file already in the upload cache in Recent Uploads and uploads it.
    func start(cachePath: String, filename: String) {
        let upload = RecentUpload(filename: filename, cdnURL: nil, date: Date(), cacheFilePath: cachePath)
        UploadHistory.add(upload)
        perform(upload, fallback: .saveLocally)
    }

    func retry(_ upload: RecentUpload) {
        guard isReady() else { return }
        guard FileManager.default.fileExists(atPath: upload.cacheFilePath) else {
            StatusHUD.show("This file is no longer available", detail: upload.filename, style: .failure)
            return
        }
        perform(upload, fallback: .notify)
    }

    func copyLink(_ upload: RecentUpload) {
        guard let url = upload.cdnURL else { return }
        Self.copyToClipboard(url)
        StatusHUD.show("Link copied", detail: url, symbol: "link")
    }

    func saveToDesktop(_ upload: RecentUpload) {
        let source = URL(fileURLWithPath: upload.cacheFilePath)
        if let saved = OutputDelivery.saveCopy(of: source, as: upload.filename, in: Defaults.desktopFolder, problems: problems) {
            OutputDelivery.announceSaved(saved)
        }
    }

    // MARK: - Uploading

    private func perform(_ upload: RecentUpload, fallback: Fallback) {
        let provider = UploadProviders.current  // a Settings change mid-upload doesn't switch providers
        if tasks.isEmpty { problems[.upload] = nil }  // a new batch: the last one's failure is old news
        StatusHUD.show(
            "Uploading to \(provider.title)\u{2026}", detail: upload.filename, symbol: "icloud.and.arrow.up", style: .info
        )
        let taskID = UUID()
        // Task inherits the main actor from this @MainActor class
        tasks[taskID] = Task {
            defer {
                tasks[taskID] = nil
                isUploading = !tasks.isEmpty
            }
            do {
                let link = try await provider.upload(
                    fileURL: URL(fileURLWithPath: upload.cacheFilePath), filename: upload.filename,
                    contentType: Self.mimeType(forFilename: upload.filename)
                )
                UploadHistory.updateCDNURL(for: upload.id, url: link)
                Self.copyToClipboard(link)
                Notifier.show("Link copied", detail: link, action: .init(title: "Open") {
                    if let url = URL(string: link) { NSWorkspace.shared.open(url) }
                })
                print("Uploaded: \(link)")
            } catch {
                failed(upload, error: error, fallback: fallback)
            }
        }
        isUploading = true
    }

    private func failed(_ upload: RecentUpload, error: Error, fallback: Fallback) {
        let reason = error.localizedDescription
        let message = "Upload failed: \(reason)"
        guard fallback == .saveLocally else {
            problems.report(.upload, message, .notification("Upload failed", detail: reason))
            return
        }
        let source = URL(fileURLWithPath: upload.cacheFilePath)
        // saveCopy reports its own failure in the save slot; the notification says both
        guard let saved = OutputDelivery.saveCopy(of: source, as: upload.filename, problems: problems) else {
            problems.report(.upload, message, .notification("Upload and local save failed", detail: reason))
            return
        }
        problems.report(.upload, message, .notification(
            "Upload failed \u{2014} saved to \(saved.deletingLastPathComponent().lastPathComponent)", detail: reason,
            action: .init(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
        ))
    }

    private static func mimeType(forFilename filename: String) -> String {
        UTType(filenameExtension: (filename as NSString).pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }

    private static func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
