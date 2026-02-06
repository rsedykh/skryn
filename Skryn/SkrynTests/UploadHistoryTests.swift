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

    func testAdd_persistsAcrossReads() {
        UploadHistory.add(makeUpload(filename: "persisted.png"))

        // Read twice to ensure UserDefaults persistence
        let first = UploadHistory.recentUploads()
        let second = UploadHistory.recentUploads()
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(first[0].filename, "persisted.png")
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
        UploadHistory.add(makeUpload(filename: "a.png"))
        UploadHistory.add(makeUpload(filename: "b.png"))

        UploadHistory.updateCDNURL(for: "a.png", url: "https://cdn.example.com/a")

        let updated = UploadHistory.recentUploads().first { $0.filename == "a.png" }
        XCTAssertEqual(updated?.cdnURL, "https://cdn.example.com/a")
    }

    func testUpdateCDNURL_doesNotAffectOtherEntries() {
        UploadHistory.add(makeUpload(filename: "a.png"))
        UploadHistory.add(makeUpload(filename: "b.png"))

        UploadHistory.updateCDNURL(for: "a.png", url: "https://cdn.example.com/a")

        let other = UploadHistory.recentUploads().first { $0.filename == "b.png" }
        XCTAssertNil(other?.cdnURL)
    }

    func testUpdateCDNURL_unknownFilename_noOp() {
        UploadHistory.add(makeUpload(filename: "a.png"))
        UploadHistory.updateCDNURL(for: "nonexistent.png", url: "https://cdn.example.com/x")

        let uploads = UploadHistory.recentUploads()
        XCTAssertEqual(uploads.count, 1)
        XCTAssertNil(uploads[0].cdnURL)
    }

    // MARK: - File caching

    func testCachePNGData_writesAndReadsBack() {
        let data = Data("test-png-content".utf8)
        let filename = "test-\(UUID().uuidString).png"

        let path = UploadHistory.cachePNGData(data, filename: filename)
        XCTAssertNotNil(path)

        let readBack = UploadHistory.cachedData(at: path!)
        XCTAssertEqual(readBack, data)

        UploadHistory.removeCacheFile(at: path!)
    }

    func testCachedData_nonexistentPath_returnsNil() {
        XCTAssertNil(UploadHistory.cachedData(at: "/tmp/nonexistent-\(UUID()).png"))
    }

    func testRemoveCacheFile_deletesFile() {
        let data = Data("to-delete".utf8)
        let filename = "delete-\(UUID().uuidString).png"
        let path = UploadHistory.cachePNGData(data, filename: filename)!

        UploadHistory.removeCacheFile(at: path)

        XCTAssertNil(UploadHistory.cachedData(at: path))
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
