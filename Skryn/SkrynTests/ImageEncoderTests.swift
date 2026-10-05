import CoreGraphics
import ImageIO
import libwebp
import XCTest
@testable import Skryn

final class ImageEncoderTests: XCTestCase {
    private let width = 40, height = 20
    private let pointSize = CGSize(width: 20, height: 10)

    /// Opaque sRGB gradient, so lossless round trips can be compared byte for byte.
    private func gradient(alpha: Bool = false) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                bytes[index] = UInt8(x * 6)
                bytes[index + 1] = UInt8(y * 12)
                bytes[index + 2] = UInt8((x + y) * 4)
                if alpha && x < 10 { bytes[index + 3] = 0; bytes[index] = 0; bytes[index + 1] = 0; bytes[index + 2] = 0 }
            }
        }
        let info: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
        let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue
        )!
        return context.makeImage()!
    }

    private func encode(_ format: ImageFormat, retina: Bool = true, lossless: Bool = true,
                        quality: Double = 0.85, alpha: Bool = false) throws -> Data {
        var settings = OutputSettings()
        settings.imageFormat = format
        settings.retina = retina
        settings.imageLossless = lossless
        settings.imageQuality = quality
        return try ImageEncoder.encode(gradient(alpha: alpha), pointSize: pointSize, settings: settings)
    }

    private struct Decoded {
        let width: Int
        let height: Int
        let rgba: [UInt8]
    }

    /// RGBA bytes (row 0 = top) and size of encoded data, decoded with libwebp for WebP, ImageIO otherwise.
    private func decode(_ data: Data, format: ImageFormat) -> Decoded? {
        if format == .webp {
            var decodedWidth: Int32 = 0, decodedHeight: Int32 = 0
            return data.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self).baseAddress
                guard let rgba = WebPDecodeRGBA(bytes, data.count, &decodedWidth, &decodedHeight) else { return nil }
                defer { WebPFree(rgba) }
                let count = Int(decodedWidth * decodedHeight * 4)
                let pixels = Array(UnsafeBufferPointer(start: rgba, count: count))
                return Decoded(width: Int(decodedWidth), height: Int(decodedHeight), rgba: pixels)
            }
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return Decoded(width: image.width, height: image.height, rgba: image.rgbaBytes())
    }

    private func maxDifference(_ data: Data, format: ImageFormat) throws -> Int {
        let decoded = try XCTUnwrap(decode(data, format: format))
        return zip(decoded.rgba, gradient().rgbaBytes()).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    // MARK: - Tests

    func testScaledSize() {
        let pixel = CGSize(width: 40, height: 20), point = CGSize(width: 20, height: 10)
        XCTAssertTrue(ImageEncoder.scaledSize(pixel: pixel, point: point, retina: true) == (40, 20))
        XCTAssertTrue(ImageEncoder.scaledSize(pixel: pixel, point: point, retina: false) == (20, 10))
        XCTAssertTrue(ImageEncoder.scaledSize(pixel: pixel, point: CGSize(width: 0.2, height: 9.6), retina: false) == (1, 10))
    }

    func testAvailableFormatsAlwaysIncludeBaseline() {
        for format in [ImageFormat.png, .jpeg, .webp, .pdf] {
            XCTAssertTrue(ImageEncoder.availableFormats.contains(format), format.title)
        }
    }

    func testDimensionsForEveryAvailableFormat() throws {
        for format in ImageEncoder.availableFormats where format != .pdf {
            for retina in [true, false] {
                let decoded = try XCTUnwrap(decode(try encode(format, retina: retina), format: format), format.title)
                XCTAssertEqual(decoded.width, retina ? 40 : 20, format.title)
                XCTAssertEqual(decoded.height, retina ? 20 : 10, format.title)
            }
        }
    }

    func testPDFIsOnePageAtPointSize() throws {
        for retina in [true, false] {
            let data = try encode(.pdf, retina: retina)
            let document = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
            XCTAssertEqual(document.numberOfPages, 1)
            XCTAssertEqual(document.page(at: 1)?.getBoxRect(.mediaBox).size, pointSize)
        }
    }

    func testLosslessRoundTrips() throws {
        let png = try XCTUnwrap(decode(try encode(.png), format: .png))
        XCTAssertEqual(png.rgba, gradient().rgbaBytes())
        XCTAssertEqual(try maxDifference(encode(.webp), format: .webp), 0)
    }

    func testLossyWebPDiffersButIsClose() throws {
        let difference = try maxDifference(encode(.webp, lossless: false, quality: 0.9), format: .webp)
        XCTAssertLessThan(difference, 40)
    }

    func testJPEGIsSmallerAtLowerQuality() throws {
        XCTAssertLessThan(try encode(.jpeg, quality: 0.2).count, try encode(.jpeg, quality: 1).count)
    }

    func testOpaqueImagesDropAlphaAndTransparentKeepIt() throws {
        func hasAlpha(_ data: Data) -> Bool {
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            let alpha = CGImageSourceCreateImageAtIndex(source, 0, nil)!.alphaInfo
            return ![.none, .noneSkipFirst, .noneSkipLast].contains(alpha)
        }
        XCTAssertFalse(hasAlpha(try encode(.png)))
        XCTAssertTrue(hasAlpha(try encode(.png, alpha: true)))
        XCTAssertFalse(hasAlpha(try encode(.jpeg, alpha: true)))
        var features = WebPBitstreamFeatures()
        let webp = try encode(.webp, alpha: true)
        _ = webp.withUnsafeBytes { WebPGetFeatures($0.bindMemory(to: UInt8.self).baseAddress, webp.count, &features) }
        XCTAssertEqual(features.has_alpha, 1)
    }

    func testUnsupportedFormatThrows() throws {
        guard let missing = ImageFormat.allCases.first(where: { !ImageEncoder.availableFormats.contains($0) }) else {
            throw XCTSkip("Every format is encodable on this Mac")
        }
        XCTAssertThrowsError(try encode(missing))
    }

    /// ImageIO has no bit-exact AVIF/HEIC (YUV-based): "lossless" is its top quality, off by a few levels (AVIF: 8 on this steep gradient).
    func testHighQualityAVIFAndHEICAreNearLossless() throws {
        for format in [ImageFormat.avif, .heic] where ImageEncoder.availableFormats.contains(format) {
            let difference = try maxDifference(encode(format), format: format)
            XCTAssertLessThanOrEqual(difference, 12, format.title)
        }
    }
}

private extension CGImage {
    func rgbaBytes() -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return rgba
    }
}
