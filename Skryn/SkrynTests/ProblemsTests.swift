import XCTest
@testable import Skryn

@MainActor
final class ProblemsTests: XCTestCase {
    func testMenuText_listsEverySlotInOrder() {
        let problems = Problems()
        XCTAssertNil(problems.menuText)
        problems[.hotkeys] = "Shortcut taken"
        problems[.capture] = "Capture failed"
        XCTAssertEqual(problems.menuText, "Capture failed\nShortcut taken")
    }

    func testSettingASlot_leavesTheOthers() {
        let problems = Problems()
        problems[.hotkeys] = "Shortcut taken"
        problems[.upload] = "Upload failed"
        problems[.upload] = nil
        XCTAssertEqual(problems.menuText, "Shortcut taken")
    }

    func testClearExcept_keepsTheNamedSlots() {
        let problems = Problems()
        problems[.recording] = "No Accessibility"
        problems[.save] = "Save failed"
        problems[.hotkeys] = "Shortcut taken"
        problems.clear(except: [.recording, .hotkeys])
        XCTAssertEqual(problems.menuText, "No Accessibility\nShortcut taken")
    }

    func testMarksIconRed_onlyForCaptureAndUpload() {
        let problems = Problems()
        problems[.save] = "Save failed"
        problems[.hotkeys] = "Shortcut taken"
        problems[.recording] = "Recording stopped"
        XCTAssertFalse(problems.marksIconRed)
        problems[.upload] = "Upload failed"
        XCTAssertTrue(problems.marksIconRed)
        problems[.upload] = nil
        problems[.capture] = "Capture failed"
        XCTAssertTrue(problems.marksIconRed)
    }

    func testOnChange_firesOnlyOnRealChanges() {
        let problems = Problems()
        var changes = 0
        problems.onChange = { changes += 1 }
        problems[.save] = "Save failed"
        problems[.save] = "Save failed"
        problems.clear(except: [.save])
        problems.clear()
        XCTAssertEqual(changes, 2)
    }
}
