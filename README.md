# Skryn

A lightweight macOS menu bar app for taking screenshots and annotating them.

## Installation

1. Download `Skryn.zip` from the [latest release](https://github.com/rsedykh/skryn/releases/latest)
2. Unzip and drag `Skryn.app` to your Applications folder
3. Right-click the app → Open on first launch (required for unsigned apps)
4. Grant Screen Recording permission when prompted

### Updating

Since the app is unsigned, macOS may revoke Screen Recording permission after updating. If screenshots stop working:

1. Go to System Settings → Privacy & Security → Screen Recording
2. Remove Skryn from the list
3. Re-add it (toggling off/on doesn't work — you must remove and re-add)

## Usage

Click the camera icon in the menu bar to capture your screen. An annotation window opens where you can draw before saving.

**Tools** (hold modifier key while dragging):

- **Drag** — Arrow
- **Shift + Drag** — Line
- **Option + Drag** — Rectangle
- **Cmd + Drag** — Crop

**Shortcuts:**

- **Cmd+Enter** — Save
- **Cmd+Z / Cmd+Shift+Z** — Undo / Redo
- **Esc** — Remove crop
- **Cmd+W** — Cancel
- **Cmd+Q** or **right-click** menu bar icon — Quit

## Build

Requires Xcode and macOS.

```bash
xcodebuild -project Skryn/Skryn.xcodeproj -scheme Skryn -configuration Release build
```
