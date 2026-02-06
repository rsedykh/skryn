import XCTest
import Carbon.HIToolbox
@testable import Skryn

final class HotkeyRecorderButtonTests: XCTestCase {

    // MARK: - carbonModifiers(from:)

    func testCarbonModifiers_emptyFlags_returnsZero() {
        XCTAssertEqual(carbonModifiers(from: []), 0)
    }

    func testCarbonModifiers_commandOnly() {
        XCTAssertEqual(carbonModifiers(from: .command), UInt32(cmdKey))
    }

    func testCarbonModifiers_shiftOnly() {
        XCTAssertEqual(carbonModifiers(from: .shift), UInt32(shiftKey))
    }

    func testCarbonModifiers_optionOnly() {
        XCTAssertEqual(carbonModifiers(from: .option), UInt32(optionKey))
    }

    func testCarbonModifiers_controlOnly() {
        XCTAssertEqual(carbonModifiers(from: .control), UInt32(controlKey))
    }

    func testCarbonModifiers_commandShiftCombined() {
        let flags: NSEvent.ModifierFlags = [.command, .shift]
        XCTAssertEqual(carbonModifiers(from: flags), UInt32(cmdKey) | UInt32(shiftKey))
    }

    // MARK: - cocoaModifiers(from:)

    func testCocoaModifiers_zero_returnsEmpty() {
        XCTAssertEqual(cocoaModifiers(from: 0), [])
    }

    func testCocoaModifiers_cmdKey_returnsCommand() {
        XCTAssertEqual(cocoaModifiers(from: UInt32(cmdKey)), .command)
    }

    func testCocoaModifiers_cmdShiftCombined() {
        let carbon = UInt32(cmdKey) | UInt32(shiftKey)
        let expected: NSEvent.ModifierFlags = [.command, .shift]
        XCTAssertEqual(cocoaModifiers(from: carbon), expected)
    }

    // MARK: - Round-trip

    func testRoundTrip_individualModifiers() {
        let singles: [NSEvent.ModifierFlags] = [.command, .shift, .option, .control]
        for flag in singles {
            let carbon = carbonModifiers(from: flag)
            let cocoa = cocoaModifiers(from: carbon)
            XCTAssertEqual(cocoa, flag, "Round-trip failed for \(flag)")
        }
    }

    func testRoundTrip_combinedFlags() {
        let combined: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let carbon = carbonModifiers(from: combined)
        let cocoa = cocoaModifiers(from: carbon)
        XCTAssertEqual(cocoa, combined)
    }

    // MARK: - modifierSymbols(_:)

    func testModifierSymbols_empty_returnsEmptyString() {
        XCTAssertEqual(modifierSymbols([]), "")
    }

    func testModifierSymbols_commandOnly() {
        XCTAssertEqual(modifierSymbols(.command), "⌘")
    }

    func testModifierSymbols_shiftCommand_correctOrder() {
        let flags: NSEvent.ModifierFlags = [.shift, .command]
        XCTAssertEqual(modifierSymbols(flags), "⇧⌘")
    }

    func testModifierSymbols_allFour_correctOrder() {
        let flags: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        XCTAssertEqual(modifierSymbols(flags), "⌃⌥⇧⌘")
    }

    // MARK: - keyCodeName(_:)

    func testKeyCodeName_letterA() {
        XCTAssertEqual(keyCodeName(UInt32(kVK_ANSI_A)), "A")
    }

    func testKeyCodeName_digit5() {
        XCTAssertEqual(keyCodeName(UInt32(kVK_ANSI_5)), "5")
    }

    func testKeyCodeName_F1() {
        XCTAssertEqual(keyCodeName(UInt32(kVK_F1)), "F1")
    }

    func testKeyCodeName_space() {
        XCTAssertEqual(keyCodeName(UInt32(kVK_Space)), "Space")
    }

    func testKeyCodeName_return() {
        XCTAssertEqual(keyCodeName(UInt32(kVK_Return)), "Return")
    }

    func testKeyCodeName_unknown_returnsHexString() {
        XCTAssertEqual(keyCodeName(0xFF), "Key 0xFF")
    }

    // MARK: - hotkeyDisplayString(keyCode:carbonModifiers:)

    func testHotkeyDisplayString_cmdShift5() {
        let mods = UInt32(cmdKey) | UInt32(shiftKey)
        XCTAssertEqual(hotkeyDisplayString(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: mods), "⇧⌘5")
    }

    func testHotkeyDisplayString_ctrlA() {
        let mods = UInt32(controlKey)
        XCTAssertEqual(hotkeyDisplayString(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: mods), "⌃A")
    }
}
