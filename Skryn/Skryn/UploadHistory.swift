import Foundation

struct RecentUpload: Codable {
    let filename: String
    var cdnURL: String?
    let date: Date
    let cacheFilePath: String
}

/// Wraps RecentUpload for use as NSMenuItem.representedObject.
/// Swift structs bridged to ObjC `id` may fail `as?` casts — NSObject wrapper ensures reliable casting.
final class RecentUploadBox: NSObject {
    let value: RecentUpload
    init(_ value: RecentUpload) { self.value = value }
}

enum UploadHistory {
    private static let defaultsKey = "recentUploads"
    private static let maxEntries = 10

    static var cacheDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("Skryn/uploads")
    }

    static func recentUploads() -> [RecentUpload] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([RecentUpload].self, from: data)) ?? []
    }

    static func add(_ upload: RecentUpload) {
        var uploads = recentUploads()
        uploads.insert(upload, at: 0)
        pruneExcess(&uploads)
        save(uploads)
    }

    static func updateCDNURL(for filename: String, url: String) {
        var uploads = recentUploads()
        guard let index = uploads.firstIndex(where: { $0.filename == filename }) else { return }
        uploads[index].cdnURL = url
        save(uploads)
    }

    static func cachePNGData(_ data: Data, filename: String) -> String? {
        let dir = cacheDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filePath = dir.appendingPathComponent(filename).path
        return FileManager.default.createFile(atPath: filePath, contents: data) ? filePath : nil
    }

    /// Copies a finished file (e.g. a recording) into the cache, without loading it into memory.
    static func cacheFile(copyingFrom source: URL, filename: String) -> String? {
        let dir = cacheDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(filename)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination.path
        } catch {
            print("UploadHistory: failed to cache \(filename) — \(error.localizedDescription)")
            return nil
        }
    }

    static func cachedData(at path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    static func removeCacheFile(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Private

    private static func save(_ uploads: [RecentUpload]) {
        guard let data = try? JSONEncoder().encode(uploads) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static func pruneExcess(_ uploads: inout [RecentUpload]) {
        while uploads.count > maxEntries {
            let removed = uploads.removeLast()
            removeCacheFile(at: removed.cacheFilePath)
        }
    }
}
