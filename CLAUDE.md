# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

```bash
xcodebuild -project Skryn/Skryn.xcodeproj -scheme Skryn -configuration Debug build
```

## Lint

```bash
swiftlint --config .swiftlint.yml
```

## Test

```bash
xcodebuild test -project Skryn/Skryn.xcodeproj -scheme Skryn -destination 'platform=macOS'
```

Verify changes by building. Run lint and tests before committing.

To run the built app (avoids Xcode re-signing permission issues with ScreenCaptureKit):
```bash
open ~/Library/Developer/Xcode/DerivedData/Skryn-*/Build/Products/Debug/Skryn.app
```

## Architecture

macOS menu bar screenshot app. SwiftUI is only the entry point (`SkrynApp.swift`); all real work is AppKit.

**Flow:** Menu bar click → `ScreenCapture.capture()` (ScreenCaptureKit, 2x resolution) → `AnnotationWindow` (90% of screen, borderless, rounded corners, shadow) → `AnnotationView` (drawing + input) → `AppDelegate.handleSave(cgImage:)` → local save or Uploadcare cloud upload. AnnotationView holds a `weak var appDelegate` reference set at window creation — do NOT use `NSApp.delegate as? AppDelegate` (see SwiftUI gotcha below).

**Coordinate system:** Annotations are stored in **screenshot point coordinates** (NSImage size), not view coordinates. Mouse input is converted via `viewToScreenshot()`. On-screen drawing uses `NSAffineTransform` to map screenshot space back to view space. `compositeAsCGImage()` uses a `CGBitmapContext` at full pixel resolution — it draws the CGImage first, then applies a point-to-pixel transform for annotation drawing. PNG is written directly via `CGImageDestination` (no TIFF/BitmapRep intermediates).

**Activation policy toggle:** The app is `LSUIElement=true` (no Dock icon). When the annotation window opens, it switches to `.regular` (appears in Cmd+Tab) and installs a main menu. On window close, it reverts to `.accessory`.

**Keyboard shortcuts** are handled via the installed `NSApp.mainMenu` (Cmd+W, Cmd+Z, Cmd+Shift+Z, Cmd+Q) for proper cross-layout support. ESC uses `keyDown` (layout-independent keyCode). Cmd+Enter and Option+Enter use `performKeyEquivalent` — the menu system intercepts modifier combos before they reach `keyDown`. Option+Enter triggers alternate save (opposite of configured default: local↔cloud).

**Tool selection:** Modifier keys at `mouseDown` time determine the tool — plain drag = arrow, Shift = line, Option = rectangle, Command = crop. Only one crop allowed at a time.

**Handle editing:** After drawing, annotations can be edited by dragging their handles (endpoints for arrows/lines, corners for rectangles/crop). `AnnotationHandle` enum and geometry methods live in `Annotation.swift`. `AnnotationView` does hit testing in `handleAt()` (10pt radius, topmost-first), shows white/red circle handles on hover with crosshair cursor, and supports live dragging with undo. Modifier keys at `mouseDown` bypass editing to draw a new annotation instead.

## Cloud Upload (Uploadcare)

**API reference:** https://uploadcare.com/api-refs/upload-api/ — we use the `/base/` direct upload endpoint. The official Swift SDK (https://github.com/uploadcare/uploadcare-swift) is not used — too heavy for a small app — but its source is a good reference for edge cases.

**Files:** `UploadcareService.swift` (HTTP multipart POST via URLSession, no dependencies), `UploadHistory.swift` (recent uploads + PNG cache).

**Upload flow:** `AppDelegate.handleSave()` → if public key set: cache PNG to `~/Library/Application Support/Skryn/uploads/`, start async upload via URLSession, animate menu bar icon (spinning arrows). On success: copy CDN URL to clipboard. On failure: icon turns red, error shown in menu, screenshot saved locally as fallback.

**Icon animation:** Layer transforms don't work on `NSStatusBarButton` — the menu bar compositor ignores them. Use image swapping with a `Timer` cycling through SF Symbols (`arrow.up` → `arrow.up.right` → ... 8 directional arrows at 120ms).

**Settings panel:** `SettingsPanel.swift` — NSPanel with radio buttons for local folder vs Uploadcare, plus a hotkey recorder (`HotkeyRecorderButton.swift`). Opened via right-click menu "Settings…" (⌘,). Uses `installEditOnlyMenu()` + `.regular` activation policy so Cmd+V works in the key field. `windowWillClose` only reverts to `.accessory` when both annotation window and settings panel are nil.

**ObjC bridging:** Swift structs in `NSMenuItem.representedObject` (bridged from ObjC `id`) may fail `as?` casts. `RecentUploadBox` (NSObject subclass in `UploadHistory.swift`) wraps `RecentUpload` struct for reliable casting.

**UserDefaults keys:** `"saveMode"` (`"local"` or `"cloud"`), `"uploadcarePublicKey"` (String, persisted even when mode is local), `"recentUploads"` (JSON-encoded `[RecentUpload]`), `"saveFolderPath"` (String, custom save folder), `"hotkeyKeyCode"` (UInt32, Carbon key code, default `kVK_ANSI_5`), `"hotkeyModifiers"` (UInt32, Carbon modifier bitmask, default `cmdKey | shiftKey`).

**Right-click menu structure:**
- Recent Uploads submenu (only if uploads exist) / error message (if any) / "Settings…" (⌘,, opens settings panel) / Quit

## App Icon

- Located in `Assets.xcassets/AppIcon.appiconset/` — 10 PNGs (16px–1024px)
- Current design: black "y" letter on white rounded rect (Helvetica font)
- Generated via Python/Pillow script — no source vector file
- Menu bar uses SF Symbol `"camera"` (set in AppDelegate.swift)

## Distribution

Unsigned app distributed via GitHub Releases. No paid Apple Developer account — notarization (no warnings) requires $99/yr Apple Developer Program.

**Release workflow** (only when explicitly asked — never create releases autonomously):

```bash
# 1. Build Release
xcodebuild -project Skryn/Skryn.xcodeproj -scheme Skryn -configuration Release build

# 2. Zip the .app
cd ~/Library/Developer/Xcode/DerivedData/Skryn-*/Build/Products/Release && ditto -c -k --keepParent Skryn.app /tmp/Skryn.zip

# 3. Create GitHub release (bump version as appropriate)
gh release create v1.x.x /tmp/Skryn.zip --title "Skryn v1.x.x" --generate-notes
```

**User install:** Download `Skryn.zip` from [Releases](https://github.com/rsedykh/skryn/releases) → unzip → drag to Applications → right-click → Open on first launch (bypasses Gatekeeper). Grant Screen Recording permission when prompted.

**Screen Recording permission after update:** Since the app is unsigned, macOS may revoke Screen Recording permission after updating. Users must remove Skryn from System Settings → Privacy & Security → Screen Recording, then re-add it (toggling off/on doesn't work).

## Key Gotchas

- **`NSApp.delegate` is SwiftUI's wrapper, not our `AppDelegate`.** With `@NSApplicationDelegateAdaptor`, `NSApp.delegate as? AppDelegate` returns nil. Always pass direct references (e.g., `weak var appDelegate`) instead of casting `NSApp.delegate`.
- **Cmd+ shortcuts need `performKeyEquivalent`, not `keyDown`.** When a main menu is installed, the menu system intercepts Cmd+ key combos via `performKeyEquivalent` before they reach `keyDown`. Use `performKeyEquivalent` for Cmd+ shortcuts in views.
- `project.pbxproj` is hand-crafted with simple hex IDs (AA000001, AB000001). Keep this convention when adding files. IDs `AB000008`/`AB000009` are taken by Skryn.entitlements and Info.plist. Latest source file IDs: `AB000014` (file ref), `AA000011` (build file). Latest test file IDs: `AB100005` (file ref), `AA100004` (build file).
- Borderless windows don't support `performClose(_:)` — Close routes through `AppDelegate.closeAnnotationWindow()` instead.
- `NSEvent.modifierFlags` (static) reads current keyboard state; `event.modifierFlags` (instance) reads state at event time. Always use the instance property for tool locking.
- When renaming variables, check ALL references in the same method — secondary uses are easy to miss.
- SwiftLint: `String.data(using: .utf8)!` triggers `non_optional_string_data_conversion` — use `Data("string".utf8)` instead.
- SwiftLint config limits: type_body_length 500/700, file_length 600/900 (bumped for AppDelegate with upload feature).
