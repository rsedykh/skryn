# Skryn

A lightweight macOS menu bar app for taking screenshots and annotating them.

## Usage

Click the camera icon in the menu bar to capture your screen. An annotation window opens where you can draw before saving.

**Tools** (hold modifier key while dragging):

- **Drag** — Arrow
- **Shift + Drag** — Line
- **Option + Drag** — Rectangle
- **Cmd + Drag** — Crop

**Shortcuts:**

- **Cmd+Enter** — Save to Desktop
- **Cmd+Z / Cmd+Shift+Z** — Undo / Redo
- **Esc** — Remove crop
- **Cmd+W** — Cancel
- **Cmd+Q** or **right-click** menu bar icon — Quit

## Build

Requires Xcode and macOS.

```bash
xcodebuild -project Skryn/Skryn.xcodeproj -scheme Skryn -configuration Release build
```
