// Dropbox account (DropboxAccount) and HTTP API (DropboxClient). The provider and its Settings view
// are in DropboxProvider.swift.
//
// Each user creates their own app at https://www.dropbox.com/developers/apps:
// - API: Scoped access. Access type: App folder (uploads land in Apps/<app name>/).
// - Permissions tab, before connecting: files.content.write, sharing.write, sharing.read, account_info.read.
//   (sharing.read is only used to look up a link that already exists.)
// - Copy the App key into Settings. No app secret and no redirect URI are needed: sign-in uses
//   OAuth 2 with PKCE, and Dropbox shows the code for the user to paste back.
//
// Endpoints: https://docs.dropboxapi.com/dropbox-api/docs/get-started/authorization (oauth2/authorize, oauth2/token)
// and https://docs.dropboxapi.com/dropbox-api/api-reference (files/upload, files/upload_session/*,
// sharing/create_shared_link_with_settings, sharing/list_shared_links, users/get_current_account, auth/token/revoke).

import AppKit
import CryptoKit
import Foundation
import Security

enum DropboxError: LocalizedError, Equatable {
    case noAppKey
    case notConnected
    /// The access or refresh token was rejected (expired, revoked, or the app was unlinked).
    case expired
    /// The Dropbox app is missing a permission (scope) the call needs.
    case missingScope(String)
    case api(String)
    case invalidResponse
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noAppKey: return "Add your Dropbox app key in Settings"
        case .notConnected: return "Connect Dropbox in Settings"
        case .expired: return "Dropbox access expired or was revoked. Reconnect Dropbox in Settings"
        case .missingScope(let scope):
            return "The Dropbox app lacks the \(scope) permission. Enable it in the App Console, then reconnect"
        case .api(let message): return "Dropbox error: \(message)"
        case .invalidResponse: return "Invalid response from Dropbox"
        case .keychain(let status): return "Couldn't save the Dropbox sign-in to the Keychain (\(status))"
        }
    }
}

// MARK: - Account

/// The Dropbox sign-in: App key and account name in UserDefaults, refresh token in `tokens` (the Keychain).
/// Keeps the short-lived access token in memory and refreshes it once when Dropbox rejects it.
@MainActor
final class DropboxAccount {
    /// Where the refresh token lives
    struct TokenStore {
        var read: () -> String?
        var save: (String) throws -> Void
        var delete: () -> Void

        static var keychain: TokenStore {
            TokenStore(read: RefreshTokenKeychain.read, save: RefreshTokenKeychain.save, delete: RefreshTokenKeychain.delete)
        }
    }

    /// A sign-in in progress: holds the PKCE verifier between opening the browser and pasting the code.
    struct PendingConnection {
        let appKey: String
        let verifier: String
        let authorizeURL: URL
    }

    private static let appKeyKey = "dropboxAppKey"
    private static let accountNameKey = "dropboxAccountName"

    private let client: DropboxClient
    private let tokens: TokenStore
    private let defaults: UserDefaults
    private var cachedToken: DropboxClient.AccessToken?
    /// Cached: the editor toolbar asks on every refresh, and each Keychain read can prompt after a re-sign
    private var cachedIsConnected: Bool?

    init(client: DropboxClient, tokens: TokenStore = .keychain, defaults: UserDefaults = .standard) {
        self.client = client
        self.tokens = tokens
        self.defaults = defaults
    }

    var appKey: String? {
        get {
            let key = defaults.string(forKey: Self.appKeyKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return key?.isEmpty == false ? key : nil
        }
        set {
            let key = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if key.isEmpty {
                defaults.removeObject(forKey: Self.appKeyKey)
            } else {
                defaults.set(key, forKey: Self.appKeyKey)
            }
        }
    }

    var isConnected: Bool {
        if let cachedIsConnected { return cachedIsConnected }
        let connected = tokens.read() != nil
        cachedIsConnected = connected
        return connected
    }

    var accountName: String? { defaults.string(forKey: Self.accountNameKey) }

    /// What's still missing before uploads can go ahead, or nil
    var setupProblem: DropboxError? {
        if appKey == nil { return .noAppKey }
        return isConnected ? nil : .notConnected
    }

    /// Builds the authorize URL (response_type=code, code_challenge S256, token_access_type=offline, no redirect_uri)
    /// and opens it in the browser.
    func beginConnecting(appKey: String) -> PendingConnection {
        let key = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let verifier = DropboxClient.makeVerifier()
        let url = DropboxClient.authorizeURL(appKey: key, challenge: DropboxClient.pkceChallenge(for: verifier))
        NSWorkspace.shared.open(url)
        return PendingConnection(appKey: key, verifier: verifier, authorizeURL: url)
    }

    /// Exchanges the pasted code, stores the refresh token, remembers the account display name.
    func finishConnecting(_ pending: PendingConnection, code: String) async throws {
        let tokens = try await client.exchangeCode(
            code.trimmingCharacters(in: .whitespacesAndNewlines), verifier: pending.verifier, appKey: pending.appKey
        )
        let name = try await client.accountName(accessToken: tokens.access.value)
        try self.tokens.save(tokens.refreshToken)
        cachedIsConnected = true
        appKey = pending.appKey
        cachedToken = tokens.access
        defaults.set(name, forKey: Self.accountNameKey)
    }

    /// Best-effort token revoke, then forgets the token and account name.
    func disconnect() async {
        if let token = try? await accessToken() {
            try? await client.revoke(accessToken: token)
        }
        tokens.delete()
        cachedIsConnected = false
        cachedToken = nil
        defaults.removeObject(forKey: Self.accountNameKey)
    }

    /// Runs `call` with the access token; when Dropbox rejects it (401), refreshes once and retries.
    func authorized<T>(_ call: (String) async throws -> T) async throws -> T {
        do {
            return try await call(await accessToken())
        } catch DropboxError.expired {
            return try await call(await accessToken(forceRefresh: true))
        }
    }

    /// The cached access token, refreshed when missing, within 60s of expiry, or when `forceRefresh` is set.
    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let token = cachedToken, token.expiresAt.timeIntervalSinceNow > 60 {
            return token.value
        }
        guard let appKey else { throw DropboxError.noAppKey }
        guard let refreshToken = tokens.read() else { throw DropboxError.notConnected }
        let token = try await client.accessToken(refreshToken: refreshToken, appKey: appKey)
        cachedToken = token
        return token.value
    }
}

/// The refresh token as a generic password item in the login keychain.
private enum RefreshTokenKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.skryn.app.dropbox",
         kSecAttrAccount as String: "refresh-token"]
    }

    static func read() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
        delete()
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw DropboxError.keychain(status) }
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - HTTP API

/// The Dropbox HTTP API over one URLSession (a stubbed one in tests).
struct DropboxClient {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    struct AccessToken {
        let value: String
        let expiresAt: Date
    }

    struct Tokens {
        let access: AccessToken
        let refreshToken: String
    }

    /// files/upload takes at most 150 MiB per request; bigger files go through an upload session.
    static let singleUploadLimit = 150 * 1_048_576
    /// Upload session chunk: a multiple of 4 MiB (the docs require it for concurrent sessions; sequential accept any).
    static let sessionChunkSize = 8 * 1_048_576

    private static let tokenURL = URL(string: "https://api.dropboxapi.com/oauth2/token")!
    private static let apiBase = "https://api.dropboxapi.com/2/"
    private static let contentBase = "https://content.dropboxapi.com/2/"

    // MARK: OAuth

    /// A random PKCE code_verifier: 32 random bytes, base64url → 43 chars of [A-Za-z0-9-_].
    static func makeVerifier() -> String {
        base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
    }

    /// S256 code_challenge: base64url(SHA256(verifier)) without padding.
    static func pkceChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// No redirect_uri: Dropbox shows the code on its page for the user to copy.
    static func authorizeURL(appKey: String, challenge: String) -> URL {
        var components = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "token_access_type", value: "offline")
        ]
        return components.url!
    }

    /// oauth2/token with grant_type=authorization_code and the PKCE verifier (no client secret).
    func exchangeCode(_ code: String, verifier: String, appKey: String) async throws -> Tokens {
        let json = try await tokenRequest([
            ("code", code), ("grant_type", "authorization_code"),
            ("code_verifier", verifier), ("client_id", appKey)
        ], onInvalidGrant: .api("The code is invalid or expired. Connect again"))
        guard let refreshToken = json["refresh_token"] as? String else { throw DropboxError.invalidResponse }
        return Tokens(access: try Self.accessToken(from: json), refreshToken: refreshToken)
    }

    /// oauth2/token with grant_type=refresh_token (no client secret).
    func accessToken(refreshToken: String, appKey: String) async throws -> AccessToken {
        let json = try await tokenRequest([
            ("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", appKey)
        ], onInvalidGrant: .expired)
        return try Self.accessToken(from: json)
    }

    /// users/get_current_account → name.display_name.
    func accountName(accessToken: String) async throws -> String {
        let data = try await rpc("users/get_current_account", args: nil, accessToken: accessToken)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = (json["name"] as? [String: Any])?["display_name"] as? String else {
            throw DropboxError.invalidResponse
        }
        return name
    }

    /// auth/token/revoke: disables the token (and the sign-in it came from).
    func revoke(accessToken: String) async throws {
        _ = try await rpc("auth/token/revoke", args: nil, accessToken: accessToken)
    }

    private func tokenRequest(_ params: [(String, String)], onInvalidGrant: DropboxError) async throws -> [String: Any] {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(params.map { "\($0)=\(Self.formEncode($1))" }.joined(separator: "&").utf8)
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw DropboxError.invalidResponse }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200...299).contains(status) else {
            if json["error"] as? String == "invalid_grant" { throw onInvalidGrant }
            let message = json["error_description"] as? String ?? json["error"] as? String
            throw DropboxError.api(message ?? "HTTP \(status)")
        }
        return json
    }

    private static func accessToken(from json: [String: Any]) throws -> AccessToken {
        guard let value = json["access_token"] as? String else { throw DropboxError.invalidResponse }
        let lifetime = (json["expires_in"] as? NSNumber)?.doubleValue ?? 0
        return AccessToken(value: value, expiresAt: Date().addingTimeInterval(lifetime))
    }

    // MARK: Upload

    /// Uploads the file to `path` (mode add, autorename) and returns the stored path_display.
    /// Files up to `singleRequestLimit` go through files/upload, streamed from disk; bigger ones through
    /// an upload session read in `chunkSize` pieces. Both parameters exist for tests.
    func upload(fileURL: URL, path: String, accessToken: String, chunkSize: Int = sessionChunkSize,
                singleRequestLimit: Int = singleUploadLimit) async throws -> String {
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let commit: [String: Any] = ["path": path, "mode": "add", "autorename": true]
        let data: Data
        if size <= singleRequestLimit {
            data = try await contentUpload("files/upload", args: commit, body: .file(fileURL),
                                           accessToken: accessToken)
        } else {
            data = try await sessionUpload(fileURL: fileURL, commit: commit, chunkSize: chunkSize,
                                           accessToken: accessToken)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stored = json["path_display"] as? String ?? json["path_lower"] as? String else {
            throw DropboxError.invalidResponse
        }
        return stored
    }

    /// upload_session/start with the first chunk → append_v2 for the middle ones → finish with the last.
    /// Returns finish's response (the file metadata).
    private func sessionUpload(fileURL: URL, commit: [String: Any], chunkSize: Int,
                               accessToken: String) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)

        // ponytail: sequential chunks, no retry; use session_type concurrent if long recordings upload too slowly
        let first = try handle.read(upToCount: chunkSize) ?? Data()
        let start = try await contentUpload("files/upload_session/start", args: [:], body: .data(first),
                                            accessToken: accessToken)
        guard let json = try? JSONSerialization.jsonObject(with: start) as? [String: Any],
              let sessionID = json["session_id"] as? String else { throw DropboxError.invalidResponse }

        var offset = UInt64(first.count)
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            let cursor: [String: Any] = ["session_id": sessionID, "offset": offset]
            if offset + UInt64(chunk.count) >= size {
                return try await contentUpload("files/upload_session/finish", args: ["cursor": cursor, "commit": commit],
                                               body: .data(chunk), accessToken: accessToken)
            }
            _ = try await contentUpload("files/upload_session/append_v2", args: ["cursor": cursor],
                                        body: .data(chunk), accessToken: accessToken)
            offset += UInt64(chunk.count)
        }
    }

    // MARK: Shared links

    /// sharing/create_shared_link_with_settings; when a link already exists, reuses the one in the error's
    /// metadata, or looks it up with sharing/list_shared_links.
    func sharedLink(path: String, accessToken: String) async throws -> String {
        let (status, data) = try await perform(
            Self.jsonRequest("sharing/create_shared_link_with_settings", args: ["path": path], accessToken: accessToken),
            body: nil)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if (200...299).contains(status), let url = json["url"] as? String { return url }
        guard status == 409, (json["error_summary"] as? String)?.hasPrefix("shared_link_already_exists") == true else {
            throw Self.apiError(status: status, data: data)
        }
        let existing = (json["error"] as? [String: Any])?["shared_link_already_exists"] as? [String: Any]
        if let url = existing?["url"] as? String { return url }

        let list = try await rpc("sharing/list_shared_links", args: ["path": path, "direct_only": true],
                                 accessToken: accessToken)
        guard let listJSON = try? JSONSerialization.jsonObject(with: list) as? [String: Any],
              let links = listJSON["links"] as? [[String: Any]],
              let url = links.first?["url"] as? String else { throw DropboxError.invalidResponse }
        return url
    }

    /// Turns a shared link into its permanent public file URL on dl.dropboxusercontent.com.
    static func directLink(from shareURL: String) -> String {
        guard var components = URLComponents(string: shareURL) else { return shareURL }
        // dl.dropboxusercontent.com serves the file itself (200, image/png, inline): no redirect and
        // no Dropbox page, so it embeds in Markdown, GitHub, and chat. www.dropbox.com…?raw=1 only
        // redirects to a temporary URL. `rlkey` (and any other item) is what grants access: keep it.
        components.host = "dl.dropboxusercontent.com"
        let items = (components.percentEncodedQueryItems ?? []).filter { $0.name != "dl" && $0.name != "raw" }
        components.percentEncodedQueryItems = items.isEmpty ? nil : items
        return components.string ?? shareURL
    }

    // MARK: Requests

    private enum Body {
        case data(Data)
        case file(URL)
    }

    /// RPC endpoint on api.dropboxapi.com: JSON args in the body (none for Void-arg routes).
    private func rpc(_ route: String, args: [String: Any]?, accessToken: String) async throws -> Data {
        let (status, data) = try await perform(Self.jsonRequest(route, args: args, accessToken: accessToken), body: nil)
        guard (200...299).contains(status) else { throw Self.apiError(status: status, data: data) }
        return data
    }

    /// Content-upload endpoint on content.dropboxapi.com: args in Dropbox-API-Arg, raw bytes in the body.
    private func contentUpload(_ route: String, args: [String: Any], body: Body,
                               accessToken: String) async throws -> Data {
        var request = URLRequest(url: URL(string: Self.contentBase + route)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(try Self.headerSafeJSON(args), forHTTPHeaderField: "Dropbox-API-Arg")
        let (status, data) = try await perform(request, body: body)
        guard (200...299).contains(status) else { throw Self.apiError(status: status, data: data) }
        return data
    }

    private static func jsonRequest(_ route: String, args: [String: Any]?, accessToken: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: apiBase + route)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let args {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: args)
        }
        return request
    }

    /// Sends the request; maps 401 to `.expired` / `.missingScope` and returns any other status with the body.
    private func perform(_ request: URLRequest, body: Body?) async throws -> (Int, Data) {
        let (data, response): (Data, URLResponse)
        switch body {
        case .data(let bytes): (data, response) = try await session.upload(for: request, from: bytes)
        case .file(let url): (data, response) = try await session.upload(for: request, fromFile: url)
        case nil: (data, response) = try await session.data(for: request)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw DropboxError.invalidResponse }
        if status == 401 {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            if error?[".tag"] as? String == "missing_scope" {
                throw DropboxError.missingScope(error?["required_scope"] as? String ?? "required")
            }
            throw DropboxError.expired
        }
        return (status, data)
    }

    /// Dropbox's user_message, else error_summary (minus the trailing dots it adds), else the raw body.
    private static func apiError(status: Int, data: Data) -> DropboxError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let message = (json?["user_message"] as? [String: Any])?["text"] as? String { return .api(message) }
        if let summary = json?["error_summary"] as? String {
            return .api(summary.trimmingCharacters(in: CharacterSet(charactersIn: "./")))
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return .api(text.isEmpty ? "HTTP \(status)" : text)
    }

    // MARK: Encoding

    /// JSON for the Dropbox-API-Arg header: 0x7F and all non-ASCII escaped as \uXXXX (UTF-16 units).
    static func headerSafeJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        let json = String(bytes: data, encoding: .utf8) ?? ""  // JSONSerialization always writes UTF-8
        return json.utf16.map { $0 < 0x7F ? String(UnicodeScalar(UInt8($0))) : String(format: "\\u%04x", $0) }
            .joined()
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static let formSafe = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formSafe) ?? value
    }
}
