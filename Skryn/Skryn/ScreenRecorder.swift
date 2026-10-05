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

/// Records a region of one display to an MP4 (H.264), with system audio and microphone as `RecordingOptions` say.
/// ScreenCaptureKit writes the file itself via `SCRecordingOutput`.
@available(macOS 15.0, *)
@MainActor
final class ScreenRecorder: NSObject {
    /// Called when the recording ends without `stop()`: with an error when capture failed, with nil
    /// when it was stopped from outside Skryn (the system's screen recording button in the menu bar).
    /// Call `stop()` afterwards to collect the file.
    var onUnexpectedStop: ((Error?) -> Void)?

    private let displayID: CGDirectDisplayID
    private let sourceRect: CGRect
    private let scale: CGFloat
    private let options: RecordingOptions
    /// Skryn's own windows (keystroke overlay, webcam bubble) that are recorded although the app is excluded
    private let capturedWindowIDs: [CGWindowID]
    private let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("skryn-\(UUID().uuidString).mp4")

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var isStopping = false
    /// Set once the recording output finished (successfully or not) before `stop()` started waiting.
    private var finishResult: Result<Void, Error>?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    /// True when the microphone was requested but access is denied; the recording goes on without it.
    private(set) var microphoneUnavailable = false

    init(
        displayID: CGDirectDisplayID, sourceRect: CGRect, scale: CGFloat,
        options: RecordingOptions, capturedWindowIDs: [CGWindowID]
    ) {
        self.displayID = displayID
        self.sourceRect = sourceRect
        self.scale = scale
        self.options = options
        self.capturedWindowIDs = capturedWindowIDs
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
        let filter = SCContentFilter(
            display: display, excludingApplications: excludedApps, exceptingWindows: capturedWindows(in: content)
        )

        var useMicrophone = false
        if options.microphone {
            useMicrophone = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneUnavailable = !useMicrophone
            if !useMicrophone { print("ScreenRecorder: microphone access denied, recording without mic") }
        }
        let config = streamConfiguration(captureMicrophone: useMicrophone)

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
        print("ScreenRecorder: recording \(config.width)x\(config.height) to \(outputURL.path)")
    }

    /// Windows to record despite the app exclusion. Windows that aren't on screen are skipped.
    private func capturedWindows(in content: SCShareableContent) -> [SCWindow] {
        let windows = content.windows.filter { capturedWindowIDs.contains($0.windowID) }
        for id in capturedWindowIDs where !windows.contains(where: { $0.windowID == id }) {
            print("ScreenRecorder: window \(id) not found, it won't be recorded")
        }
        return windows
    }

    private func streamConfiguration(captureMicrophone: Bool) -> SCStreamConfiguration {
        let size = Self.outputPixelSize(for: sourceRect, scale: scale)
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = size.width
        config.height = size.height
        config.scalesToFit = false
        config.showsCursor = options.showCursor
        config.showMouseClicks = options.highlightClicks
        // The click highlight is only drawn in BGRA frames (SCStream.h)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(OutputSettings.current.frameRate))
        config.capturesAudio = options.systemAudio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = captureMicrophone
        if captureMicrophone, let deviceID = options.microphoneDeviceID {
            config.microphoneCaptureDeviceID = deviceID
        }
        return config
    }

    private static let finishTimedOut = NSError(
        domain: "ScreenRecorder", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "ScreenCaptureKit didn't finish the recording"]
    )

    /// Stops capture and waits until ScreenCaptureKit has finished writing the file.
    /// After a failure (e.g. the display went away) the partial file is still returned if it plays.
    func stop() async throws -> URL {
        isStopping = true
        var result = finishResult
        if result == nil, let stream, let recordingOutput {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    finishContinuation = continuation
                    // A dead stream may never report the end of the file; give up after a few seconds
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(5))
                        self?.recordingFinished(.failure(Self.finishTimedOut))
                    }
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
        guard !isStopping else { return }
        // A clean finish we didn't ask for: the system's stop button ended the recording
        switch result {
        case .success: onUnexpectedStop?(nil)
        case .failure(let error): onUnexpectedStop?(ScreenRecorderError.failed(error))
        }
    }

    private func streamStopped(_ error: Error) {
        guard !isStopping else { return }
        print("ScreenRecorder: stream stopped — \(error)")
        let stoppedByUser = (error as NSError).code == SCStreamError.Code.userStopped.rawValue
        onUnexpectedStop?(stoppedByUser ? nil : ScreenRecorderError.failed(error))
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
