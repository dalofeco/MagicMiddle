# MagicMiddle

A lightweight macOS menu bar utility that adds middle-click support to the Magic Mouse — no extra hardware required.

Touch the center of your Magic Mouse and click to fire a middle mouse button event, with full drag support. Perfect for panning and rotating viewports in 3D applications like Blender, Maya, and CAD tools.

---

## How it works

The Magic Mouse has no physical middle button, which makes it awkward to use in 3D software that relies on middle-click to pan and rotate the viewport.

MagicMiddle bridges that gap:

1. **Rest one finger in the center zone** of the Magic Mouse surface.
2. **Click** — MagicMiddle intercepts the left click and converts it to a middle mouse button event.
3. **Hold and drag** — the middle button state is maintained for the full duration of the drag, so viewport navigation feels natural and continuous.

Release the button and everything returns to normal left-click behavior.

You can also trigger a middle click by holding **Fn + Click** if you prefer a keyboard modifier over touch detection.

---

## Features

- **Center-touch detection** — detects a single finger resting in the configurable center zone of the Magic Mouse before a click
- **Full drag support** — maintains middle button state through the entire drag, not just the initial click
- **Adjustable trigger zone** — a preferences slider lets you widen or narrow the center zone to match your grip
- **Magic Mouse only by default** — built-in trackpad is ignored unless you explicitly opt in via preferences
- **Fn + Click fallback** — works as an alternative trigger for users who prefer a modifier key
- **Runs silently in the background** — menu bar icon only, no Dock presence

---

## Installation

### Option 1: Download

1. Go to the [Releases](../../releases) page.
2. Download `MagicMiddle_Installer.dmg`.
3. Open the DMG and drag **MagicMiddle** into your **Applications** folder.
4. Launch the app. On first run, macOS will ask you to grant **Accessibility** permissions — this is required for the event tap to intercept mouse events.

### Option 2: Build from source

```bash
git clone https://github.com/dalofeco/MagicMiddle.git
cd MagicMiddle
chmod +x build.sh
./build.sh
```

The compiled `MagicMiddle.dmg` will appear in the project folder.

---

## Preferences

Click the **MM** icon in the menu bar and choose **Preferences…** to open the settings panel.

| Setting | Description |
|---|---|
| **Trigger Zone Width** | Controls how wide the center detection area is. Narrow = only the very center triggers; Wide = a larger portion of the mouse surface triggers. |
| **Also enable on trackpad** | Extends center-touch detection to the built-in trackpad. Disabled by default. |

---

## Permissions

MagicMiddle requires **Accessibility** access (System Settings → Privacy & Security → Accessibility) to intercept and rewrite mouse events system-wide. It does not collect or transmit any data.

---

## License

MIT License
