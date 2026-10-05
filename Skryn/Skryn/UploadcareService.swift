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
    private static let uploadBaseURL = URL(string: "https://upload.uploadcare.com/")!

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

    /// Smallest file /multipart/ accepts (docs: "Multipart uploads support files larger than 10 megabytes only";
    /// the Swift SDK uses 10485760 and goes direct below it).
    static let multipartMinFileSize = 10_485_760
    /// Part size /multipart/start/ assumes by default (5 MiB, the S3 minimum for every part but the last).
    static let multipartPartSize = 5_242_880

    /// Uploads the file at `fileURL` and returns its URL on the key's CDN ("<cdnBase>/<uuid>/").
    /// Files smaller than the multipart minimum go through /base/; larger ones through /multipart/.
    /// `multipartThreshold` and `partSize` exist for tests; keep the defaults in production.
    static func upload(fileURL: URL, filename: String, contentType: String, publicKey: String,
                       session: URLSession = .shared,
                       multipartThreshold: Int = multipartMinFileSize,
                       partSize: Int = multipartPartSize) async throws -> String {
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let fileID: String
        if size < multipartThreshold {
            fileID = try await directUpload(data: Data(contentsOf: fileURL), filename: filename,
                                            contentType: contentType, publicKey: publicKey, session: session)
        } else {
            let file = DiskFile(url: fileURL, filename: filename, contentType: contentType)
            fileID = try await multipartUpload(file, publicKey: publicKey, partSize: partSize, session: session)
        }
        return "\(cdnBase(forPublicKey: publicKey))/\(fileID)/"
    }

    /// POST /base/; returns the file UUID.
    private static func directUpload(data: Data, filename: String, contentType: String,
                                     publicKey: String, session: URLSession) async throws -> String {
        let json = try await postForm(
            path: "base/",
            fields: [("UPLOADCARE_PUB_KEY", publicKey), ("UPLOADCARE_STORE", "1")],
            file: FormFile(filename: filename, contentType: contentType, data: data), session: session)
        guard let fileID = json["file"] as? String else { throw UploadcareError.missingFileID }
        return fileID
    }

    /// /multipart/start/ → PUT each part to its presigned URL → /multipart/complete/; returns the file UUID.
    private static func multipartUpload(
        _ file: DiskFile, publicKey: String, partSize: Int, session: URLSession
    ) async throws -> String {
        let (filename, contentType) = (file.filename, file.contentType)
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)

        let start = try await postForm(
            path: "multipart/start/",
            fields: [("UPLOADCARE_PUB_KEY", publicKey), ("UPLOADCARE_STORE", "1"),
                     ("filename", filename), ("size", "\(size)"),
                     ("part_size", "\(partSize)"), ("content_type", contentType)],
            session: session)
        guard let uuid = start["uuid"] as? String,
              let parts = start["parts"] as? [String] else { throw UploadcareError.invalidResponse }

        // ponytail: sequential parts, no retry; add bounded concurrency if long recordings upload too slowly
        for part in parts {
            guard let url = URL(string: part),
                  let chunk = try handle.read(upToCount: partSize), !chunk.isEmpty else {
                throw UploadcareError.invalidResponse
            }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = chunk
            let (data, response) = try await session.data(for: request)
            try checkStatus(data, response)
        }

        let complete = try await postForm(
            path: "multipart/complete/",
            fields: [("UPLOADCARE_PUB_KEY", publicKey), ("uuid", uuid)],
            session: session)
        guard let fileID = complete["uuid"] as? String else { throw UploadcareError.missingFileID }
        return fileID
    }

    /// A file on disk to upload in parts
    private struct DiskFile {
        let url: URL
        let filename: String
        let contentType: String
    }

    private struct FormFile {
        let filename: String
        let contentType: String
        let data: Data
    }

    /// POSTs a multipart/form-data request to the Upload API and returns the decoded JSON object.
    private static func postForm(path: String, fields: [(String, String)],
                                 file: FormFile? = nil,
                                 session: URLSession) async throws -> [String: Any] {
        let boundary = UUID().uuidString
        var request = URLRequest(url: uploadBaseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        for (name, value) in fields {
            body.appendMultipart(boundary: boundary, name: name, value: value)
        }
        if let file {
            body.append(Data("--\(boundary)\r\n".utf8))
            let safeFilename = file.filename.replacingOccurrences(of: "\"", with: "\\\"")
            body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename)\"\r\n".utf8))
            body.append(Data("Content-Type: \(file.contentType)\r\n\r\n".utf8))
            body.append(file.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try checkStatus(data, response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UploadcareError.missingFileID
        }
        return json
    }

    private static func checkStatus(_ data: Data, _ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UploadcareError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw UploadcareError.serverError(message)
        }
    }
}

private extension Data {
    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        append(Data("\(value)\r\n".utf8))
    }
}
