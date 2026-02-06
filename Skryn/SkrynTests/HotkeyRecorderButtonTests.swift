import XCTest
import Carbon.HIToolbox
@testable import Skryn

final class HotkeyRecorderButtonTests: XCTestCase {

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

    func testModifierSymbols_allFour_correctOrder() {
        let flags: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        XCTAssertEqual(modifierSymbols(flags), "⌃⌥⇧⌘")
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
