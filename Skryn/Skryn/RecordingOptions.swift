import AVFoundation
import Foundation

/// Screen recording switches. The area picker's toolbar and Settings both edit them; the recorder,
/// keystroke overlay, and webcam bubble read them when a recording starts. Stored in UserDefaults.
struct RecordingOptions: StoredSettings {
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

    static let didChange = Notification.Name("RecordingOptionsDidChange")

    static var fields: [StoredField<Self>] {
        [
            .value("recordMicrophone", \.microphone),
            .optional("recordMicrophoneDeviceID", \.microphoneDeviceID),
            .value("recordSystemAudio", \.systemAudio),
            .value("recordHighlightClicks", \.highlightClicks),
            .value("recordShowCursor", \.showCursor),
            .value("recordShowKeystrokes", \.showKeystrokes),
            .optional("recordKeystrokeLayoutID", \.keystrokeLayoutID),
            .value("recordCamera", \.camera),
            .optional("recordCameraDeviceID", \.cameraDeviceID),
            .value("recordCountdown", \.countdown),
        ]
    }
}

/// A recording option picked from a list (the recording bar's chevron menus and Settings' popups):
/// a capture device, or the layout that names keys in the keystroke overlay. Nil picks the default.
enum RecordingChoice {
    case microphone, camera, keyboardLayout

    var name: String {
        switch self {
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .keyboardLayout: "Key labels"
        }
    }

    /// Title of the nil choice
    var defaultTitle: String { self == .keyboardLayout ? "As Typed" : "System Default" }

    var selection: WritableKeyPath<RecordingOptions, String?> {
        switch self {
        case .microphone: \.microphoneDeviceID
        case .camera: \.cameraDeviceID
        case .keyboardLayout: \.keystrokeLayoutID
        }
    }

    /// The switch this choice belongs to
    var option: WritableKeyPath<RecordingOptions, Bool> {
        switch self {
        case .microphone: \.microphone
        case .camera: \.camera
        case .keyboardLayout: \.showKeystrokes
        }
    }

    /// What's available now, as (ID stored in `selection`, title)
    var choices: [(id: String, title: String)] {
        switch self {
        case .microphone:
            AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
                .devices.map { ($0.uniqueID, $0.localizedName) }
        case .camera:
            AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified
            ).devices.map { ($0.uniqueID, $0.localizedName) }
        case .keyboardLayout:
            KeyboardLayout.enabled().map { ($0.id, $0.name) }
        }
    }
}
