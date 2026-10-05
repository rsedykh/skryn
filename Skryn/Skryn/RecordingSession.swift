import AppKit

/// One screen recording, from the area picker to the finished file: picks the area and the switches,
/// shows the overlays (the frame, never captured; the keystroke HUD and camera bubble, captured by window
/// ID), counts down, records, and on `finish()` stops and takes everything off screen.
@MainActor
final class RecordingSession {
    /// When recording started, for the menu bar timer
    let startedAt = Date()
    /// Things the user should know (missing permissions), to show when recording starts
    let notices: [String]

    /// Stops the recorder, takes the overlays down, and returns the file. A closure because `ScreenRecorder`
    /// is macOS 15+ and this class isn't, so the app can keep a session in a plain stored property.
    private let stopRecorder: () async throws -> URL

    private init(notices: [String], stopRecorder: @escaping () async throws -> URL) {
        self.notices = notices
        self.stopRecorder = stopRecorder
    }

    /// Lets the user pick an area on `screen` and the recording switches, then starts recording it.
    /// Returns nil when the user cancels (Esc in the picker or the countdown). `onEnded` is called when the
    /// recording ends on its own: with the error, or nil when the system's menu bar button stopped it.
    @available(macOS 15.0, *)
    static func begin(on screen: NSScreen, onEnded: @escaping (Error?) -> Void) async throws -> RecordingSession? {
        guard let area = await SelectionOverlay.pickArea(on: screen, fullScreenVerb: "record",
                                                         accessory: RecordingOptionsBar()) else { return nil }
        let options = RecordingOptions.current

        // On screen before the recorder lists windows, so the ones it should capture are found
        let frame = RecordingFrame(area: area)
        frame.show()
        var notices: [String] = []
        let keystrokes = options.showKeystrokes ? KeystrokeOverlay.start(area: area, layoutID: options.keystrokeLayoutID) : nil
        if options.showKeystrokes && keystrokes == nil {
            notices.append("Keystrokes need Accessibility permission — allow Skryn, then record again")
        }
        let camera = options.camera ? await WebcamBubble.start(area: area, deviceID: options.cameraDeviceID) : nil
        if options.camera && camera == nil {
            notices.append("Camera unavailable — check Camera permission for Skryn")
        }
        let tearDown = {
            frame.close()
            keystrokes?.stop()
            camera?.stop()
        }

        if options.countdown, await !frame.countdown() {
            tearDown()
            return nil
        }
        let recorder = ScreenRecorder(
            area: area, options: options, frameRate: OutputSettings.current.frameRate,
            capturedWindowIDs: [keystrokes?.windowID, camera?.windowID].compactMap { $0 }
        )
        // The recorder keeps what it captured so far; `finish()` collects it
        recorder.onUnexpectedStop = onEnded
        do {
            try await recorder.start()
        } catch {
            tearDown()
            throw error
        }
        if recorder.microphoneUnavailable {
            notices.append("Microphone access denied — recording without the mic")
        }
        return RecordingSession(notices: notices) {
            defer { tearDown() }  // after the stream stops, so the last frames still show the overlays
            return try await recorder.stop()
        }
    }

    /// Stops recording, takes the overlays off screen, and returns the finished video (a temp file the
    /// caller owns).
    func finish() async throws -> URL {
        try await stopRecorder()
    }
}
