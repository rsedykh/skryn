import Carbon.HIToolbox
import Foundation

/// Screen recording switches. The area picker's toolbar and Settings both edit them; the recorder,
/// keystroke overlay, and webcam bubble read them when a recording starts. Stored in UserDefaults.
struct RecordingOptions: Equatable {
    var microphone = false
    /// `AVCaptureDevice.uniqueID` of the chosen microphone; nil means the system default.
    var microphoneDeviceID: String?
    var systemAudio = true
    /// ScreenCaptureKit's built-in click highlight (`SCStreamConfiguration.showMouseClicks`)
    var highlightClicks = false
    var showCursor = true
    /// On-screen overlay of pressed key combinations; needs Accessibility permission
    var showKeystrokes = false
    /// Keyboard layout (`TISInputSource` ID) that names the keys in the overlay, so shortcuts read
    /// the same whatever layout is active; nil labels keys as typed.
    var keystrokeLayoutID: String?
    /// Round webcam window that floats over the recording
    var camera = false
    /// `AVCaptureDevice.uniqueID` of the chosen camera; nil means the system default.
    var cameraDeviceID: String?
    /// 3-2-1 countdown before recording starts
    var countdown = true

    /// Posted on the default center whenever `current` is written, so open UIs stay in sync.
    static let didChange = Notification.Name("RecordingOptionsDidChange")

    private enum Key {
        static let microphone = "recordMicrophone"
        static let microphoneDeviceID = "recordMicrophoneDeviceID"
        static let systemAudio = "recordSystemAudio"
        static let highlightClicks = "recordHighlightClicks"
        static let showCursor = "recordShowCursor"
        static let showKeystrokes = "recordShowKeystrokes"
        static let keystrokeLayoutID = "recordKeystrokeLayoutID"
        static let camera = "recordCamera"
        static let cameraDeviceID = "recordCameraDeviceID"
        static let countdown = "recordCountdown"
    }

    static var current: RecordingOptions {
        get {
            let defaults = UserDefaults.standard
            let fallback = RecordingOptions()
            func bool(_ key: String, _ value: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? value }
            return RecordingOptions(
                microphone: bool(Key.microphone, fallback.microphone),
                microphoneDeviceID: defaults.string(forKey: Key.microphoneDeviceID),
                systemAudio: bool(Key.systemAudio, fallback.systemAudio),
                highlightClicks: bool(Key.highlightClicks, fallback.highlightClicks),
                showCursor: bool(Key.showCursor, fallback.showCursor),
                showKeystrokes: bool(Key.showKeystrokes, fallback.showKeystrokes),
                keystrokeLayoutID: defaults.string(forKey: Key.keystrokeLayoutID),
                camera: bool(Key.camera, fallback.camera),
                cameraDeviceID: defaults.string(forKey: Key.cameraDeviceID),
                countdown: bool(Key.countdown, fallback.countdown)
            )
        }
        set {
            guard newValue != current else { return }
            let defaults = UserDefaults.standard
            defaults.set(newValue.microphone, forKey: Key.microphone)
            defaults.set(newValue.microphoneDeviceID, forKey: Key.microphoneDeviceID)
            defaults.set(newValue.systemAudio, forKey: Key.systemAudio)
            defaults.set(newValue.highlightClicks, forKey: Key.highlightClicks)
            defaults.set(newValue.showCursor, forKey: Key.showCursor)
            defaults.set(newValue.showKeystrokes, forKey: Key.showKeystrokes)
            defaults.set(newValue.keystrokeLayoutID, forKey: Key.keystrokeLayoutID)
            defaults.set(newValue.camera, forKey: Key.camera)
            defaults.set(newValue.cameraDeviceID, forKey: Key.cameraDeviceID)
            defaults.set(newValue.countdown, forKey: Key.countdown)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}

extension Defaults {
    static let recordHotkeyKeyCode = "recordHotkeyKeyCode"
    static let recordHotkeyModifiers = "recordHotkeyModifiers"

    static let defaultRecordHotkeyKeyCode = UInt32(kVK_ANSI_6)
    static let defaultRecordHotkeyModifiers = UInt32(cmdKey | shiftKey)

    static let areaHotkeyKeyCode = "areaHotkeyKeyCode"
    static let areaHotkeyModifiers = "areaHotkeyModifiers"

    static let defaultAreaHotkeyKeyCode = UInt32(kVK_ANSI_4)
    static let defaultAreaHotkeyModifiers = UInt32(cmdKey | shiftKey)

    /// The configured area screenshot hotkey, falling back to ⌘⇧4 (taking it over from macOS while Skryn runs)
    static var areaHotkey: (keyCode: UInt32, modifiers: UInt32) {
        let defaults = UserDefaults.standard
        return (
            defaults.object(forKey: areaHotkeyKeyCode) as? UInt32 ?? defaultAreaHotkeyKeyCode,
            defaults.object(forKey: areaHotkeyModifiers) as? UInt32 ?? defaultAreaHotkeyModifiers
        )
    }

    /// The configured screen recording hotkey, falling back to ⌘⇧6
    static var recordHotkey: (keyCode: UInt32, modifiers: UInt32) {
        let defaults = UserDefaults.standard
        return (
            defaults.object(forKey: recordHotkeyKeyCode) as? UInt32 ?? defaultRecordHotkeyKeyCode,
            defaults.object(forKey: recordHotkeyModifiers) as? UInt32 ?? defaultRecordHotkeyModifiers
        )
    }
}
