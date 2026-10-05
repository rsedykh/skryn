# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

```bash
xcodebuild -project Skryn/Skryn.xcodeproj -scheme Skryn -configuration Debug build
```

**Signing:** `Skryn/Signing.xcconfig` (the project-level base config, so both targets use it) signs ad hoc, so a fresh clone builds without a certificate. It includes the gitignored `Skryn/Signing.local.xcconfig` if present, which sets `CODE_SIGN_IDENTITY` to a local certificate (a self-signed one works; Xcode signs with it even when it's untrusted). Signed with a certificate, the designated requirement is `identifier "com.skryn.app" and certificate leaf = H"…"` and stays the same across builds; ad hoc it's a `cdhash` that changes every build, and macOS keys Screen Recording permission to it. Check with `codesign -d -r- <app>`. Don't set signing in the target build settings: they override the xcconfig.

## Lint

```bash
swiftlint --config .swiftlint.yml
```

## Test

```bash
xcodebuild test -project Skryn/Skryn.xcodeproj -scheme Skryn -destination 'platform=macOS'
```

Verify changes by building. Run lint and tests before committing. Write tests for new logic — model/pure functions in `AnnotationViewTests.swift`. Use `setAnnotations(forTesting:)` to inject state for view-level tests like `handleAt()`.

To run the built app (avoids Xcode re-signing permission issues with ScreenCaptureKit):
```bash
open ~/Library/Developer/Xcode/DerivedData/Skryn-*/Build/Products/Debug/Skryn.app
```

## Architecture

macOS menu bar screenshot app. SwiftUI is only the entry point (`SkrynApp.swift`); all real work is AppKit.

**Flow:** Menu bar click → `ScreenCapture.capture(displayID:scale:)` (ScreenCaptureKit, captures the display under the cursor at its native backing scale) → `AnnotationWindow` (90% of screen, borderless, rounded corners, shadow) → `AnnotationView` (drawing + input) → `AppDelegate.handleAction(_:cgImage:)` → local save, clipboard copy, or Uploadcare cloud upload. AnnotationView holds a `weak var appDelegate` reference set at window creation — do NOT use `NSApp.delegate as? AppDelegate` (see SwiftUI gotcha below).

**Coordinate system:** Annotations are stored in **screenshot point coordinates** (NSImage size), not view coordinates. Mouse input is converted via `viewToScreenshot()`. On-screen drawing uses `NSAffineTransform` to map screenshot space back to view space. `compositeAsCGImage()` uses a `CGBitmapContext` at full pixel resolution — it draws the CGImage first, then applies a point-to-pixel transform for annotation drawing. PNG is written directly via `CGImageDestination` (no TIFF/BitmapRep intermediates). Drawing uses two passes: blur annotations first (layered between the screenshot and other annotations), then all non-blur annotations on top.

**Feedback:** two channels. `StatusHUD.swift` confirms what the user just did (copied, saved, uploading, link copied from Recent Uploads, actions that can't run right now, immediate failures): a dark rounded square with an icon and label, centered on the screen under the pointer, gone after ~1–2s; no permission, not blocked by Focus. `Notifier.swift` posts native notifications (`UNUserNotificationCenter`) for results that arrive later or need a button: link ready (Open), upload failed (Show in Finder), recording stopped on its own, shortcut taken / Screen Recording permission (Open Settings). macOS asks for notification permission on the first one; each button title is a `UNNotificationCategory` and clicking the banner runs the action too; `willPresent` returns `.banner` so they show while Skryn is active. Closing the last window calls `NSApp.hide` to hand focus back, which would hide the HUD too, so it deactivates instead while the HUD is up.

**Activation policy toggle:** The app is `LSUIElement=true` (no Dock icon). When the annotation window opens, it switches to `.regular` (appears in Cmd+Tab) and installs a main menu. On window close, it reverts to `.accessory`. On first launch, the About panel is shown automatically (with a 0.5s delay so the activation policy change propagates to the window server).

**Keyboard shortcuts** are handled via the installed `NSApp.mainMenu` (Cmd+W, Cmd+Z, Cmd+Shift+Z, Cmd+Q) for proper cross-layout support. ESC uses `keyDown` (layout-independent keyCode). Modifier+Enter uses `performKeyEquivalent` — the menu system intercepts modifier combos before they reach `keyDown`. Each of the three save actions (local, clipboard, cloud) has a configurable modifier key (Cmd/Opt/Ctrl) stored in UserDefaults. `SaveAction.action(for:)` maps the pressed modifier to the correct action.

**Tool selection:** Modifier keys at `mouseDown` time determine the tool — plain drag = arrow, Shift = line, Command = rectangle, Shift+Command = ellipse, Option = crop, Control = blur. T key opens a text editor at the cursor. Only one crop allowed at a time.

**Color:** Annotations carry an `AnnotationColor` associated value, an 8-color palette (red, orange, yellow, green, blue, purple, black, white); crop and blur are colorless. C moves the hovered annotation, or the drawing color (`currentColor`) when nothing is hovered, to the next palette color; the toolbar's swatches set the drawing color directly. Badge numbers use `contrastingTextColor` (black on yellow/white). The text editor inherits `currentColor`. The website demo still has only red/blue.

**Numbered badges:** Digit keys 1–0 (no modifiers) place a `.badge` (filled circle + white number) at the cursor. A digit pressed within 0.5s (`badgeCombineInterval`) of the previous one combines into a multi-digit number (1, 2 → 12; capped at two digits via the `number < 10` guard). Badges have no handles; they move via body drag.

**Text annotations:** T places an `IsolatedUndoTextView` (bold text in `currentColor`, transparent background) at the cursor and starts editing immediately; T over an existing text annotation re-edits it instead (`startTextAtCursor`). While the new box is still empty, a plain click elsewhere moves it there (keeps the old "T, then click" habit working). Auto-repeat of the T key is swallowed by the text view (`swallowsRepeatOfKeyCode`). Enter finalizes, Shift+Enter inserts newline, ESC finalizes; empty text is discarded. Cmd+=/Cmd+- adjusts font size. Click on finalized text to re-edit. Text width is resizable via left/right edge handles. `IsolatedUndoTextView` is a private NSTextView subclass with its own undo manager — this prevents text-editing undo operations from leaking into AnnotationView's undo stack (which would crash on Cmd+Z after the text view is removed). `finalizeTextEditing()` converts the NSTextView back to a `.text` annotation. The Edit menu (Cut/Copy/Paste/Select All) in `AppDelegate.installMainMenu()` enables clipboard support in the text view via responder chain.

**Interaction state:** AnnotationView uses a single `InteractionState` enum (`.idle`, `.editingHandle`, `.movingAnnotation`, `.editingText`) instead of parallel optional variables. This makes invalid state combinations impossible. Persistent state (`textFontSize`, `hoveredAnnotationIndex`, `currentAnnotation`, `dragOrigin`/`dragModifiers`) remains as separate properties since they're orthogonal to the interaction state.

**Handle editing:** After drawing, annotations can be edited by dragging their handles (endpoints for arrows/lines, corners for rectangles/crop, left/right edges for text). `AnnotationHandle` enum and geometry methods live in `Annotation.swift`. `AnnotationView` does hit testing in `handleAt()` (10pt radius, topmost-first), shows white/red circle handles on hover with crosshair cursor (resize-left-right for text edges), and supports live dragging with undo. Modifier keys at `mouseDown` bypass editing to draw a new annotation instead. Delete key removes the hovered annotation.

**Drag-to-move:** Any annotation can be repositioned by dragging its body. `bodyContains(_:hitRadius:)` does hit testing: point-to-segment distance for lines/arrows; stroke-only (within `hitRadius` of the outline) for rectangles, ellipses, and crop so their interior stays free for drawing; full-rect containment for blur and text; radius for badges. `annotationBodyAt(_:)` finds the topmost hit. Click-without-drag on text opens re-editing; on other types it's a no-op. Move uses `offsetBy(dx:dy:)` with undo support.

## Output formats

`OutputSettings.swift` holds the choices (Settings → Output): `ImageFormat` (PNG, JPEG, AVIF, HEIC, WebP, PDF), `VideoFormat` (MP4 H.264 / HEVC, MOV, animated GIF / WebP), lossless + quality, Retina vs 1x, frame rate (30/60, read by `ScreenRecorder`), strip metadata, and presets: Compatible (PNG + MP4 H.264, the default) and Compact (lossless WebP + MP4 HEVC). Stored per key (`"output…"`), posts `OutputSettings.didChange`.
- `ImageEncoder.encode(_:pointSize:settings:)` encodes Save/Upload screenshots: one redraw into 8-bit sRGB at the output size (that also drops capture metadata and, for opaque images, the alpha channel), then ImageIO, libwebp, or a PDF context. macOS can't write AVIF/HEIC bit-exact: their "lossless" is near-lossless (AVIF fails at quality 1.0, so it's capped at 0.99); WebP lossless is exact. The clipboard always gets PNG + TIFF (every app pastes those), whatever the format.
- `VideoExporter.export(_:settings:)` converts the recorder's MP4 (H.264): returns the source untouched for MP4 H.264 at Retina, otherwise re-encodes/remuxes (`shouldOptimizeForNetworkUse`, moov first) or builds GIF (12.5 fps, ≤800px wide) / animated WebP (15 fps, libwebp `WebPAnimEncoder`) frame by frame from an `AVAssetReader`. `AppDelegate.handleRecordingAction` converts from a clone of the panel's temp file (the panel deletes its file on close) and, if conversion fails, saves the original MP4 instead.

**Dependency:** libwebp via Swift Package Manager (`SDWebImage/libwebp-Xcode`, module `libwebp`; `AG000001`/`AG000002` in `project.pbxproj`) — macOS can read WebP but not write it. It's the app's only dependency. Plain `swiftc -typecheck` can't see the package module: typecheck without `ImageEncoder.swift` / `VideoExporter.swift`, or build with `xcodebuild`.

## Design system

`HUDKit.swift` is the shared look of every floating control: `HUDStyle` tokens (surface, hairline, radii, sizes, `paintSurface`), `HUDMotion` (`show`/`hide`/`fade`: entrances ease out in 0.22s, exits ease in over 0.16s; Reduce Motion gets fades only — every window and overlay enters and leaves through it), and components `HUDBar`, `HUDButton` (selected tile = the one chosen tool of a group), `HUDDivider`, `HUDHintButton` + `HUDHint` (instant hover hints; system tooltips wait ~1s and are unreliable in non-key panels). Animated closes (`AnnotationWindow`, `RecordingPanel`, `AnimatedPanel` for Settings/About) play the exit and then call `super.close()`, so `windowWillClose` fires after it; `isClosing` is readable, and `AppDelegate` retries a capture, drop, or reopen that arrives mid-close. The recording switch bar uses its own `SwitchButton` (white icon + dot when on, dimmed and slashed when off): independent switches, not a selection.

## Cloud Upload (providers)

**Abstraction:** `UploadProvider.swift` holds `protocol UploadProvider` (`@MainActor`, class-bound: `id`, `title`, `setupProblem`, `makeSettingsView(onChange:)`, `async upload(fileURL:filename:contentType:) -> link`) and the registry `UploadProviders` (`all`, in Settings menu order; `current`, stored by `id` under `"uploadDestination"`, unknown IDs fall back to the first). The rest of the app (AppDelegate, AnnotationToolbar, RecordingPanel, AboutPanel, SettingsPanel) knows only `UploadProviders.current` — no provider names outside the provider files and the registry list. Provider `id`s are stored in UserDefaults: never rename them.

**Each provider is self-contained:** one file with the provider class and its private Settings view (a `SettingsForm` subclass, so its labels line up with the panel's), plus an optional HTTP layer. Settings keys of a provider live in its own file, not in `Defaults`. The settings view calls `onChange` after anything that affects `setupProblem` or its own size; the panel then refits the window and refreshes the app.
- `UploadcareProvider.swift` — public key field (saved on every edit to `"uploadcarePublicKey"`) + "Get a key" link. HTTP: `UploadcareService.swift`.
- `DropboxProvider.swift` — the guided connect flow (setup caption, App Console link, App key, Connect…, Code + Finish, Connected as… / Disconnect). Account and HTTP: `DropboxService.swift` (`DropboxAuth`, `DropboxService`, `DropboxError`).

**To add a provider:** one new file with a `final class …: UploadProvider` and its settings view, plus one entry in `UploadProviders.all` (and the file in `project.pbxproj`). No edits to Settings, AppDelegate, toolbar or panels.

**Uploadcare:** https://uploadcare.com/api-refs/upload-api/ — we use the `/base/` direct upload endpoint. The official Swift SDK (https://github.com/uploadcare/uploadcare-swift) is not used — too heavy for a small app — but its source is a good reference for edge cases.

**Dropbox:** each user creates their own app in the App Console (Scoped access, App folder — uploads land in `Apps/<app name>/`) with permissions `files.content.write`, `sharing.write`, `sharing.read` (only to look up an existing link) and `account_info.read`, then pastes its App key in Settings. Sign-in is OAuth 2 with PKCE and no redirect URI: Connect opens the browser, Dropbox shows a code, the user pastes it back. The refresh token is in the Keychain (service `com.skryn.app.dropbox`); the access token is cached in memory and refreshed once on a 401. The App key is locked while connected (a new key needs a new authorization). Links are shared links rewritten to the permanent public file URL on `dl.dropboxusercontent.com` (same path and `rlkey`, no `dl`/`raw`): it serves the file itself (no redirect, no Dropbox page), unlike `www.dropbox.com…?raw=1`, which redirects to a temporary URL.

**Files:** `UploadHistory.swift` (recent uploads + file cache).

**Upload flow:** `AppDelegate.handleAction(.cloud, cgImage:)` → if `UploadProviders.current.setupProblem` is nil: cache PNG to `~/Library/Application Support/Skryn/uploads/`, capture the provider (a mid-upload Settings change doesn't switch it), start the async upload, animate menu bar icon (spinning arrows). On success: copy the link to clipboard. On failure: icon turns red, error shown in menu, screenshot saved locally as fallback. If the provider isn't set up, shows the setup problem and returns `false` (window stays open).

**Icon animation:** Layer transforms don't work on `NSStatusBarButton` — the menu bar compositor ignores them. Use image swapping with a `Timer` cycling through SF Symbols (`arrow.up` → `arrow.up.right` → ... 8 directional arrows at 120ms).

**Settings panel:** `SettingsPanel.swift` — NSPanel with three save action rows (local folder, clipboard, cloud upload), each with an `NSPopUpButton` to choose the modifier key (Cmd/Opt/Ctrl). Auto-swap prevents duplicate modifiers. The Upload section is generic: a "Service:" popup from `UploadProviders.all` and a full-width row hosting `UploadProviders.current.makeSettingsView(onChange:)`, swapped on change (the window resizes, keeping its top edge). Also has a hotkey recorder (`HotkeyRecorderButton.swift`) and launch-at-login checkbox. Opened via right-click menu "Settings…" (⌘,). Uses the shared `installMainMenu()` + `.regular` activation policy so Cmd+V works in the key field. `windowWillClose` only reverts to `.accessory` when the annotation window, settings panel, and about panel are all nil. Launch-at-login errors and the "requires approval" state are surfaced via `NSAlert`.

**UserDefaults keys:** `"modifierLocal"` / `"modifierClipboard"` / `"modifierCloud"` (String: `"cmd"`, `"opt"`, or `"ctrl"`, defaults opt/cmd/ctrl), `"uploadDestination"` (String, provider `id`), `"uploadcarePublicKey"` (String), `"dropboxAppKey"` / `"dropboxAccountName"` (String), `"recentUploads"` (JSON-encoded `[RecentUpload]`), `"saveFolderPath"` (String, custom save folder), `"hotkeyKeyCode"` (UInt32, Carbon key code, default `kVK_ANSI_5`), `"hotkeyModifiers"` (UInt32, Carbon modifier bitmask, default `cmdKey | shiftKey`), `"hasLaunchedBefore"` (Bool, triggers first-launch About panel when false/missing).
**Drag-and-drop:** Dropping an image file onto the menu bar icon opens it in the annotation window (same as a screenshot). Non-image files are rejected with a "!" icon for 2 seconds. Only one image is accepted per drop (first file wins). `StatusItemDropView` (NSView subclass at bottom of AppDelegate.swift) sits on top of `statusItem.button`, returns nil from `hitTest` so clicks pass through, but receives drag events via frame containment.

**Right-click menu:** built by `StatusMenu.make(_:actions:)` (`StatusMenu.swift`); `AppDelegate.showQuitMenu` only supplies `Content` and `Actions` closures. Top: a custom-view row of action tiles (Screenshot / Area / Record with their shortcuts) that cancel menu tracking and run their action asynchronously, so the menu isn't captured. Then the notice (`lastError`; a missing Screen Recording permission adds "Open Screen Recording Settings…"), then Recent Uploads inline as native items with async thumbnails (click copies the link, ⌥ alternate saves to Desktop, failed ones retry; more than 6 go under "More"), then Settings… (⌘,) / About Skryn / Quit Skryn. While recording, right-clicking the stop icon shows Stop / Discard instead.

**Menu bar icons:** `MenuBarSettings` (`MenuBar.swift`; Settings → Menu Bar, built by `MenuBarSettingsSection`): independent switches for a Screenshot / Area / Record icon (at least one stays on; the first enabled is the main icon, which also shows the upload spinner and the red error state), "Clicking an icon" (does its action, or opens the menu — right-click always opens it), and which action buttons the menu starts with. Keys `"menuBarIcons"`, `"menuBarClickOpensMenu"`, `"menuBarTiles"` (an old `"menuBarLayout"` is migrated on read and removed on the next save). `AppDelegate.applyMenuBarLayout()` keeps one `NSStatusItem` per enabled icon in `statusItems` (`autosaveName` keeps the user's ⌘-drag order; a change while recording waits until it ends). `recordingStatusItem` (the record icon, else the main one) becomes the red stop button with the timer. The menu drops from the icon that was clicked (`menuSourceButton`); every icon accepts dropped images.

## Distribution

Self-signed app (see Build → Signing) distributed via GitHub Releases. No paid Apple Developer account — notarization (no Gatekeeper warning) requires $99/yr Apple Developer Program.

**Release workflow** (only when explicitly asked — never create releases autonomously):

```bash
# 0. Bump MARKETING_VERSION in project.pbxproj (4 occurrences), commit, push

# 1. Build Release, and check it's signed with a certificate: the output must show Authority=,
#    not Signature=adhoc (see Signing above). Always the same certificate: a different one
#    changes the app's identity, and users lose Screen Recording permission on that update.
xcodebuild -project Skryn/Skryn.xcodeproj -scheme Skryn -configuration Release build
codesign -dvv ~/Library/Developer/Xcode/DerivedData/Skryn-*/Build/Products/Release/Skryn.app 2>&1 | grep -E "Authority=|Signature="

# 2. Zip the .app
cd ~/Library/Developer/Xcode/DerivedData/Skryn-*/Build/Products/Release && ditto -c -k --keepParent Skryn.app /tmp/Skryn.zip

# 3. Write release notes to a file (see format below), then create the release
gh release create v0.x.x /tmp/Skryn.zip --title "Skryn v0.x.x" --notes-file <notes.md>
```

**Release notes are hand-written — never use `--generate-notes`.** There are no PRs, so it produces only a changelog link. Write user-facing notes from the commits since the previous tag (`git log vPREV..HEAD`), matching earlier releases (`gh release view v0.1.4`):

```markdown
## What's new

- **Feature name** — what the user can now do, with keys in backticks (`T`, `⇧⌘ Drag`).

## Fixes

- User-visible bug fixed, described by its symptom.

**Full Changelog**: https://github.com/rsedykh/skryn/compare/vPREV...vNEW
```

Describe behavior, not implementation — leave out refactors, tests, and internal changes. Omit the Fixes section if there are none.

**User install:** Download `Skryn.zip` from [Releases](https://github.com/rsedykh/skryn/releases) → unzip → drag to Applications → on first launch, System Settings → Privacy & Security → Open Anyway (right-click → Open also works on macOS 14, not on 15+). Grant Screen Recording permission when prompted.

**Screen Recording permission after update:** From v0.1.6 on, releases are signed with a stable certificate, so the permission survives updates. Updating from v0.1.5 or earlier (signed ad hoc) needs a one-time reset: remove Skryn from System Settings → Privacy & Security → Screen Recording, then re-add it (toggling off/on doesn't work).

## Website

`docs/` is the GitHub Pages site for skryn.app (served from `main` `/docs`, with `CNAME`). It's one self-contained `index.html` (inline CSS and JS, no build step, dark only) plus `docs/assets/`. The only external request is the demo video, hosted as a GitHub user-attachment.

- **Marks** on the page are drawn by JS from `data-mark` attributes (`rect`, `ellipse`, `line`, `arrow` with `data-to`) inside `data-ink` blocks, so they follow reflow. Keep them in the app's style: 3pt strokes, 18pt arrowheads at ±30°.
- **Demo:** devices with a fine pointer get a browser replica of `AnnotationView` behind Skryn's blur (`initDemo()`, `initPlayground()`); touch devices get the video. The replica copies the app's drawing (stroke widths, arrowheads, badge size, colors, blur block size `max(max(w, h) / 40, 10pt)`) and key handling, so change it together with `AnnotationView.swift` / `Annotation.swift`.
- **Copy** only states what the app does: no "free", no "open source" (there's no LICENSE), no speed numbers.

## Key Gotchas

- **`NSApp.delegate` is SwiftUI's wrapper, not our `AppDelegate`.** With `@NSApplicationDelegateAdaptor`, `NSApp.delegate as? AppDelegate` returns nil. Always pass direct references (e.g., `weak var appDelegate`) instead of casting `NSApp.delegate`.
- **Cmd+ shortcuts need `performKeyEquivalent`, not `keyDown`.** When a main menu is installed, the menu system intercepts Cmd+ key combos via `performKeyEquivalent` before they reach `keyDown`. Use `performKeyEquivalent` for Cmd+ shortcuts in views.
- **NSTextView subviews must have isolated undo managers.** When an NSTextView is a subview, it inherits the parent's undo manager via the responder chain. Its internal text-editing undo operations (targeting text storage) leak into the parent's undo stack. When the text view is removed and deallocated, those operations become dangling pointers → crash on Cmd+Z. Fix: subclass NSTextView and override `undoManager` to return its own instance (`IsolatedUndoTextView`).
- `project.pbxproj` is hand-crafted with simple hex IDs (AA000001, AB000001). Keep this convention when adding files. IDs `AB000008`/`AB000009` are taken by Skryn.entitlements and Info.plist, `AB000016` by Signing.xcconfig. IDs count up in decimal digits (AB000019 → AB000020). Latest source file IDs: `AB000036` (file ref), `AA000033` (build file; `AA000029` is the libwebp package product). Latest test file IDs: `AB100012` (file ref), `AA100011` (build file). Swift package objects use `AG…` (`AG000001` reference, `AG000002` product).
- Borderless windows don't support `performClose(_:)` — Close (Cmd+W) routes through `AppDelegate.closeKeyWindow()`, which calls `close()` on the key window.
- **One main menu for every window.** `installMainMenu()` is used for the annotation window, settings, and about panels. Don't install a reduced menu for panels — opening one while annotating would strip Undo/Close from the annotation window.
- **Undo while editing text.** NSTextView doesn't implement `undo:`/`redo:`, so the menu action reaches `AnnotationView.undo(_:)`, which forwards to the text view's own undo manager during `.editingText`.
- **UserDefaults keys** live in `Defaults` (and `SaveAction.defaultsKey` for modifiers) in `SettingsPanel.swift` — don't use string literals. Exception: an upload provider's keys live in its own file.
- **Blur:** pixel blocks are at least `minBlurBlockSize` (10pt) so small regions stay unreadable. `blurCache` is keyed by rect and pruned (not cleared) on annotation changes; a blur being dragged renders uncached so intermediate frames don't accumulate.
- **Clipboard** writes one `NSPasteboardItem` with both PNG and TIFF data.
- `AppDelegate` is `@MainActor`; `Task {}` inside it runs on the main actor, so no `MainActor.run` hops are needed.
- `NSEvent.modifierFlags` (static) reads current keyboard state; `event.modifierFlags` (instance) reads state at event time. Always use the instance property for tool locking.
- When renaming variables, check ALL references in the same method — secondary uses are easy to miss.
- SwiftLint: `String.data(using: .utf8)!` triggers `non_optional_string_data_conversion` — use `Data("string".utf8)` instead.
- SwiftLint config limits: type_body_length 900/1100, file_length 1200/1400 (bumped for AnnotationView with text annotations, drag-to-move, blur, badges, ellipse, colors, and type-at-cursor text).
