import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox
import libwebp

enum VideoExporterError: LocalizedError {
    case noVideoTrack, exportFailed(String), encodingFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The recording has no video."
        case .exportFailed(let reason): "Couldn't convert the recording: \(reason)"
        case .encodingFailed: "Couldn't encode the animation."
        }
    }
}

/// Converts finished recordings (MP4 / H.264 from `ScreenRecorder`) into the format picked in Settings.
///
/// Animated images sample the clip on a fixed timeline (GIF 12.5 fps so every delay is an exact 8 cs, WebP 15 fps),
/// drop audio, and decode frames one at a time with `AVAssetReader` so long clips don't pile up in memory.
/// GIF is capped at 800 px wide (after the Retina-off halving), since it gets huge fast; WebP keeps the full width.
enum VideoExporter {
    /// Export progress, 0...1, reported on the main actor
    typealias Progress = @MainActor (Double) -> Void

    static let gifFrameRate = 12.5
    static let webpFrameRate = 15.0
    static let gifMaxWidth: CGFloat = 800

    /// Converts a finished recording (MP4, H.264, from ScreenRecorder) into `settings.videoFormat` at the
    /// chosen resolution. Returns a new temp file `skryn-<UUID>.<ext>`; the caller owns both files.
    /// Returns `source` itself when nothing needs to change (MP4 H.264, Retina) — no re-encode.
    /// `progress` (0...1) is called on the main actor.
    static func export(_ source: URL, settings: OutputSettings, progress: Progress? = nil) async throws -> URL {
        let format = settings.videoFormat
        if format == .mp4H264 && settings.retina { return source }
        let output = FileManager.default.skrynTemporaryFile(extension: format.fileExtension)
        let asset = AVURLAsset(url: source)
        do {
            switch format {
            case .gif: try await writeGIF(asset, retina: settings.retina, to: output, progress: progress)
            case .webp: try await writeWebP(asset, retina: settings.retina, to: output, progress: progress)
            case .mp4H264, .mp4HEVC, .mov:
                try await exportVideo(asset, settings: settings, to: output, progress: progress)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        await progress?(1)
        return output
    }

    /// Copies `range` of a recording into a new temp MP4 (no re-encode). The caller owns the file.
    static func trim(_ asset: AVAsset, range: CMTimeRange) async throws -> URL {
        // ponytail: recording itself needs macOS 15, so there's no pre-15 export path
        guard #available(macOS 15, *),
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
        else { throw CocoaError(.featureUnsupported) }
        let output = FileManager.default.skrynTemporaryFile(extension: "mp4")
        session.timeRange = range
        do {
            try await session.export(to: output, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    // MARK: - MP4 / MOV

    private static func exportVideo(
        _ asset: AVURLAsset, settings: OutputSettings, to output: URL, progress: Progress?
    ) async throws {
        // ponytail: recording itself needs macOS 15, so there's no pre-15 export path
        guard #available(macOS 15, *) else { throw CocoaError(.featureUnsupported) }
        let preset = switch settings.videoFormat {
        case .mp4HEVC: AVAssetExportPresetHEVCHighestQuality
        default: settings.retina ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw VideoExporterError.exportFailed("unsupported preset")
        }
        if !settings.retina {
            session.videoComposition = try await halfSizeComposition(asset, frameRate: settings.frameRate.rawValue)
        }
        session.shouldOptimizeForNetworkUse = true
        let monitor = Task {
            for await state in session.states(updateInterval: 0.1) {
                if case .exporting(let exportProgress) = state { await progress?(exportProgress.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        do {
            try await session.export(to: output, as: settings.videoFormat == .mov ? .mov : .mp4)
        } catch {
            throw VideoExporterError.exportFailed(error.localizedDescription)
        }
    }

    /// Scales the video track to half size (Retina off).
    private static func halfSizeComposition(_ asset: AVAsset, frameRate: Int) async throws -> AVVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoExporterError.noVideoTrack
        }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let duration = try await asset.load(.duration)
        let target = evenPixelSize(size, scale: 0.5, rounding: .down)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let scale = CGAffineTransform(scaleX: target.width / size.width, y: target.height / size.height)
        layer.setTransform(transform.concatenating(scale), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = target
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(frameRate, 1)))
        composition.instructions = [instruction]
        return composition
    }

    /// `size × scale` in whole pixels, made even (H.264 and friends want even dimensions) and at least 2.
    /// The recorder rounds its point sizes to the nearest pixel; scaling an existing video rounds down.
    static func evenPixelSize(_ size: CGSize, scale: CGFloat, rounding: FloatingPointRoundingRule) -> CGSize {
        func even(_ value: CGFloat) -> CGFloat { CGFloat(max(2, Int((value * scale).rounded(rounding)) & ~1)) }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    // MARK: - GIF

    private static func writeGIF(
        _ asset: AVAsset, retina: Bool, to output: URL, progress: Progress?
    ) async throws {
        let plan = try await FramePlan(asset, retina: retina, fps: gifFrameRate, maxWidth: gifMaxWidth)
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, UTType.gif.identifier as CFString, plan.count, nil
        ) else { throw VideoExporterError.encodingFailed }
        // Per-frame color maps keep ImageIO from buffering every frame until finalize to build a global one.
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFLoopCount: 0, kCGImagePropertyGIFHasGlobalColorMap: false
        ]] as CFDictionary)
        let delay = 1 / plan.fps
        let frameProperties = [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay
        ]] as CFDictionary
        try await plan.forEachFrame(progress: progress) { context, _ in
            guard let image = context.makeImage() else { throw VideoExporterError.encodingFailed }
            CGImageDestinationAddImage(destination, image, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { throw VideoExporterError.encodingFailed }
    }

    // MARK: - WebP

    private static func writeWebP(
        _ asset: AVAsset, retina: Bool, to output: URL, progress: Progress?
    ) async throws {
        let plan = try await FramePlan(asset, retina: retina, fps: webpFrameRate, maxWidth: nil)
        var options = WebPAnimEncoderOptions()
        var config = WebPConfig()
        var picture = WebPPicture()
        guard WebPAnimEncoderOptionsInit(&options) != 0, WebPConfigInit(&config) != 0, WebPPictureInit(&picture) != 0
        else { throw VideoExporterError.encodingFailed }
        options.allow_mixed = 1
        options.anim_params.loop_count = 0
        config.quality = 80
        config.method = 4
        picture.use_argb = 1
        picture.width = Int32(plan.size.width)
        picture.height = Int32(plan.size.height)
        guard let encoder = WebPAnimEncoderNew(picture.width, picture.height, &options) else {
            throw VideoExporterError.encodingFailed
        }
        defer {
            WebPAnimEncoderDelete(encoder)
            WebPPictureFree(&picture)
        }
        let timestamp = { (index: Int) in Int32((Double(index) * 1000 / plan.fps).rounded()) }
        try await plan.forEachFrame(progress: progress) { context, index in
            guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self),
                  WebPPictureImportBGRX(&picture, pixels, Int32(context.bytesPerRow)) != 0,
                  WebPAnimEncoderAdd(encoder, &picture, timestamp(index), &config) != 0
            else { throw VideoExporterError.encodingFailed }
        }
        var webp = WebPData()
        defer { WebPDataClear(&webp) }
        guard WebPAnimEncoderAdd(encoder, nil, timestamp(plan.count), nil) != 0,
              WebPAnimEncoderAssemble(encoder, &webp) != 0, let bytes = webp.bytes
        else { throw VideoExporterError.encodingFailed }
        try Data(bytes: bytes, count: webp.size).write(to: output)
    }
}

// MARK: - Frame sampling

/// A fixed-rate timeline over the clip's video track, at the output size of an animated image.
private struct FramePlan {
    let asset: AVAsset
    let track: AVAssetTrack
    let size: CGSize
    let fps: Double
    let count: Int

    init(_ asset: AVAsset, retina: Bool, fps: Double, maxWidth: CGFloat?) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoExporterError.noVideoTrack
        }
        let natural = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        var factor: CGFloat = retina ? 1 : 0.5
        if let maxWidth, natural.width * factor > maxWidth { factor = maxWidth / natural.width }
        self.asset = asset
        self.track = track
        size = VideoExporter.evenPixelSize(natural, scale: factor, rounding: .down)
        self.fps = fps
        count = max(1, Int((duration * fps).rounded(.up)))
    }

    /// Decodes the track in order and calls `body` once per timeline slot with that moment's frame drawn
    /// into a reused BGRX context. A slot shows the latest source frame at or before its time, so static
    /// stretches of a variable-frame-rate recording repeat the frame.
    func forEachFrame(
        progress: VideoExporter.Progress?, body: (CGContext, Int) throws -> Void
    ) async throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading(), let context = makeContext() else { throw VideoExporterError.encodingFailed }
        let rect = CGRect(origin: .zero, size: size)
        var slot = 0
        var current: CGImage?
        while slot < count {
            try Task.checkCancellation()
            let sample = output.copyNextSampleBuffer()
            if sample == nil, reader.status == .failed {
                throw VideoExporterError.exportFailed(reader.error?.localizedDescription ?? "unreadable video")
            }
            let time = sample.map { CMSampleBufferGetPresentationTimeStamp($0).seconds } ?? .infinity
            while slot < count, let current, Double(slot) / fps < time {
                context.draw(current, in: rect)
                try body(context, slot)
                slot += 1
                await progress?(Double(slot) / Double(count))
            }
            guard let sample else { break }
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                var image: CGImage?
                VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
                current = image ?? current
            }
        }
        reader.cancelReading()
        guard slot == count else { throw VideoExporterError.encodingFailed }
    }

    private func makeContext() -> CGContext? {
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        context?.interpolationQuality = .high
        return context
    }
}

extension FileManager {
    /// A new, unique `skryn-<UUID>.<ext>` URL in the temp folder (recordings, trims, conversions)
    func skrynTemporaryFile(extension ext: String) -> URL {
        temporaryDirectory.appendingPathComponent("skryn-\(UUID().uuidString).\(ext)")
    }
}
