import AppKit
import Carbon.HIToolbox

// MARK: - Key Display Utilities

func carbonModifiers(from cocoa: NSEvent.ModifierFlags) -> UInt32 {
    var carbon: UInt32 = 0
    if cocoa.contains(.control) { carbon |= UInt32(controlKey) }
    if cocoa.contains(.option) { carbon |= UInt32(optionKey) }
    if cocoa.contains(.shift) { carbon |= UInt32(shiftKey) }
    if cocoa.contains(.command) { carbon |= UInt32(cmdKey) }
    return carbon
}

func cocoaModifiers(from carbon: UInt32) -> NSEvent.ModifierFlags {
    var flags = NSEvent.ModifierFlags()
    if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
    if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
    if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
    if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
    return flags
}

func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
    var result = ""
    if flags.contains(.control) { result += "⌃" }
    if flags.contains(.option) { result += "⌥" }
    if flags.contains(.shift) { result += "⇧" }
    if flags.contains(.command) { result += "⌘" }
    return result
}

// swiftlint:disable:next cyclomatic_complexity
func keyCodeName(_ keyCode: UInt32) -> String {
    switch Int(keyCode) {
    case kVK_ANSI_A: return "A"
    case kVK_ANSI_S: return "S"
    case kVK_ANSI_D: return "D"
    case kVK_ANSI_F: return "F"
    case kVK_ANSI_H: return "H"
    case kVK_ANSI_G: return "G"
    case kVK_ANSI_Z: return "Z"
    case kVK_ANSI_X: return "X"
    case kVK_ANSI_C: return "C"
    case kVK_ANSI_V: return "V"
    case kVK_ANSI_B: return "B"
    case kVK_ANSI_Q: return "Q"
    case kVK_ANSI_W: return "W"
    case kVK_ANSI_E: return "E"
    case kVK_ANSI_R: return "R"
    case kVK_ANSI_Y: return "Y"
    case kVK_ANSI_T: return "T"
    case kVK_ANSI_1: return "1"
    case kVK_ANSI_2: return "2"
    case kVK_ANSI_3: return "3"
    case kVK_ANSI_4: return "4"
    case kVK_ANSI_5: return "5"
    case kVK_ANSI_6: return "6"
    case kVK_ANSI_7: return "7"
    case kVK_ANSI_8: return "8"
    case kVK_ANSI_9: return "9"
    case kVK_ANSI_0: return "0"
    case kVK_ANSI_O: return "O"
    case kVK_ANSI_U: return "U"
    case kVK_ANSI_I: return "I"
    case kVK_ANSI_P: return "P"
    case kVK_ANSI_L: return "L"
    case kVK_ANSI_J: return "J"
    case kVK_ANSI_K: return "K"
    case kVK_ANSI_N: return "N"
    case kVK_ANSI_M: return "M"
    case kVK_F1: return "F1"
    case kVK_F2: return "F2"
    case kVK_F3: return "F3"
    case kVK_F4: return "F4"
    case kVK_F5: return "F5"
    case kVK_F6: return "F6"
    case kVK_F7: return "F7"
    case kVK_F8: return "F8"
    case kVK_F9: return "F9"
    case kVK_F10: return "F10"
    case kVK_F11: return "F11"
    case kVK_F12: return "F12"
    case kVK_Space: return "Space"
    case kVK_Delete: return "Delete"
    case kVK_ForwardDelete: return "Fwd Delete"
    case kVK_Return: return "Return"
    case kVK_Tab: return "Tab"
    default: return String(format: "Key 0x%02X", keyCode)
    }
}

func hotkeyDisplayString(keyCode: UInt32, carbonModifiers mods: UInt32) -> String {
    modifierSymbols(cocoaModifiers(from: mods)) + keyCodeName(keyCode)
}

// MARK: - HotkeyRecorderButton

final class HotkeyRecorderButton: NSButton {
    private(set) var recordedKeyCode: UInt32 = UInt32(kVK_ANSI_5)
    private(set) var recordedCarbonModifiers: UInt32 = UInt32(cmdKey | shiftKey)
    private(set) var isRecording = false

    var onHotkeyRecorded: ((_ keyCode: UInt32, _ carbonModifiers: UInt32) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        updateTitle()
    }

    func setHotkey(keyCode: UInt32, carbonModifiers: UInt32) {
        recordedKeyCode = keyCode
        recordedCarbonModifiers = carbonModifiers
        updateTitle()
    }

    @objc private func clicked() {
        isRecording = true
        title = "Type shortcut..."
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        handleRecordingKey(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        handleRecordingKey(event)
    }

    private func handleRecordingKey(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            cancelRecording()
            return
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasModifier = mods.contains(.command) || mods.contains(.control)
            || mods.contains(.option)

        guard hasModifier else {
            NSSound.beep()
            return
        }

        recordedKeyCode = UInt32(event.keyCode)
        recordedCarbonModifiers = carbonModifiers(from: mods)
        isRecording = false
        updateTitle()
        onHotkeyRecorded?(recordedKeyCode, recordedCarbonModifiers)
    }

    func cancelRecording() {
        isRecording = false
        updateTitle()
    }

    private func updateTitle() {
        title = hotkeyDisplayString(keyCode: recordedKeyCode, carbonModifiers: recordedCarbonModifiers)
    }
}
