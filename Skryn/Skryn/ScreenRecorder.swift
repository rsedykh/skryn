import AVFoundation
import ScreenCaptureKit

enum ScreenRecorderError: LocalizedError {
    case permissionDenied
    case displayNotFound
    case failed(Error)
    case finishTimedOut

    var errorDescription: String? {
        switch self {
        case .finishTimedOut: return "Screen recording failed: ScreenCaptureKit didn't finish the recording"
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

    private let area: CaptureArea
    private let options: RecordingOptions
    private let frameRate: FrameRate
    /// Skryn's own windows (keystroke overlay, webcam bubble) that are recorded although the app is excluded
    private let capturedWindowIDs: [CGWindowID]
    private let outputURL = FileManager.default.skrynTemporaryFile(extension: "mp4")

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var stopRequested = false
    /// The recording output reports the end of the file once; `stop()` waits for it here
    private let (finished, finishedContinuation) = AsyncThrowingStream<Void, Error>.makeStream()
    private var hasFinished = false
    /// True when the microphone was requested but access is denied; the recording goes on without it.
    private(set) var microphoneUnavailable = false

    init(area: CaptureArea, options: RecordingOptions, frameRate: FrameRate, capturedWindowIDs: [CGWindowID]) {
        self.area = area
        self.options = options
        self.frameRate = frameRate
        self.capturedWindowIDs = capturedWindowIDs
    }

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            print("ScreenRecorder: failed to get shareable content — \(error)")
            throw CGPreflightScreenCaptureAccess() ? ScreenRecorderError.failed(error) : .permissionDenied
        }

        guard let display = content.displays.first(where: { $0.displayID == area.displayID }) else {
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
        let size = VideoExporter.evenPixelSize(area.rect.size, scale: area.scale, rounding: .toNearestOrAwayFromZero)
        let config = SCStreamConfiguration()
        config.sourceRect = area.rect
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.scalesToFit = false
        config.showsCursor = options.showCursor
        config.showMouseClicks = options.highlightClicks
        // The click highlight is only drawn in BGRA frames (SCStream.h)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate.rawValue))
        config.capturesAudio = options.systemAudio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = captureMicrophone
        if captureMicrophone, let deviceID = options.microphoneDeviceID {
            config.microphoneCaptureDeviceID = deviceID
        }
        return config
    }

    /// Stops capture and waits until ScreenCaptureKit has finished writing the file.
    /// After a failure (e.g. the display went away) the partial file is still returned if it plays.
    func stop() async throws -> URL {
        stopRequested = true
        var failure: Error?
        if let stream, let recordingOutput {
            do {
                // Removing the output finalizes the file (unless it already ended); the delegate reports the end
                if !hasFinished { try stream.removeRecordingOutput(recordingOutput) }
                try await waitUntilFinished()
            } catch {
                failure = error
            }
        }
        // Stop on every path, or the Screen Recording indicator stays on
        try? await stream?.stopCapture()
        stream = nil
        recordingOutput = nil

        if let failure {
            let playable = (try? await AVURLAsset(url: outputURL).load(.isPlayable)) ?? false
            guard playable else {
                try? FileManager.default.removeItem(at: outputURL)
                throw failure as? ScreenRecorderError ?? .failed(failure)
            }
        }
        return outputURL
    }

    /// A dead stream may never report the end of the file; give up after a few seconds
    private func waitUntilFinished() async throws {
        try await withThrowingTaskGroup(of: Void.self) { [finished] group in
            group.addTask {
                for try await _ in finished { return }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw ScreenRecorderError.finishTimedOut
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func recordingFinished(_ result: Result<Void, Error>) {
        guard !hasFinished else { return }
        hasFinished = true
        switch result {
        case .success:
            finishedContinuation.yield()
            finishedContinuation.finish()
        case .failure(let error):
            finishedContinuation.finish(throwing: ScreenRecorderError.failed(error))
        }
        guard !stopRequested else { return }
        // An end we didn't ask for; a clean one means the system's stop button ended the recording
        switch result {
        case .success: onUnexpectedStop?(nil)
        case .failure(let error): onUnexpectedStop?(ScreenRecorderError.failed(error))
        }
    }

    private func streamStopped(_ error: Error) {
        guard !stopRequested else { return }
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
