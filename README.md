# SlideSnap

A lightweight macOS menu bar app that instantly captures presentation slides from your screen. Press a keyboard shortcut, click the slide's background, and it's cropped to your clipboard — ready to paste into GoodNotes, Notability, or any other app via Universal Clipboard.

## How it works

1. Press **⌘⇧2** — screen dims instantly
2. Click the **background color** of the slide you want to capture (not on text or images)
3. SlideSnap detects the slide boundaries automatically
4. The cropped slide is copied to your clipboard and saved to `~/Documents/SlideSnap/`

You can also **drag to select** a custom region if auto-detection doesn't work for your layout.

Press **Esc** to cancel at any time.

## Install

### Download (recommended)

1. Go to [Releases](../../releases) and download **SlideSnap-Installer.dmg**
2. Open the DMG and drag **SlideSnap** to Applications
3. On first launch, right-click the app → **Open** (required since the app isn't notarized)
4. Grant **Screen Recording** permission when prompted (System Settings → Privacy & Security → Screen Recording)

### Build from source

1. Clone the repo and open `SlideSnap/SlideSnap.xcodeproj` in Xcode
2. Select your team in Signing & Capabilities
3. **⌘R** to build and run
4. Grant Screen Recording permission when prompted

## Usage

| Action | How |
|---|---|
| Capture a slide | **⌘⇧2**, then click the slide's background color |
| Manual selection | **⌘⇧2**, then drag to select a region |
| Cancel | **Esc** |
| Open saved captures | Menu bar icon → Open Captures Folder |
| Quit | Menu bar icon → Quit |

## Tips

- **Click on the solid background color** of the slide, not on text or images. The app uses that color to find the slide edges.
- Works great with **Universal Clipboard** — capture on your Mac, paste on your iPad.
- Slides are saved as PNGs in `~/Documents/SlideSnap/` as a backup.
- If multiple slides are stacked vertically with separators, it detects only the one you clicked.

## Requirements

- macOS 14 (Sonoma) or later
- Screen Recording permission

## License

[MIT](LICENSE)
