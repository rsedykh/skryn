import AVFoundation
import ImageIO
import libwebp
import XCTest
@testable import Skryn

final class VideoExporterTests: XCTestCase {
    private static var source: URL!
    private var outputs: [URL] = []

    /// A 1 s, 64×48, 30 fps H.264 MP4 whose solid color changes every frame. Built once for the whole class.
    override static func setUp() {
        super.setUp()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("skryn-test-\(UUID().uuidString).mp4")
        let done = expectation(writingSyntheticVideoTo: url)
        _ = XCTWaiter.wait(for: [done], timeout: 10)
        source = url
    }

    override static func tearDown() {
        try? FileManager.default.removeItem(at: source)
        super.tearDown()
    }

    override func tearDown() {
        outputs.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private static func expectation(writingSyntheticVideoTo url: URL) -> XCTestExpectation {
        let done = XCTestExpectation(description: "synthetic video")
        // swiftlint:disable:next force_try
        let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            fill(buffer!, shade: UInt8(frame * 8))
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 30, timescale: 30))
        writer.finishWriting { done.fulfill() }
        return done
    }

    private static func fill(_ buffer: CVPixelBuffer, shade: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<48 {
            for col in 0..<64 {
                let pixel = bytes + row * rowBytes + col * 4
                pixel[0] = shade; pixel[1] = 255 - shade; pixel[2] = UInt8(col * 4); pixel[3] = 255
            }
        }
    }

    private func export(_ format: VideoFormat, retina: Bool = true) async throws -> URL {
        var settings = OutputSettings()
        settings.videoFormat = format
        settings.retina = retina
        let url = try await VideoExporter.export(Self.source, settings: settings)
        if url != Self.source { outputs.append(url) }
        XCTAssertEqual(url.pathExtension, format.fileExtension)
        return url
    }

    private struct VideoInfo {
        let size: CGSize
        let codec: FourCharCode
        let duration: Double
    }

    /// Video track size, its codec FourCC, and the duration in seconds.
    private func videoInfo(_ url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let (size, descriptions) = try await track.load(.naturalSize, .formatDescriptions)
        let codec = CMFormatDescriptionGetMediaSubType(try XCTUnwrap(descriptions.first))
        let duration = try await asset.load(.duration)
        return VideoInfo(size: size, codec: codec, duration: duration.seconds)
    }

    private func fourCC(_ string: String) -> FourCharCode {
        string.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    func testH264RetinaIsPassthrough() async throws {
        let url = try await export(.mp4H264)
        XCTAssertEqual(url, Self.source)
    }

    func testH264RetinaOffHalvesSize() async throws {
        let info = try await videoInfo(export(.mp4H264, retina: false))
        XCTAssertEqual(info.size, CGSize(width: 32, height: 24))
        XCTAssertEqual(info.codec, fourCC("avc1"))
        XCTAssertEqual(info.duration, 1, accuracy: 0.1)
    }

    func testHEVC() async throws {
        let info = try await videoInfo(export(.mp4HEVC))
        XCTAssertTrue([fourCC("hvc1"), fourCC("hev1")].contains(info.codec))
        XCTAssertEqual(info.size, CGSize(width: 64, height: 48))
        XCTAssertEqual(info.duration, 1, accuracy: 0.1)
    }

    func testMOV() async throws {
        let url = try await export(.mov)
        let info = try await videoInfo(url)
        XCTAssertEqual(info.size, CGSize(width: 64, height: 48))
        XCTAssertEqual(info.duration, 1, accuracy: 0.1)
        let halved = try await videoInfo(export(.mov, retina: false))
        XCTAssertEqual(halved.size, CGSize(width: 32, height: 24))
    }

    func testGIF() async throws {
        let url = try await export(.gif)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), Int((VideoExporter.gifFrameRate).rounded(.up)))
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        XCTAssertEqual(gif?[kCGImagePropertyGIFLoopCount] as? Int, 0)
        let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(frame.width, 64)
    }

    func testWebPIsAnimated() async throws {
        let url = try await export(.webp, retina: false)
        let data = try Data(contentsOf: url)
        // Frame count, canvas width, loop count
        let info = data.withUnsafeBytes { raw -> [UInt32] in
            var webp = WebPData(bytes: raw.bindMemory(to: UInt8.self).baseAddress, size: raw.count)
            guard let demux = WebPDemux(&webp) else { return [0, 0, 1] }
            defer { WebPDemuxDelete(demux) }
            return [WEBP_FF_FRAME_COUNT, WEBP_FF_CANVAS_WIDTH, WEBP_FF_LOOP_COUNT].map { WebPDemuxGetI(demux, $0) }
        }
        XCTAssertGreaterThan(info[0], 1)
        XCTAssertEqual(info[1], 32)
        XCTAssertEqual(info[2], 0)
    }

    func testScaledSizeIsEven() {
        XCTAssertEqual(VideoExporter.evenPixelSize(CGSize(width: 3456, height: 2234), scale: 0.5, rounding: .down),
                       CGSize(width: 1728, height: 1116))
        XCTAssertEqual(VideoExporter.evenPixelSize(CGSize(width: 101, height: 3), scale: 0.5, rounding: .down),
                       CGSize(width: 50, height: 2))
    }
}
