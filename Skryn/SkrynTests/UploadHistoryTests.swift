import XCTest
@testable import Skryn

final class UploadHistoryTests: XCTestCase {

    private let defaultsKey = "recentUploads"
    private var savedDefaults: Data?

    override func setUp() {
        super.setUp()
        savedDefaults = UserDefaults.standard.data(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    override func tearDown() {
        if let saved = savedDefaults {
            UserDefaults.standard.set(saved, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        super.tearDown()
    }

    // MARK: - recentUploads

    func testRecentUploads_emptyByDefault() {
        XCTAssertEqual(UploadHistory.recentUploads().count, 0)
    }

    func testRecentUploads_corruptedData_returnsEmpty() {
        UserDefaults.standard.set(Data("not json".utf8), forKey: defaultsKey)
        XCTAssertEqual(UploadHistory.recentUploads().count, 0)
    }

    // MARK: - add

    func testAdd_insertsAtFront() {
        UploadHistory.add(makeUpload(filename: "first.png"))
        UploadHistory.add(makeUpload(filename: "second.png"))

        let uploads = UploadHistory.recentUploads()
        XCTAssertEqual(uploads.count, 2)
        XCTAssertEqual(uploads[0].filename, "second.png")
        XCTAssertEqual(uploads[1].filename, "first.png")
    }

    func testAdd_prunesBeyond10() {
        for idx in 0..<12 {
            UploadHistory.add(makeUpload(filename: "file\(idx).png"))
        }

        let uploads = UploadHistory.recentUploads()
        XCTAssertEqual(uploads.count, 10)
        XCTAssertEqual(uploads[0].filename, "file11.png")
        XCTAssertEqual(uploads[9].filename, "file2.png")
    }

    // MARK: - updateCDNURL

    func testUpdateCDNURL_updatesCorrectEntry() {
        let first = makeUpload(filename: "a.png")
        UploadHistory.add(first)
        UploadHistory.add(makeUpload(filename: "b.png"))

        UploadHistory.updateCDNURL(for: first.id, url: "https://cdn.example.com/a")

        let updated = UploadHistory.recentUploads().first { $0.filename == "a.png" }
        XCTAssertEqual(updated?.cdnURL, "https://cdn.example.com/a")
    }

    func testUpdateCDNURL_sameFilename_updatesOnlyThatUpload() {
        let first = makeUpload(filename: "same.png")
        UploadHistory.add(first)
        UploadHistory.add(makeUpload(filename: "same.png"))

        UploadHistory.updateCDNURL(for: first.id, url: "https://cdn.example.com/a")

        let uploads = UploadHistory.recentUploads()
        XCTAssertNil(uploads[0].cdnURL)
        XCTAssertEqual(uploads[1].cdnURL, "https://cdn.example.com/a")
    }

    func testUpdateCDNURL_unknownID_noOp() {
        UploadHistory.add(makeUpload(filename: "a.png"))
        UploadHistory.updateCDNURL(for: UUID(), url: "https://cdn.example.com/x")

        let uploads = UploadHistory.recentUploads()
        XCTAssertEqual(uploads.count, 1)
        XCTAssertNil(uploads[0].cdnURL)
    }

    // MARK: - Stored history

    func testRecentUploads_savedBeforeIDs_stillLoad() throws {
        let json = #"[{"filename":"old.png","date":0,"cacheFilePath":"/tmp/old.png","cdnURL":"https://x"}]"#
        UserDefaults.standard.set(Data(json.utf8), forKey: defaultsKey)

        let uploads = UploadHistory.recentUploads()
        XCTAssertEqual(uploads.count, 1)
        XCTAssertEqual(uploads[0].filename, "old.png")
        XCTAssertEqual(uploads[0].cdnURL, "https://x")
    }

    func testRecentUpload_idSurvivesSaving() {
        let upload = makeUpload(filename: "a.png")
        UploadHistory.add(upload)
        XCTAssertEqual(UploadHistory.recentUploads().first?.id, upload.id)
    }

    // MARK: - cacheFile

    func testCacheFile_copiesFileIntoCache() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("skryn-test-\(UUID()).mp4")
        try Data("video".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let filename = "skryn-test-\(UUID()).mp4"

        let path = try XCTUnwrap(UploadHistory.cacheFile(copyingFrom: source, filename: filename))
        defer { UploadHistory.removeCacheFile(at: path) }

        XCTAssertEqual(FileManager.default.contents(atPath: path), Data("video".utf8))
    }

    func testCacheFile_missingSource_returnsNil() {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).mp4")
        XCTAssertNil(UploadHistory.cacheFile(copyingFrom: source, filename: "missing.mp4"))
    }

    // MARK: - Helper

    private func makeUpload(filename: String) -> RecentUpload {
        RecentUpload(
            filename: filename,
            cdnURL: nil,
            date: Date(),
            cacheFilePath: "/tmp/\(filename)"
        )
    }
}
