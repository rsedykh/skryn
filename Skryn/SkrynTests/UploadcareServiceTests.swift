import XCTest
@testable import Skryn

final class UploadcareServiceTests: XCTestCase {

    private var session: URLSession!

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
            pngData: Data("fake-png".utf8),
            filename: "test.png",
            publicKey: "test-key",
            session: session
        )

        XCTAssertEqual(url, "https://ucarecdn.com/abc-123-def/")
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
            pngData: Data("png-bytes".utf8),
            filename: "shot.png",
            publicKey: "my-pub-key",
            session: session
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
                pngData: Data(), filename: "t.png", publicKey: "k", session: session
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

    func testUpload_withCustomCdnBase_returnsCDNURL() async throws {
        let fileID = "custom-uuid"
        MockURLProtocol.requestHandler = { request in
            let json = Data("{\"file\":\"\(fileID)\"}".utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, json)
        }

        let url = try await UploadcareService.upload(
            pngData: Data("fake-png".utf8),
            filename: "test.png",
            publicKey: "test-key",
            cdnBase: "https://mycdn.ucarecd.net",
            session: session
        )

        XCTAssertEqual(url, "https://mycdn.ucarecd.net/custom-uuid/")
    }

    // MARK: - CDN Base Normalization

    func testNormalizeCdnBase_empty_returnsDefault() {
        XCTAssertEqual(
            UploadcareService.normalizeCdnBase(""),
            "https://ucarecdn.com"
        )
    }

    func testNormalizeCdnBase_whitespace_returnsDefault() {
        XCTAssertEqual(
            UploadcareService.normalizeCdnBase("  \n "),
            "https://ucarecdn.com"
        )
    }

    func testNormalizeCdnBase_bareSubdomain_addsUcarecdNet() {
        XCTAssertEqual(
            UploadcareService.normalizeCdnBase("2ijp1do3td"),
            "https://2ijp1do3td.ucarecd.net"
        )
    }

    func testNormalizeCdnBase_domainWithDot_addsHttps() {
        XCTAssertEqual(
            UploadcareService.normalizeCdnBase("2ijp1do3td.ucarecd.net"),
            "https://2ijp1do3td.ucarecd.net"
        )
    }

    func testNormalizeCdnBase_fullHttpsURL_returnsAsIs() {
        XCTAssertEqual(
            UploadcareService.normalizeCdnBase("https://cdn.example.com"),
            "https://cdn.example.com"
        )
    }

    func testNormalizeCdnBase_trailingSlash_stripped() {
        XCTAssertEqual(
            UploadcareService.normalizeCdnBase("https://cdn.example.com/"),
            "https://cdn.example.com"
        )
    }

    func testNormalizeCdnBase_customDomain_addsHttps() {
        XCTAssertEqual(
            UploadcareService.normalizeCdnBase("cdn.mysite.com"),
            "https://cdn.mysite.com"
        )
    }

    func testNormalizeCdnBase_httpUpgradedToHttps() {
        XCTAssertEqual(
            UploadcareService.normalizeCdnBase("http://cdn.example.com"),
            "https://cdn.example.com"
        )
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
                pngData: Data(), filename: "t.png", publicKey: "k", session: session
            )
            XCTFail("Expected missingFileID")
        } catch is UploadcareError {
            // expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

}

// MARK: - Mock URLProtocol

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var lastRequestBody: Data?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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
