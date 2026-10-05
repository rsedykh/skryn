import CoreGraphics
import Foundation
import ImageIO
import libwebp
import UniformTypeIdentifiers

enum ImageEncoderError: LocalizedError {
    case unsupported(ImageFormat), encodingFailed(ImageFormat)

    var errorDescription: String? {
        switch self {
        case .unsupported(let format): "\(format.title) isn't supported on this Mac"
        case .encodingFailed(let format): "Could not encode \(format.title)"
        }
    }
}

enum ImageEncoder {
    /// Encodes a screenshot for saving/uploading. `pointSize` is the image's size in points (the editor's
    /// NSImage size); with `settings.retina == false` the output is scaled to points (1x), high quality.
    static func encode(_ image: CGImage, pointSize: CGSize, settings: OutputSettings) throws -> Data {
        let format = settings.imageFormat
        guard availableFormats.contains(format) else { throw ImageEncoderError.unsupported(format) }
        let size = scaledSize(pixel: CGSize(width: image.width, height: image.height), point: pointSize, retina: settings.retina)
        guard let bitmap = Bitmap(image, width: size.width, height: size.height, keepAlpha: format != .jpeg)
        else { throw ImageEncoderError.encodingFailed(format) }

        let data: Data? = switch format {
        case .webp: webp(bitmap, lossless: settings.imageLossless, quality: settings.imageQuality)
        case .pdf: bitmap.cgImage.flatMap { pdf($0, pageSize: pointSize) }
        case .png, .jpeg, .avif, .heic: bitmap.cgImage.flatMap { imageIO($0, format: format, settings: settings, pointSize: pointSize) }
        }
        guard let data else { throw ImageEncoderError.encodingFailed(format) }
        return data
    }

    /// Formats this Mac can encode right now (AVIF/HEIC depend on the OS); WebP and PNG/JPEG/PDF always.
    static let availableFormats: [ImageFormat] = {
        let encodable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return ImageFormat.allCases.filter { format in
            guard let type = utType(format) else { return true }
            return encodable.contains(type.identifier)
        }
    }()

    /// Output pixel size: the source pixels for Retina, else the point size (at least 1×1).
    static func scaledSize(pixel: CGSize, point: CGSize, retina: Bool) -> (width: Int, height: Int) {
        let size = retina ? pixel : point
        return (max(1, Int(size.width.rounded())), max(1, Int(size.height.rounded())))
    }

    /// ImageIO type for formats ImageIO encodes; nil for WebP and PDF, which are encoded here.
    static func utType(_ format: ImageFormat) -> UTType? {
        switch format {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .avif: UTType("public.avif")
        case .webp, .pdf: nil
        }
    }

    // MARK: - Encoders

    private static func imageIO(_ image: CGImage, format: ImageFormat, settings: OutputSettings, pointSize: CGSize) -> Data? {
        guard let type = utType(format) else { return nil }
        // Only properties set here are written: the bitmap is freshly drawn, so no capture metadata carries over.
        var properties: [CFString: Any] = [:]
        if format != .png {
            // ImageIO has no true lossless AVIF/HEIC: 1.0 is its best (HEIC: off by 1–2 levels after YUV),
            // and the AVIF encoder fails at 1.0 outright, while its output stops changing above 0.99.
            let lossless = format.hasLosslessOption && settings.imageLossless
            let best = format == .avif ? 0.99 : 1.0
            properties[kCGImageDestinationLossyCompressionQuality] = lossless ? best : settings.imageQuality
        }
        if !settings.stripMetadata, pointSize.width > 0 {
            let dpi = 72 * Double(image.width) / pointSize.width
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }
        return imageData(from: image, type: type, properties: properties)
    }

    /// `image` written by ImageIO as `type` (the clipboard's PNG and TIFF, and the formats above).
    static func imageData(from image: CGImage, type: UTType, properties: [CFString: Any] = [:]) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    private static func pdf(_ image: CGImage, pageSize: CGSize) -> Data? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPDFPage(nil)
        context.interpolationQuality = .high
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private static func webp(_ bitmap: Bitmap, lossless: Bool, quality: Double) -> Data? {
        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { return nil }
        if lossless {
            WebPConfigLosslessPreset(&config, 6) // method 4, quality 75: cwebp's default lossless effort
        } else {
            config.quality = Float(min(max(quality, 0), 1) * 100)
            config.method = 4
        }
        config.exact = 0
        guard WebPValidateConfig(&config) != 0 else { return nil }

        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { return nil }
        defer { WebPPictureFree(&picture) }
        picture.use_argb = lossless ? 1 : 0
        picture.width = Int32(bitmap.width)
        picture.height = Int32(bitmap.height)
        let stride = Int32(bitmap.width * 4)
        let straight = bitmap.straightRGBA()
        let imported = straight.withUnsafeBytes { raw -> Int32 in
            let pixels = raw.bindMemory(to: UInt8.self).baseAddress
            return bitmap.hasAlpha
                ? WebPPictureImportRGBA(&picture, pixels, stride)
                : WebPPictureImportRGBX(&picture, pixels, stride)
        }
        guard imported != 0 else { return nil }

        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }
        let encoded = withUnsafeMutablePointer(to: &writer) { writerPointer -> Int32 in
            picture.writer = WebPMemoryWrite
            picture.custom_ptr = UnsafeMutableRawPointer(writerPointer)
            return WebPEncode(&config, &picture)
        }
        guard encoded != 0, let mem = writer.mem else { return nil }
        return Data(bytes: mem, count: writer.size)
    }
}

/// An 8-bit sRGB RGBA bitmap (premultiplied, rows packed) the screenshot is redrawn into before encoding:
/// converts colors to sRGB, scales to the output size, and tells whether any pixel is actually transparent.
private struct Bitmap {
    let width: Int, height: Int
    let pixels: Data
    let hasAlpha: Bool

    init?(_ image: CGImage, width: Int, height: Int, keepAlpha: Bool) {
        var pixels = Data(count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: Self.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let sourceHasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        self.width = width
        self.height = height
        self.pixels = pixels
        hasAlpha = keepAlpha && sourceHasAlpha && pixels.withUnsafeBytes { raw in
            var index = 3
            while index < raw.count {
                if raw[index] != 255 { return true }
                index += 4
            }
            return false
        }
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Opaque bitmaps skip the alpha byte, so PNG/HEIC/AVIF write no alpha channel.
    var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        let alpha: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: Self.sRGB, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// Straight (unpremultiplied) RGBA, as libwebp expects. Opaque pixels are unchanged.
    func straightRGBA() -> Data {
        guard hasAlpha else { return pixels }
        var straight = pixels
        straight.withUnsafeMutableBytes { raw in
            var index = 0
            while index < raw.count {
                let alpha = Int(raw[index + 3])
                if alpha > 0 && alpha < 255 {
                    for channel in index..<index + 3 {
                        raw[channel] = UInt8(min(255, (Int(raw[channel]) * 255 + alpha / 2) / alpha))
                    }
                }
                index += 4
            }
        }
        return straight
    }
}
