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
3. Re-add it; the app will prompt for permission again

## Usage

Click the camera icon in the menu bar or press **Cmd+Shift+5** (configurable in Settings) to capture your screen. An annotation window opens where you can draw before saving.

**Annotations**

- **Drag** — Arrow
- **Shift + Drag** — Line
- **Option + Drag** — Rectangle
- **T** — Toggle text mode
- **Cmd + + / Cmd + -** — Increase / Decrease text size
- **Shift + Enter** — new text line (Enter will exit text mode)
- **Cmd + Drag** — Crop

You can also hover over the annotation and change its size or drag it.

**Shortcuts**

- **Cmd+Enter** and **Option+Enter** and **Control+Enter** — Save to different locations (configurable in Settings)
- **Cmd+Z / Cmd+Shift+Z** — Undo / Redo
- **Esc** — Remove crop
- **Cmd+W** — Cancel screenshot
- **Cmd+Q** or **right-click** menu bar icon — Quit

## Build

Requires Xcode and macOS.

```bash
xcodebuild -project Skryn/Skryn.xcodeproj -scheme Skryn -configuration Release build
```
