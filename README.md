# Skryn

A lightweight macOS menu bar app for taking screenshots and annotating them.

https://github.com/user-attachments/assets/e71aa5b3-80e6-4399-9993-0efe7728c68f

## Installation

1. Download `Skryn.zip` from the [latest release](https://github.com/rsedykh/skryn/releases/latest)
2. Unzip and drag `Skryn.app` to your Applications folder
3. Open the app. macOS blocks the first launch because Skryn isn't notarized by Apple: go to System Settings → Privacy & Security and click **Open Anyway** (on macOS 14, right-click the app → Open also works)
4. Grant Screen Recording permission when prompted

### Updating

Since v0.1.6, Skryn is signed with a stable certificate, so Screen Recording permission carries over when you update.

Updating from v0.1.5 or earlier needs a one-time reset, because the signature changed. If screenshots stop working:

1. Go to System Settings → Privacy & Security → Screen Recording
2. Remove Skryn from the list
3. Take a screenshot; Skryn will ask for permission again

## Usage

Click the camera icon in the menu bar or press **Cmd+Shift+5** (configurable in Settings) to capture your screen. An annotation window opens where you can draw before saving. You can also drag an image file onto the menu bar icon to open it for annotation.

**Shortcuts**

- **Drag** — Arrow
- **Shift + Drag** — Line
- **Cmd + Drag** — Rectangle
- **Option + Drag** — Crop
- **Control + Drag** — Blur
- **Esc** — Remove crop
- **Delete** — Remove hovered annotation
- **Cmd+Z / Cmd+Shift+Z** — Undo / Redo
- **T** — Type text at the cursor (over existing text, edits it)
- **U** — Insert capture time (UTC) at cursor
- **Cmd + + / Cmd + -** — Increase / Decrease text size
- **Shift + Enter** — new text line (Enter or Esc finishes the text; empty text is discarded)
- **Cmd+Enter** and **Option+Enter** and **Control+Enter** — Save to different locations (configurable in Settings)
- **Cmd+W** — Cancel screenshot

You can also hover over the annotation and change its size or drag it.

## Uploading to Dropbox

Skryn uploads with a Dropbox app that you create, so your files and access stay under your account. It takes about two minutes. The same steps are in Skryn under **Settings → Upload → Dropbox → Setup guide**.

1. **Create a Dropbox app.** Open the [Dropbox App Console](https://www.dropbox.com/developers/apps), sign in, and click **Create app**.
2. **Choose its access.** Choose **Scoped access**, then **App folder**: Skryn can only see its own folder, `Apps/<app name>`, never the rest of your Dropbox. Give the app any unique name and click **Create app**.
3. **Turn on the permissions.** Open the **Permissions** tab and check `files.content.write`, `sharing.write`, `sharing.read` and `account_info.read`. Then click **Submit** at the bottom of the page — the changes don't apply until you do.
4. **Copy the App key.** Open the **Settings** tab and copy the **App key**. In Skryn, open **Settings → Upload**, choose **Dropbox** as the Service, and paste it into **App key**. Skryn never needs the App secret.
5. **Connect.** Click **Connect Dropbox…**. Your browser opens Dropbox; click **Allow**. Dropbox shows a code: copy it, paste it into the **Code** field, and click **Finish**. Settings then shows "Connected as" your name.
6. **Upload.** Files go to `Dropbox/Apps/<app name>/`, and Skryn copies a public link to the file itself (`https://dl.dropboxusercontent.com/…`): it opens directly in a browser and embeds in Markdown, GitHub and chat. Anyone with the link can view the file.

**Troubleshooting**

- *"The Dropbox app lacks the … permission"* — turn it on in the **Permissions** tab and click **Submit**, then **Disconnect** and **Connect** again in Skryn. Dropbox grants permissions when you connect.
- *"The code is invalid or expired"* — codes work once and expire quickly. Click **Connect Dropbox…** again and paste the new code.
- *A link stopped working* — deleting the file, or its shared link in Dropbox, revokes it.
- New apps stay in **Development** status. That's fine for your own account; there's no need to apply for production.
- **Disconnect** revokes Skryn's access and removes the sign-in token from your Keychain.

## Build

Requires Xcode and macOS.

```bash
xcodebuild -project Skryn/Skryn.xcodeproj -scheme Skryn -configuration Release build
```
