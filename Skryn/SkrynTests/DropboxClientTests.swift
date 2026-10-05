import XCTest
@testable import Skryn

final class DropboxClientTests: XCTestCase {

    private var session: URLSession!
    private var tempFiles: [URL] = []

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DropboxMockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        session = nil
        DropboxMockURLProtocol.requestHandler = nil
        DropboxMockURLProtocol.requests = []
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
        super.tearDown()
    }

    private var client: DropboxClient { DropboxClient(session: session) }

    // MARK: - Helpers

    private func makeTempFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        tempFiles.append(url)
        return url
    }

    private static func respond(_ request: URLRequest, _ status: Int, _ json: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    private static func form(_ body: Data) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(data: body, encoding: .utf8)
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private static func apiArg(_ request: URLRequest) throws -> [String: Any] {
        let header = try XCTUnwrap(request.value(forHTTPHeaderField: "Dropbox-API-Arg"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: Any])
    }

    // MARK: - OAuth

    /// Expected value from Python: urlsafe_b64encode(sha256(verifier).digest()).rstrip(b"=").
    func testPKCEChallenge_isUnpaddedBase64URLOfSHA256() {
        XCTAssertEqual(DropboxClient.pkceChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWEOEjXk"),
                       "TP3DZQl9rJnri9eRuZaFS6Q7czCrth7sEZC00LreApo")
    }

    func testMakeVerifier_isUnpaddedBase64URL() {
        let verifier = DropboxClient.makeVerifier()
        XCTAssertEqual(verifier.count, 43)
        XCTAssertNil(verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertNotEqual(verifier, DropboxClient.makeVerifier())
    }

    func testAuthorizeURL_hasPKCEAndOfflineWithoutRedirect() throws {
        let url = DropboxClient.authorizeURL(appKey: "key123", challenge: "chal")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "www.dropbox.com")
        XCTAssertEqual(components.path, "/oauth2/authorize")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items, ["client_id": "key123", "response_type": "code", "code_challenge": "chal",
                               "code_challenge_method": "S256", "token_access_type": "offline"])
    }

    func testExchangeCode_sendsPKCEFormWithoutSecret() async throws {
        DropboxMockURLProtocol.requestHandler = {
            Self.respond($0, 200, """
                {"access_token":"sl.abc","expires_in":14400,"token_type":"bearer","refresh_token":"rt-1"}
                """)
        }

        let tokens = try await client.exchangeCode("code+1", verifier: "ver", appKey: "key")

        XCTAssertEqual(tokens.refreshToken, "rt-1")
        XCTAssertEqual(tokens.access.value, "sl.abc")
        XCTAssertEqual(tokens.access.expiresAt.timeIntervalSinceNow, 14400, accuracy: 60)
        let (request, body) = try XCTUnwrap(DropboxMockURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.dropboxapi.com/oauth2/token")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(Self.form(body), ["code": "code+1", "grant_type": "authorization_code",
                                         "code_verifier": "ver", "client_id": "key"])
    }

    func testAccessToken_refreshGrant() async throws {
        DropboxMockURLProtocol.requestHandler = {
            Self.respond($0, 200, "{\"access_token\":\"sl.new\",\"expires_in\":14400,\"token_type\":\"bearer\"}")
        }

        let token = try await client.accessToken(refreshToken: "rt-1", appKey: "key")

        XCTAssertEqual(token.value, "sl.new")
        XCTAssertEqual(token.expiresAt.timeIntervalSinceNow, 14400, accuracy: 60)
        let body = try XCTUnwrap(DropboxMockURLProtocol.requests.first?.body)
        XCTAssertEqual(Self.form(body), ["grant_type": "refresh_token", "refresh_token": "rt-1", "client_id": "key"])
    }

    func testAccessToken_invalidGrant_throwsExpired() async {
        DropboxMockURLProtocol.requestHandler = {
            Self.respond($0, 400, "{\"error\":\"invalid_grant\",\"error_description\":\"refresh token is invalid\"}")
        }
        do {
            _ = try await client.accessToken(refreshToken: "rt", appKey: "key")
            XCTFail("Expected expired")
        } catch {
            XCTAssertEqual(error as? DropboxError, .expired)
        }
    }

    // MARK: - Upload

    func testUpload_small_usesSingleRequest() async throws {
        let fileURL = try makeTempFile(bytes: 19)
        DropboxMockURLProtocol.requestHandler = {
            Self.respond($0, 200, "{\"name\":\"rec.mp4\",\"path_display\":\"/rec (1).mp4\",\"path_lower\":\"/rec (1).mp4\"}")
        }

        let path = try await client.upload(fileURL: fileURL, path: "/rec.mp4", accessToken: "tok",
                                           chunkSize: 10, singleRequestLimit: 20)

        XCTAssertEqual(path, "/rec (1).mp4")
        let requests = DropboxMockURLProtocol.requests
        XCTAssertEqual(requests.map { $0.request.url!.absoluteString }, ["https://content.dropboxapi.com/2/files/upload"])
        let request = requests[0].request
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        let arg = try Self.apiArg(request)
        XCTAssertEqual(arg["path"] as? String, "/rec.mp4")
        XCTAssertEqual(arg["mode"] as? String, "add")
        XCTAssertEqual(arg["autorename"] as? Bool, true)
        XCTAssertEqual(requests[0].body, try Data(contentsOf: fileURL))
    }

    func testUpload_large_usesSessionWithThreeChunks() async throws {
        let fileURL = try makeTempFile(bytes: 25)
        DropboxMockURLProtocol.requestHandler = { request in
            switch request.url!.path {
            case "/2/files/upload_session/start": return Self.respond(request, 200, "{\"session_id\":\"sess-1\"}")
            case "/2/files/upload_session/append_v2": return Self.respond(request, 200, "null")
            default: return Self.respond(request, 200, "{\"path_display\":\"/rec.mp4\"}")
            }
        }

        let path = try await client.upload(fileURL: fileURL, path: "/rec.mp4", accessToken: "tok",
                                           chunkSize: 10, singleRequestLimit: 20)

        XCTAssertEqual(path, "/rec.mp4")
        let requests = DropboxMockURLProtocol.requests
        XCTAssertEqual(requests.map { $0.request.url!.path },
                       ["/2/files/upload_session/start", "/2/files/upload_session/append_v2",
                        "/2/files/upload_session/finish"])
        XCTAssertEqual(requests.map { $0.body.count }, [10, 10, 5])
        XCTAssertEqual(requests.reduce(Data()) { $0 + $1.body }, try Data(contentsOf: fileURL))

        let append = try Self.apiArg(requests[1].request)
        let appendCursor = try XCTUnwrap(append["cursor"] as? [String: Any])
        XCTAssertEqual(appendCursor["session_id"] as? String, "sess-1")
        XCTAssertEqual(appendCursor["offset"] as? Int, 10)

        let finish = try Self.apiArg(requests[2].request)
        XCTAssertEqual((finish["cursor"] as? [String: Any])?["offset"] as? Int, 20)
        let commit = try XCTUnwrap(finish["commit"] as? [String: Any])
        XCTAssertEqual(commit["path"] as? String, "/rec.mp4")
        XCTAssertEqual(commit["mode"] as? String, "add")
        XCTAssertEqual(commit["autorename"] as? Bool, true)
    }

    func testUpload_unauthorized_throwsExpired() async throws {
        let fileURL = try makeTempFile(bytes: 5)
        DropboxMockURLProtocol.requestHandler = {
            Self.respond($0, 401, "{\"error_summary\":\"expired_access_token/..\",\"error\":{\".tag\":\"expired_access_token\"}}")
        }
        do {
            _ = try await client.upload(fileURL: fileURL, path: "/a.png", accessToken: "tok")
            XCTFail("Expected expired")
        } catch {
            XCTAssertEqual(error as? DropboxError, .expired)
        }
    }

    func testUpload_missingScope_namesScope() async throws {
        let fileURL = try makeTempFile(bytes: 5)
        DropboxMockURLProtocol.requestHandler = {
            Self.respond($0, 401, """
                {"error_summary":"missing_scope/.","error":{".tag":"missing_scope","required_scope":"files.content.write"}}
                """)
        }
        do {
            _ = try await client.upload(fileURL: fileURL, path: "/a.png", accessToken: "tok")
            XCTFail("Expected missingScope")
        } catch {
            XCTAssertEqual(error as? DropboxError, .missingScope("files.content.write"))
        }
    }

    // MARK: - Shared links

    func testSharedLink_created() async throws {
        DropboxMockURLProtocol.requestHandler = {
            Self.respond($0, 200, "{\".tag\":\"file\",\"url\":\"https://www.dropbox.com/scl/fi/x/a.png?rlkey=k&dl=0\"}")
        }

        let url = try await client.sharedLink(path: "/a.png", accessToken: "tok")

        XCTAssertEqual(url, "https://www.dropbox.com/scl/fi/x/a.png?rlkey=k&dl=0")
        let (request, body) = try XCTUnwrap(DropboxMockURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.dropboxapi.com/2/sharing/create_shared_link_with_settings")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["path"] as? String, "/a.png")
    }

    func testSharedLink_alreadyExists_reusesMetadata() async throws {
        DropboxMockURLProtocol.requestHandler = {
            Self.respond($0, 409, """
                {"error_summary":"shared_link_already_exists/metadata/..","error":{".tag":"shared_link_already_exists",\
                "shared_link_already_exists":{".tag":"metadata","url":"https://www.dropbox.com/s/old/a.png?dl=0"}}}
                """)
        }

        let url = try await client.sharedLink(path: "/a.png", accessToken: "tok")

        XCTAssertEqual(url, "https://www.dropbox.com/s/old/a.png?dl=0")
        XCTAssertEqual(DropboxMockURLProtocol.requests.count, 1)
    }

    func testSharedLink_alreadyExistsWithoutMetadata_listsLinks() async throws {
        DropboxMockURLProtocol.requestHandler = { request in
            if request.url!.path == "/2/sharing/list_shared_links" {
                return Self.respond(request, 200, """
                    {"links":[{".tag":"file","url":"https://www.dropbox.com/s/listed/a.png?dl=0"}],"has_more":false}
                    """)
            }
            return Self.respond(request, 409, """
                {"error_summary":"shared_link_already_exists/..","error":{".tag":"shared_link_already_exists"}}
                """)
        }

        let url = try await client.sharedLink(path: "/a.png", accessToken: "tok")

        XCTAssertEqual(url, "https://www.dropbox.com/s/listed/a.png?dl=0")
        let list = try XCTUnwrap(DropboxMockURLProtocol.requests.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: list.body) as? [String: Any])
        XCTAssertEqual(json["path"] as? String, "/a.png")
        XCTAssertEqual(json["direct_only"] as? Bool, true)
    }

    func testSharedLink_otherConflict_throwsSummary() async {
        DropboxMockURLProtocol.requestHandler = {
            Self.respond($0, 409, "{\"error_summary\":\"path/not_found/...\",\"error\":{\".tag\":\"path\"}}")
        }
        do {
            _ = try await client.sharedLink(path: "/a.png", accessToken: "tok")
            XCTFail("Expected api error")
        } catch {
            XCTAssertEqual(error as? DropboxError, .api("path/not_found"))
        }
    }

    // MARK: - Direct links

    func testDirectLink_classicLink() {
        XCTAssertEqual(DropboxClient.directLink(from: "https://www.dropbox.com/s/abc123/shot.png?dl=0"),
                       "https://dl.dropboxusercontent.com/s/abc123/shot.png")
    }

    func testDirectLink_sclLinkKeepsRlkey() {
        XCTAssertEqual(
            DropboxClient.directLink(from: "https://www.dropbox.com/scl/fi/xyz789/shot.png?rlkey=k3y&dl=0"),
            "https://dl.dropboxusercontent.com/scl/fi/xyz789/shot.png?rlkey=k3y")
    }

    func testDirectLink_noQuery() {
        XCTAssertEqual(DropboxClient.directLink(from: "https://www.dropbox.com/s/abc/shot.png"),
                       "https://dl.dropboxusercontent.com/s/abc/shot.png")
    }

    // MARK: - Header encoding

    func testHeaderSafeJSON_escapesNonASCII() throws {
        let header = try DropboxClient.headerSafeJSON(["path": "/caf\u{e9} \u{1F600}\u{7F}.png"])
        XCTAssertTrue(header.allSatisfy { $0.isASCII && $0 != "\u{7F}" })
        XCTAssertTrue(header.contains("\\u00e9"))
        XCTAssertTrue(header.contains("\\ud83d\\ude00"))
        XCTAssertTrue(header.contains("\\u007f"))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: String])
        XCTAssertEqual(decoded["path"], "/caf\u{e9} \u{1F600}\u{7F}.png")
    }

    // MARK: - Account

    /// An account with an App key, a refresh token in memory, and throwaway defaults
    @MainActor
    private func makeAccount() -> DropboxAccount {
        var stored: String? = "rt-1"
        let tokens = DropboxAccount.TokenStore(read: { stored }, save: { stored = $0 }, delete: { stored = nil })
        let defaults = UserDefaults(suiteName: "DropboxAccountTests-\(UUID().uuidString)")!
        let account = DropboxAccount(client: client, tokens: tokens, defaults: defaults)
        account.appKey = "key"
        return account
    }

    private var tokenRequests: Int {
        DropboxMockURLProtocol.requests.filter { $0.request.url?.path == "/oauth2/token" }.count
    }

    @MainActor
    func testAccount_cachesAccessTokenBetweenCalls() async throws {
        DropboxMockURLProtocol.requestHandler = {
            Self.respond($0, 200, "{\"access_token\":\"sl.a\",\"expires_in\":14400,\"token_type\":\"bearer\"}")
        }
        let account = makeAccount()

        let first = try await account.authorized { $0 }
        let second = try await account.authorized { $0 }

        XCTAssertEqual([first, second], ["sl.a", "sl.a"])
        XCTAssertEqual(tokenRequests, 1)
    }

    @MainActor
    func testAccount_refreshesOnceWhenTheTokenIsRejected() async throws {
        var issued = 0
        DropboxMockURLProtocol.requestHandler = {
            issued += 1
            return Self.respond($0, 200, "{\"access_token\":\"sl.\(issued)\",\"expires_in\":14400}")
        }
        let account = makeAccount()
        var seen: [String] = []

        let result = try await account.authorized { token -> String in
            seen.append(token)
            if seen.count == 1 { throw DropboxError.expired }
            return token
        }

        XCTAssertEqual(seen, ["sl.1", "sl.2"])
        XCTAssertEqual(result, "sl.2")
        XCTAssertEqual(tokenRequests, 2)
    }

    @MainActor
    func testAccount_setupProblem_followsAppKeyAndConnection() async {
        DropboxMockURLProtocol.requestHandler = { Self.respond($0, 200, "null") }
        let account = makeAccount()
        XCTAssertNil(account.setupProblem)

        await account.disconnect()
        XCTAssertEqual(account.setupProblem, .notConnected)
        account.appKey = "  "
        XCTAssertEqual(account.setupProblem, .noAppKey)
    }
}

// MARK: - Mock URLProtocol

private final class DropboxMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var requests: [(request: URLRequest, body: Data)] = []

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession delivers upload bodies as a stream rather than httpBody
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 4096)
                if read > 0 { body.append(buffer, count: read) } else { break }
            }
            stream.close()
        }
        Self.requests.append((request, body))

        guard let handler = Self.requestHandler else {
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
