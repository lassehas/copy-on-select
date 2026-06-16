# copy-on-select

A tiny macOS menu-bar app that **automatically copies selected text to the clipboard** — anywhere on your system.

Inspired by the *copy-on-select* behavior in terminals (and the Claude Code terminal): in those, the moment you highlight text it's already on the clipboard, no `⌘C` needed. This app brings that same convenience to **all of macOS** — any app, any text field, system-wide — as a lightweight background agent.

Highlight text with the mouse or keyboard → it's instantly on your clipboard, ready to paste.

---

## How it works

The app runs as a background **menu-bar agent** (no Dock icon, no window). It watches for text-selection gestures globally and copies whatever you've selected.

### Capturing selections

It listens for two kinds of selection gesture via a global event tap (`CGEventTap`):

- **Mouse drag-select** — press, drag past a small threshold, release. On release it grabs the selection.
- **Keyboard shift-select** — `Shift`+arrows, `Shift`+`⌘`+arrows (line/document), `Shift`+`⌥`+arrows (word), `Shift`+`Home`/`End`/`PageUp`/`PageDown`. It captures once the selection is finalized.

To read the selected text it tries two strategies:

1. **Accessibility API** (`kAXSelectedTextAttribute`) — reads the selection directly from the focused UI element. Clean and non-intrusive; preferred.
2. **Synthetic `⌘C` fallback** — for apps that don't expose their selection to the Accessibility API (e.g. some Electron/web apps like VS Code), it synthesizes a copy and reads the result from the pasteboard.

### Getting it right

A few details keep it from being annoying:

- **Keyboard: capture on `Shift`-release, not per keystroke.** Holding `Shift`+`↓` across several lines fires many key events. Instead of copying on each (which would spam your clipboard with growing fragments), it waits until you *release* `Shift` — i.e. the selection is final — and copies once. A generous debounce timer is a safety net if the release is ever missed.
- **Deduplication.** It never writes the same text to the clipboard twice in a row, so repeated or overlapping captures don't pollute your clipboard history.
- **Drag threshold.** A plain click isn't a selection; only a drag past ~3px counts, so clicking around never clobbers your clipboard.

---

## Permissions

macOS gates reading other apps' content behind **Accessibility** permission — there's no way around it, and it's the same prompt tools like Maccy or Raycast use.

On first run, open the menu-bar icon and choose **Grant Accessibility Access…**, then enable **copy-on-select** under:

> System Settings → Privacy & Security → Accessibility

The menu reflects the current permission status and re-checks it automatically, so if you grant access while the app is running it'll start working without a relaunch (toggle off/on once if it doesn't pick it up immediately).

> **Note:** because it needs a global event tap and the Accessibility API, the app **cannot be sandboxed** (App Sandbox is off; hardened runtime is on). That's why it isn't distributed via the Mac App Store — same as other clipboard/automation utilities.

---

## Using it

The menu-bar icon (a ring + cursor) gives you:

- **Copy on Select** — toggle the feature on/off (persists across launches).
- **Accessibility: Granted / Not granted** — current permission status, with a **Grant Access…** shortcut when needed.
- **Quit**.

That's it. With the toggle on and permission granted, just select text the way you always do.

---

## Building

Open `copy-on-select.xcodeproj` in Xcode and Run, or build from the command line:

```sh
xcodebuild -project copy-on-select.xcodeproj -scheme copy-on-select -configuration Release build
```

### Packaging a `.dmg`

```sh
./scripts/build-dmg.sh
```

This clean-builds the Release app and packages it into `dist/copy-on-select-<version>.dmg`, with an `Applications` symlink for drag-to-install.

The DMG is **not signed for distribution or notarized**. It runs on the build machine; on *other* Macs, Gatekeeper will warn ("unidentified developer"). Recipients bypass with **right-click → Open** once, or:

```sh
xattr -dr com.apple.quarantine /Applications/copy-on-select.app
```

Each machine also needs Accessibility permission granted separately. For clean installs on any Mac, the app would need **Developer ID signing + notarization**.

---

## Requirements

- macOS 15.7+
- Xcode 26+ to build

## License

[MIT](LICENSE) © 2026 Lasse Haslund

---

## Project layout

```
copy-on-select/
  copy_on_selectApp.swift   App entry point (background agent, no window)
  AppDelegate.swift         Menu-bar UI, toggle, Accessibility permission flow
  SelectionWatcher.swift    The core: event tap, selection capture, clipboard write
  Assets.xcassets/          App icon + menu-bar template icon
scripts/
  build-dmg.sh              Build Release and package a .dmg
```
