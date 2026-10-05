import XCTest
@testable import Skryn

final class UploadcareServiceTests: XCTestCase {

    private var session: URLSession!
    private var tempFiles: [URL] = []

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        session = nil
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.lastRequestBody = nil
        MockURLProtocol.requests = []
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
        super.tearDown()
    }

    // MARK: - Success

    func testUpload_returnsCDNURL() async throws {
        let fileID = "abc-123-def"
        MockURLProtocol.requestHandler = { request in
            let json = Data("{\"file\":\"\(fileID)\"}".utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, json)
        }

        let url = try await UploadcareService.upload(
            fileURL: try makeTempFile(Data("fake-png".utf8)), filename: "test.png", contentType: "image/png",
            publicKey: "test-key", session: session
        )

        XCTAssertEqual(url, UploadcareService.cdnBase(forPublicKey: "test-key") + "/abc-123-def/")
    }

    // MARK: - Multipart body

    func testUpload_sendsCorrectMultipartBody() async throws {
        var capturedContentType: String?
        MockURLProtocol.lastRequestBody = nil
        MockURLProtocol.requestHandler = { request in
            capturedContentType = request.value(forHTTPHeaderField: "Content-Type")
            let json = Data("{\"file\":\"id\"}".utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, json)
        }

        _ = try await UploadcareService.upload(
            fileURL: try makeTempFile(Data("png-bytes".utf8)), filename: "shot.png", contentType: "image/png",
            publicKey: "my-pub-key", session: session
        )

        let contentType = try XCTUnwrap(capturedContentType)
        XCTAssertTrue(contentType.starts(with: "multipart/form-data; boundary="))

        let bodyData = try XCTUnwrap(MockURLProtocol.lastRequestBody)
        let bodyString = try XCTUnwrap(String(data: bodyData, encoding: .utf8))
        XCTAssertTrue(bodyString.contains("UPLOADCARE_PUB_KEY"))
        XCTAssertTrue(bodyString.contains("my-pub-key"))
        XCTAssertTrue(bodyString.contains("UPLOADCARE_STORE"))
        XCTAssertTrue(bodyString.contains("filename=\"shot.png\""))
        XCTAssertTrue(bodyString.contains("image/png"))
    }

    // MARK: - Error cases

    func testUpload_serverError_throwsWithMessage() async {
        MockURLProtocol.requestHandler = { request in
            let body = Data("Bad Request".utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 400,
                httpVersion: nil, headerFields: nil
            )!
            return (response, body)
        }

        do {
            _ = try await UploadcareService.upload(
            fileURL: try makeTempFile(Data()), filename: "t.png", contentType: "image/png",
            publicKey: "k", session: session
        )
            XCTFail("Expected serverError")
        } catch let error as UploadcareError {
            guard case .serverError(let msg) = error else {
                return XCTFail("Expected serverError, got \(error)")
            }
            XCTAssertEqual(msg, "Bad Request")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - CNAME Prefix

    func testCnamePrefix_userKey() {
        XCTAssertEqual(
            UploadcareService.cnamePrefix(forPublicKey: "b527517dd9b0b6b2ba3c"),
            "2ijp1do3td"
        )
    }

    func testCnamePrefix_demoPublicKey() {
        XCTAssertEqual(
            UploadcareService.cnamePrefix(forPublicKey: "demopublickey"),
            "1s4oyld5dc"
        )
    }

    func testCnamePrefix_knownVector1() {
        XCTAssertEqual(
            UploadcareService.cnamePrefix(forPublicKey: "c8c237984266090ff9b8"),
            "127mbvwq3b"
        )
    }

    func testCnamePrefix_knownVector2() {
        XCTAssertEqual(
            UploadcareService.cnamePrefix(forPublicKey: "3e6ba70c0670de3bef7a"),
            "u51bthcx6t"
        )
    }

    func testCnamePrefix_knownVector3() {
        XCTAssertEqual(
            UploadcareService.cnamePrefix(forPublicKey: "823a5ae6eb3afa5b353f"),
            "ggiwfssv31"
        )
    }

    func testCdnBase_forPublicKey() {
        XCTAssertEqual(
            UploadcareService.cdnBase(forPublicKey: "b527517dd9b0b6b2ba3c"),
            "https://2ijp1do3td.ucarecd.net"
        )
    }

    // MARK: - Error cases

    func testUpload_missingFileID_throws() async {
        MockURLProtocol.requestHandler = { request in
            let json = Data("{\"status\":\"ok\"}".utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, json)
        }

        do {
            _ = try await UploadcareService.upload(
            fileURL: try makeTempFile(Data()), filename: "t.png", contentType: "image/png",
            publicKey: "k", session: session
        )
            XCTFail("Expected missingFileID")
        } catch is UploadcareError {
            // expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - File upload

    private func makeTempFile(bytes: Int) throws -> URL {
        try makeTempFile(Data((0..<bytes).map { UInt8($0 % 251) }))
    }

    private func makeTempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try data.write(to: url)
        tempFiles.append(url)
        return url
    }

    private static func ok(_ request: URLRequest, _ json: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    private static func multipartHandler(partStatus: Int) -> (URLRequest) -> (HTTPURLResponse, Data) {
        { request in
            switch request.url!.absoluteString {
            case "https://upload.uploadcare.com/multipart/start/":
                return ok(request, """
                    {"uuid":"mp-uuid","parts":["https://s3.test/p1","https://s3.test/p2","https://s3.test/p3"]}
                    """)
            case "https://upload.uploadcare.com/multipart/complete/":
                return ok(request, "{\"uuid\":\"mp-uuid\",\"file_id\":\"mp-uuid\"}")
            default:
                let response = HTTPURLResponse(url: request.url!, statusCode: partStatus,
                                               httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
        }
    }

    func testUploadFile_large_usesMultipart() async throws {
        let fileURL = try makeTempFile(bytes: 25)
        MockURLProtocol.requestHandler = Self.multipartHandler(partStatus: 200)

        let url = try await UploadcareService.upload(
            fileURL: fileURL, filename: "rec.mp4", contentType: "video/mp4", publicKey: "k",
            session: session, multipartThreshold: 20, partSize: 10
        )

        XCTAssertEqual(url, UploadcareService.cdnBase(forPublicKey: "k") + "/mp-uuid/")
        let requests = MockURLProtocol.requests
        XCTAssertEqual(requests.map { $0.request.url!.absoluteString }, [
            "https://upload.uploadcare.com/multipart/start/",
            "https://s3.test/p1", "https://s3.test/p2", "https://s3.test/p3",
            "https://upload.uploadcare.com/multipart/complete/"
        ])
        let start = try XCTUnwrap(String(data: requests[0].body, encoding: .utf8))
        for field in ["name=\"size\"\r\n\r\n25\r\n", "name=\"part_size\"\r\n\r\n10\r\n",
                      "name=\"content_type\"\r\n\r\nvideo/mp4\r\n", "name=\"filename\"\r\n\r\nrec.mp4\r\n"] {
            XCTAssertTrue(start.contains(field), field)
        }
        let puts = requests[1...3]
        XCTAssertEqual(puts.map { $0.request.httpMethod }, ["PUT", "PUT", "PUT"])
        XCTAssertEqual(puts.map { $0.body.count }, [10, 10, 5])
        XCTAssertEqual(puts.map { $0.request.value(forHTTPHeaderField: "Content-Type") },
                       ["video/mp4", "video/mp4", "video/mp4"])
        XCTAssertEqual(puts.reduce(Data()) { $0 + $1.body }, try Data(contentsOf: fileURL))
        let complete = try XCTUnwrap(String(data: requests[4].body, encoding: .utf8))
        XCTAssertTrue(complete.contains("name=\"uuid\"\r\n\r\nmp-uuid\r\n"))
    }

    func testUploadFile_partFailure_throws() async throws {
        let fileURL = try makeTempFile(bytes: 25)
        MockURLProtocol.requestHandler = Self.multipartHandler(partStatus: 403)

        do {
            _ = try await UploadcareService.upload(
                fileURL: fileURL, filename: "rec.mp4", contentType: "video/mp4", publicKey: "k",
                session: session, multipartThreshold: 20, partSize: 10
            )
            XCTFail("Expected serverError")
        } catch UploadcareError.serverError {
            XCTAssertFalse(MockURLProtocol.requests.contains {
                $0.request.url!.path == "/multipart/complete/"
            })
        }
    }

    func testUploadFile_small_usesBaseWithContentType() async throws {
        let fileURL = try makeTempFile(bytes: 19)
        MockURLProtocol.requestHandler = { Self.ok($0, "{\"file\":\"small-id\"}") }

        let url = try await UploadcareService.upload(
            fileURL: fileURL, filename: "rec.mp4", contentType: "video/mp4", publicKey: "k",
            session: session, multipartThreshold: 20, partSize: 10
        )

        XCTAssertEqual(url, UploadcareService.cdnBase(forPublicKey: "k") + "/small-id/")
        let requests = MockURLProtocol.requests
        XCTAssertEqual(requests.map { $0.request.url!.absoluteString }, ["https://upload.uploadcare.com/base/"])
        let body = try XCTUnwrap(String(data: requests[0].body, encoding: .isoLatin1))
        XCTAssertTrue(body.contains("Content-Type: video/mp4\r\n"))
        XCTAssertFalse(body.contains("image/png"))
    }

}

// MARK: - Mock URLProtocol

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var lastRequestBody: Data?
    static var requests: [(request: URLRequest, body: Data)] = []

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.lastRequestBody = nil
        // Capture body — URLSession may deliver it via stream instead of httpBody
        if let body = request.httpBody {
            MockURLProtocol.lastRequestBody = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 4096)
                if read > 0 { data.append(buffer, count: read) } else { break }
            }
            stream.close()
            MockURLProtocol.lastRequestBody = data
        }
        MockURLProtocol.requests.append((request, MockURLProtocol.lastRequestBody ?? Data()))

        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
