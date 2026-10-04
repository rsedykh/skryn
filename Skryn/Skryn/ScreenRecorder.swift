import AVFoundation
import ScreenCaptureKit

enum ScreenRecorderError: LocalizedError {
    case permissionDenied
    case displayNotFound
    case failed(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Screen recording failed: Screen Recording permission is missing"
        case .displayNotFound: return "Screen recording failed: display not found"
        case .failed(let error): return "Screen recording failed: \(error.localizedDescription)"
        }
    }
}

/// Records a region of one display to an MP4 (H.264) with system audio and, if allowed, the microphone.
/// ScreenCaptureKit writes the file itself via `SCRecordingOutput`.
@available(macOS 15.0, *)
@MainActor
final class ScreenRecorder: NSObject {
    var onUnexpectedStop: ((Error) -> Void)?

    private let displayID: CGDirectDisplayID
    private let sourceRect: CGRect
    private let scale: CGFloat
    private let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("skryn-\(UUID().uuidString).mp4")

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var isStopping = false
    /// Set once the recording output finished (successfully or not) before `stop()` started waiting.
    private var finishResult: Result<Void, Error>?
    private var finishContinuation: CheckedContinuation<Void, Error>?

    init(displayID: CGDirectDisplayID, sourceRect: CGRect, scale: CGFloat) {
        self.displayID = displayID
        self.sourceRect = sourceRect
        self.scale = scale
    }

    /// Pixel size of the recording: rect × scale, rounded down to even numbers (H.264 needs even dimensions).
    static func outputPixelSize(for rect: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        func even(_ value: CGFloat) -> Int { max(2, Int((value * scale).rounded()) & ~1) }
        return (even(rect.width), even(rect.height))
    }

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            print("ScreenRecorder: failed to get shareable content — \(error)")
            throw CGPreflightScreenCaptureAccess() ? ScreenRecorderError.failed(error) : .permissionDenied
        }

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            print("ScreenRecorder: display not found")
            throw ScreenRecorderError.displayNotFound
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excludedApps = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        if !micGranted { print("ScreenRecorder: microphone access denied, recording without mic") }

        let size = Self.outputPixelSize(for: sourceRect, scale: scale)
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = size.width
        config.height = size.height
        config.scalesToFit = false
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = micGranted

        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = outputURL
        recordingConfig.videoCodecType = .h264
        recordingConfig.outputFileType = .mp4

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)
        do {
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
        } catch {
            print("ScreenRecorder: failed to start — \(error)")
            throw ScreenRecorderError.failed(error)
        }
        self.stream = stream
        self.recordingOutput = output
        print("ScreenRecorder: recording \(size.width)x\(size.height) to \(outputURL.path)")
    }

    /// Stops capture and waits until ScreenCaptureKit has finished writing the file.
    /// After a failure (e.g. the display went away) the partial file is still returned if it plays.
    func stop() async throws -> URL {
        isStopping = true
        var result = finishResult
        if result == nil, let stream, let recordingOutput {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    finishContinuation = continuation
                    do {
                        // Removing the output finalizes the file; the delegate resumes the continuation.
                        try stream.removeRecordingOutput(recordingOutput)
                    } catch {
                        finishContinuation = nil
                        continuation.resume(throwing: error)
                    }
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }
        }
        // Stop on every path, or the Screen Recording indicator stays on
        try? await stream?.stopCapture()
        stream = nil
        recordingOutput = nil

        if case .failure(let error)? = result {
            let playable = (try? await AVURLAsset(url: outputURL).load(.isPlayable)) ?? false
            guard playable else {
                try? FileManager.default.removeItem(at: outputURL)
                throw error as? ScreenRecorderError ?? .failed(error)
            }
        }
        return outputURL
    }

    private func recordingFinished(_ result: Result<Void, Error>) {
        if let continuation = finishContinuation {
            finishContinuation = nil
            continuation.resume(with: result.mapError { ScreenRecorderError.failed($0) })
            return
        }
        guard finishResult == nil else { return }
        finishResult = result
        if case .failure(let error) = result, !isStopping {
            onUnexpectedStop?(ScreenRecorderError.failed(error))
        }
    }

    private func streamStopped(_ error: Error) {
        guard !isStopping else { return }
        print("ScreenRecorder: stream stopped — \(error)")
        onUnexpectedStop?(ScreenRecorderError.failed(error))
    }
}

@available(macOS 15.0, *)
extension ScreenRecorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.streamStopped(error) }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.recordingFinished(.success(())) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        print("ScreenRecorder: recording failed — \(error)")
        Task { @MainActor in self.recordingFinished(.failure(error)) }
    }
}
