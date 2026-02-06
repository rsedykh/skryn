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

    func testUpload_postsToCorrectURL() async throws {
        var capturedURL: URL?
        MockURLProtocol.requestHandler = { request in
            capturedURL = request.url
            let json = Data("{\"file\":\"id\"}".utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, json)
        }

        _ = try await UploadcareService.upload(
            pngData: Data(), filename: "f.png", publicKey: "k", session: session
        )

        XCTAssertEqual(capturedURL?.absoluteString, "https://upload.uploadcare.com/base/")
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

    func testUpload_malformedJSON_throws() async {
        MockURLProtocol.requestHandler = { request in
            let body = Data("not json".utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, body)
        }

        do {
            _ = try await UploadcareService.upload(
                pngData: Data(), filename: "t.png", publicKey: "k", session: session
            )
            XCTFail("Expected error")
        } catch is UploadcareError {
            // expected — malformed JSON falls through to missingFileID
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Error descriptions

    func testErrorDescriptions() {
        XCTAssertEqual(
            UploadcareError.invalidResponse.errorDescription,
            "Invalid response from Uploadcare"
        )
        XCTAssertEqual(
            UploadcareError.serverError("oops").errorDescription,
            "Uploadcare error: oops"
        )
        XCTAssertEqual(
            UploadcareError.missingFileID.errorDescription,
            "No file ID in Uploadcare response"
        )
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
