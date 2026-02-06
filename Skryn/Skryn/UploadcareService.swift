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

    /// Uploads PNG data to Uploadcare and returns the CDN URL.
    static func upload(pngData: Data, filename: String, publicKey: String,
                       session: URLSession = .shared) async throws -> String {
        let boundary = UUID().uuidString

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // UPLOADCARE_PUB_KEY
        body.appendMultipart(boundary: boundary, name: "UPLOADCARE_PUB_KEY", value: publicKey)

        // UPLOADCARE_STORE
        body.appendMultipart(boundary: boundary, name: "UPLOADCARE_STORE", value: "1")

        // File data
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: image/png\r\n\r\n".utf8))
        body.append(pngData)
        body.append(Data("\r\n".utf8))

        // Closing boundary
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

        return "https://ucarecdn.com/\(fileID)/"
    }

    /// Uploads arbitrary file data to Uploadcare with a specified content type.
    static func upload(fileData: Data, filename: String, contentType: String,
                       publicKey: String, session: URLSession = .shared) async throws -> String {
        let boundary = UUID().uuidString

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        body.appendMultipart(boundary: boundary, name: "UPLOADCARE_PUB_KEY", value: publicKey)
        body.appendMultipart(boundary: boundary, name: "UPLOADCARE_STORE", value: "1")

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
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

        return "https://ucarecdn.com/\(fileID)/"
    }
}

private extension Data {
    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        append(Data("\(value)\r\n".utf8))
    }
}
