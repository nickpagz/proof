<p align="center"><img src="Assets/AppIcon-1024.png" width="128" alt=""></p>

<h1 align="center">Proof</h1>

<p align="center"><strong>Screenshots for your Mac, saved where you want them.</strong></p>

<p align="center">
Proof lives in your menu bar. Press ⇧⌘4, drag over what you want to show, and it's saved and
waiting in the corner of your screen, ready to drag into a chat, a document or an email.
</p>

---

## Why we built it

A good screenshot tool shouldn't be another subscription. Proof does the parts of a paid
screenshot app that people use every day, with Apple's frameworks and nothing else, and keeps every
capture on your Mac unless you decide to share it.

## What it does

- **Captures** an area, a window (with or without its shadow), the whole screen, or the same area
  as last time. A crosshair and magnifier help you land on the right pixel.
- **All-In-One** (⇧⌘5) keeps the selection adjustable, with handles and a toolbar to switch modes
  or start the self-timer.
- **Hides desktop icons** in every capture, without touching your desktop.
- **Editor first, or save first**: by default each capture opens in the editor and nothing is
  saved until you choose Save as…. Or switch Settings → After capture to save straight away and
  keep a Quick Access thumbnail in the corner: drag it into any app, or hover to annotate, copy
  or save.
- **Annotate**: rectangles, ellipses, lines, arrows, text, counters, pencil and highlighter,
  pixelate and blur for anything private, spotlight, crop, and a background tool that puts the
  capture on a gradient with padding, rounded corners and a shadow. Everything stays editable
  until you save, with full undo. Single-key tools: V R F O L A T X B S N P H C.
- **Shares** with two buttons in the editor. **Share Private** uploads to CloudUp (an unlisted
  link of its own) and **Share Public** to your WordPress.com site's media library, under a random
  file name so the link doesn't give away what it is. Either button can use either service. The
  link is copied, and Settings → Sharing keeps a list of recent shares where you can copy a link
  again or delete the upload.
- **Saves** PNG, JPEG or HEIC to your Downloads folder (or anywhere), named the way you like.
- **Works with your keyboard**: ⇧⌘3, ⇧⌘4 and ⇧⌘5 by default, every action rebindable, and
  `proof://` links for Raycast, Alfred and Shortcuts.
- Talks to GitHub once a day to look for a new version. No analytics, nothing else.

Coming next: screen recording, capture history, text recognition, pinning, and S3-compatible
storage as another sharing destination. See [PLAN.md](PLAN.md) if you have it locally.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/nickpagz/proof/trunk/install.sh | sh
```

It fetches the latest release, checks it, puts Proof in your Applications folder and opens it.
Run it again later to upgrade, or let Proof update itself. (While the repository is private, build
from source instead; see below.)

You'll need a Mac with Apple silicon running macOS 26 or later. Allow Screen Recording when macOS
asks, then reopen Proof.

### Taking over ⇧⌘3, ⇧⌘4 and ⇧⌘5

macOS keeps those shortcuts for its own screenshot tool. Turn them off in System Settings →
Keyboard → Keyboard Shortcuts → Screenshots, and quit any other screenshot app that uses them.
Settings → Shortcuts in Proof shows a warning when a shortcut is taken.

## Using it

| Shortcut | What it does |
|---|---|
| ⇧⌘4 | Capture an area. Click without dragging to capture the window under the pointer. |
| ⇧⌘5 | All-In-One: adjust the selection, then Capture or press Return |
| ⇧⌘3 | Capture the screen under the pointer |

While selecting: **Space** switches to window mode, **Space while dragging** moves the selection,
**Shift** makes a square, **Option** draws from the centre, the **arrow keys** nudge (Shift for
10 points, Option to resize), **Escape** cancels.

`proof://capture-area`, `capture-previous-area`, `capture-fullscreen`, `capture-window`,
`all-in-one`, `self-timer`, `toggle-desktop-icons`, `restore-recently-closed` and `open-settings`
do what they say.

## For developers

Proof is written in Swift with Apple frameworks only and builds with SwiftPM; no Xcode project.
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) covers building, the headless test commands, signing
and releases. The build, signing and self-update machinery comes from
[Loominate](https://github.com/a8cteam51/loominate).

## License

[GPL-2.0-or-later](LICENSE).
