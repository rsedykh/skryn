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

**Flow:** Menu bar click → `ScreenCapture.capture()` (ScreenCaptureKit, 2x resolution) → `AnnotationWindow` (90% of screen, borderless, rounded corners, shadow) → `AnnotationView` (drawing + input) → Save PNG to Desktop.

**Coordinate system:** Annotations are stored in **screenshot coordinates** (full image resolution), not view coordinates. Mouse input is converted via `viewToScreenshot()`. Drawing uses `NSAffineTransform` to map screenshot space back to view space. This means `compositeImage()` needs no transform — annotations composite directly at full resolution.

**Activation policy toggle:** The app is `LSUIElement=true` (no Dock icon). When the annotation window opens, it switches to `.regular` (appears in Cmd+Tab) and installs a main menu. On window close, it reverts to `.accessory`.

**Keyboard shortcuts** are handled via the installed `NSApp.mainMenu` (Cmd+W, Cmd+Z, Cmd+Shift+Z, Cmd+Q) for proper cross-layout support. ESC and Cmd+Enter use `keyDown` with keyCodes (layout-independent).

**Tool selection:** Modifier keys at `mouseDown` time determine the tool — plain drag = arrow, Shift = line, Option = rectangle, Command = crop. Only one crop allowed at a time.

## Key Gotchas

- `project.pbxproj` is hand-crafted with simple hex IDs (AA000001, AB000001). Keep this convention when adding files.
- Borderless windows don't support `performClose(_:)` — Close routes through `AppDelegate.closeAnnotationWindow()` instead.
- `NSEvent.modifierFlags` (static) reads current keyboard state; `event.modifierFlags` (instance) reads state at event time. Always use the instance property for tool locking.
- When renaming variables, check ALL references in the same method — secondary uses are easy to miss.
