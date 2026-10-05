import Foundation

struct RecentUpload: Codable {
    /// Stable identity: filenames have one-second resolution, so two uploads can share one
    let id: UUID
    let filename: String
    var cdnURL: String?
    let date: Date
    let cacheFilePath: String

    init(id: UUID = UUID(), filename: String, cdnURL: String?, date: Date, cacheFilePath: String) {
        self.id = id
        self.filename = filename
        self.cdnURL = cdnURL
        self.date = date
        self.cacheFilePath = cacheFilePath
    }

    /// History saved before uploads had an `id` still loads; each entry gets a new one.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        filename = try container.decode(String.self, forKey: .filename)
        cdnURL = try container.decodeIfPresent(String.self, forKey: .cdnURL)
        date = try container.decode(Date.self, forKey: .date)
        cacheFilePath = try container.decode(String.self, forKey: .cacheFilePath)
    }
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

    static func updateCDNURL(for id: UUID, url: String) {
        var uploads = recentUploads()
        guard let index = uploads.firstIndex(where: { $0.id == id }) else { return }
        uploads[index].cdnURL = url
        save(uploads)
    }

    /// Copies a finished file into the cache (replacing one of the same name), without loading it into memory.
    static func cacheFile(copyingFrom source: URL, filename: String) -> String? {
        let dir = cacheDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination.path
        } catch {
            print("UploadHistory: failed to cache \(filename) — \(error.localizedDescription)")
            return nil
        }
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
