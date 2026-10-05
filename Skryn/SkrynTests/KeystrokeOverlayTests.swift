import XCTest
import Carbon.HIToolbox
@testable import Skryn

@MainActor
final class KeystrokeOverlayTests: XCTestCase {
    private func label(_ keyCode: Int, _ chars: String?, _ mods: NSEvent.ModifierFlags = []) -> String? {
        KeystrokeOverlay.label(keyCode: UInt16(keyCode), characters: chars, modifiers: mods)
    }

    func testPlainTyping_hidden() {
        XCTAssertNil(label(kVK_ANSI_A, "a"))
        XCTAssertNil(label(kVK_ANSI_A, "a", .shift))
        XCTAssertNil(label(kVK_Space, " "))
        // ⌥ types characters on many layouts (⌥L = @ on German), so it's text, not a shortcut
        XCTAssertNil(label(kVK_ANSI_L, "l", .option))
        XCTAssertNil(label(kVK_ANSI_E, "e", [.option, .shift]))
        XCTAssertEqual(label(kVK_Space, " ", .option), "⌥␣")
    }

    func testShortcuts() {
        XCTAssertEqual(label(kVK_ANSI_C, "c", .command), "⌘C")
        XCTAssertEqual(label(kVK_ANSI_K, "k", [.command, .shift, .option, .control]), "⌃⌥⇧⌘K")
        XCTAssertEqual(label(kVK_ANSI_4, "4", [.command, .shift]), "⇧⌘4")
        XCTAssertEqual(label(kVK_Space, " ", .command), "⌘␣")
    }

    func testSpecialKeys() {
        XCTAssertEqual(label(kVK_Escape, "\u{1b}"), "⎋")
        XCTAssertEqual(label(kVK_LeftArrow, "\u{F702}", .option), "⌥←")
        XCTAssertEqual(label(kVK_Return, "\r"), "↩")
        XCTAssertEqual(label(kVK_F5, nil), "F5")
    }

    func testIgnoresNonModifierFlags() {
        XCTAssertNil(label(kVK_ANSI_A, "a", [.capsLock, .numericPad]))
    }
}

final class KeyboardLayoutTests: XCTestCase {
    func testCharacter_namesKeysWithTheChosenLayout() throws {
        let usLayout = try XCTUnwrap(KeyboardLayout(id: "com.apple.keylayout.US"))
        XCTAssertEqual(usLayout.character(for: UInt16(kVK_ANSI_C)), "c")
        // Same key, different layout: the overlay shows what that layout would type
        let russian = try XCTUnwrap(KeyboardLayout(id: "com.apple.keylayout.Russian"))
        XCTAssertEqual(russian.character(for: UInt16(kVK_ANSI_C)), "с")
    }

    func testInit_unknownLayout_nil() {
        XCTAssertNil(KeyboardLayout(id: "com.example.not-a-layout"))
    }
}
