import CryptoKit
import Foundation

enum UploadcareError: LocalizedError {
    case invalidResponse
    case serverError(String)
    case missingFileID

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from Uploadcare"
        case .serverError(let msg): return "Uploadcare error: \(msg)"
        case .missingFileID: return "No file ID in Uploadcare response"
        }
    }
}

enum UploadcareService {
    private static let uploadURL = URL(string: "https://upload.uploadcare.com/base/")!
    static let defaultCdnBase = "https://ucarecdn.com"

    /// Normalizes user CDN base input into a full https URL.
    static func normalizeCdnBase(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultCdnBase }

        // Full URL — strip trailing slashes, upgrade http to https
        if trimmed.lowercased().hasPrefix("http://") {
            let stripped = trimmed.dropFirst(7)
            return "https://\(stripped)".trimmingSlashes()
        }
        if trimmed.lowercased().hasPrefix("https://") {
            return trimmed.trimmingSlashes()
        }

        // Has dots → treat as domain
        if trimmed.contains(".") {
            return "https://\(trimmed)".trimmingSlashes()
        }

        // Bare subdomain → project-specific ucarecd.net
        return "https://\(trimmed).ucarecd.net"
    }

    /// Computes the 10-char CNAME prefix from a public key.
    /// Algorithm: SHA-256 → big-endian integer → base-36 → first 10 chars.
    static func cnamePrefix(forPublicKey key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        var bytes = Array(digest)
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var result = ""
        while !bytes.allSatisfy({ $0 == 0 }) {
            var remainder: UInt16 = 0
            for i in 0..<bytes.count {
                let dividend = remainder &* 256 &+ UInt16(bytes[i])
                bytes[i] = UInt8(dividend / 36)
                remainder = dividend % 36
            }
            result = String(alphabet[Int(remainder)]) + result
        }
        return String(result.prefix(10))
    }

    /// Returns the CDN base URL for a given public key (e.g. "https://2ijp1do3td.ucarecd.net").
    static func cdnBase(forPublicKey key: String) -> String {
        let prefix = cnamePrefix(forPublicKey: key)
        return "https://\(prefix).ucarecd.net"
    }

    /// Uploads PNG data to Uploadcare and returns the CDN URL.
    static func upload(pngData: Data, filename: String, publicKey: String,
                       cdnBase: String = defaultCdnBase,
                       session: URLSession = .shared) async throws -> String {
        try await upload(
            fileData: pngData, filename: filename, contentType: "image/png",
            publicKey: publicKey, cdnBase: cdnBase, session: session
        )
    }

    /// Uploads arbitrary file data to Uploadcare with a specified content type.
    static func upload(fileData: Data, filename: String, contentType: String,
                       publicKey: String, cdnBase: String = defaultCdnBase,
                       session: URLSession = .shared) async throws -> String {
        let boundary = UUID().uuidString

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        body.appendMultipart(boundary: boundary, name: "UPLOADCARE_PUB_KEY", value: publicKey)
        body.appendMultipart(boundary: boundary, name: "UPLOADCARE_STORE", value: "1")

        body.append(Data("--\(boundary)\r\n".utf8))
        let safeFilename = filename.replacingOccurrences(of: "\"", with: "\\\"")
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n".utf8))

        body.append(Data("--\(boundary)--\r\n".utf8))

        request.httpBody = body

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UploadcareError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw UploadcareError.serverError(message)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileID = json["file"] as? String else {
            throw UploadcareError.missingFileID
        }

        return "\(cdnBase)/\(fileID)/"
    }
}

private extension String {
    func trimmingSlashes() -> String {
        var result = self
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

private extension Data {
    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        append(Data("\(value)\r\n".utf8))
    }
}
