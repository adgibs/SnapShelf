# SnapShelf

A macOS menu bar screenshot tool that keeps every capture on screen until you have used it.
Captures appear as thumbnails in a screen corner; drag one into any app to drop a real PNG file.

macOS 14 or later. Swift, SwiftUI and AppKit, ScreenCaptureKit for capture. No third-party
dependencies, no network access, no analytics.

## Build

```bash
make app     # builds and signs build/SnapShelf.app
make run     # builds, then relaunches the app
make test    # unit tests
```

`make app` signs with the first valid "Apple Development" identity in your keychain, so the
Screen Recording permission survives rebuilds. To pick another identity or bundle ID:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" BUNDLE_ID=com.example.SnapShelf make app
```

The script refuses to fall back to ad-hoc signing, because that resets the permission on every build.

The app icon is drawn in code. To change it, edit `Scripts/make-icon.swift` and run
`swift Scripts/make-icon.swift`, which rewrites `Support/AppIcon.icns`.

## Granting the permission

On first launch SnapShelf explains why it needs Screen Recording access. Click **Grant Access**
(or **Open System Settings**), turn on SnapShelf under Privacy & Security › Screen & System Audio
Recording, then click **Relaunch SnapShelf**. If access is missing when you press a hotkey, the same
window comes back instead of a black image.

## Default hotkeys

| Action | Hotkey |
| --- | --- |
| Capture area | ⌃⇧4 |
| Capture window | ⌃⇧5 |
| Capture full screen (display under the pointer) | ⌃⇧3 |
| Capture text (OCR to clipboard) | ⌃⇧T |
| Reopen last capture in the overlay | ⌃⇧R |

Change them in Settings (menu bar icon › Settings…). During a selection, Esc or a right-click
cancels. Pressing the hotkey again also cancels.

## Using it

- **Thumbnails** stay in the bottom-left (or bottom-right) corner until you act on them. Drag one
  out to drop the PNG, hover for Copy, Save, Annotate, Pin and Close, or swipe sideways with two
  fingers to dismiss. Up to five stack, newest at the bottom.
- **Menu bar icon** lists the last 20 captures. Drag a row out, click it to reopen it in the
  overlay, or use its Copy and Reveal in Finder buttons.
- **Annotate** opens an editor: select, arrow, rectangle, ellipse, line, freehand, text, numbered
  steps, highlighter, blur, pixelate and crop, with undo and redo. Objects stay movable and
  restylable (use the Select tool; Delete removes, double-click text to edit, Shift constrains).
  Copy, Save, or drag the edited image out from the toolbar handle.
- **Pin** floats a capture above all windows. Drag to move, drag an edge to resize, scroll or
  right-click to change opacity, Esc or right-click › Close to remove.
- **Settings**: hotkeys, after-capture actions (copy to clipboard, show overlay, save to folder),
  save folder (default `~/Pictures/SnapShelf`), file name pattern, PNG or JPEG, self-timer, hide
  desktop icons, overlay corner, auto-dismiss, launch at login.

Dragged files are always PNG at native pixel resolution; the PNG/JPEG setting applies to files
saved to the save folder.

## What it stores, and how it is cleaned up

| Location | Contents | Limit |
| --- | --- | --- |
| `~/Library/Application Support/SnapShelf/History` | The last 20 captures as PNG, each with a small thumbnail, plus `index.json` | Oldest is deleted as each new capture arrives. A capture still on the shelf or open in the editor is kept until released. Folders the index does not know about are deleted at launch. **Clear** in the menu empties it. |
| `$TMPDIR/SnapShelf-drag` | The edited image while you drag it out of the annotation editor | One file per open editor, removed when the editor closes or exports again, and the whole folder is emptied at launch. |
| `~/Library/Preferences/app.snapshelf.SnapShelf.plist` | Settings | A few kilobytes. |
| Your save folder | Only what you save | Never cleaned up by SnapShelf. |

Nothing else is written: no caches, no logs of its own, no network storage. To remove every trace,
quit the app and delete the first and third rows.

## Automation

The app registers a `snapshelf://` URL scheme, handy for scripts and testing:

```bash
open -g "snapshelf://capture/area"                      # also window, screen, text
open -g "snapshelf://capture/area?x=100&y=200&w=400&h=300"   # fixed rectangle, main display, points
open -g "snapshelf://reopen"                            # also settings, annotate, pin
```

Launching with `--dock` (`open build/SnapShelf.app --args --dock`) gives the app a Dock icon, which
UI automation tools need in order to see it.

## Layout

| Module | Contents |
| --- | --- |
| `SnapShelfKit` | Settings, hotkey model, image encoding, file naming, clipboard, file drag source |
| `SnapShelfCapture` | ScreenCaptureKit capture, area and window selection overlay, permission, OCR |
| `SnapShelfOverlay` | Quick access thumbnails, pinned captures |
| `SnapShelfHistory` | History store and the menu bar list |
| `SnapShelfSettings` | Settings window, hotkey recorder, launch at login |
| `SnapShelfAnnotate` | Annotation editor |
| `SnapShelf` | App shell: hotkeys (Carbon), menu bar item, capture pipeline, onboarding |

## What has been checked, and what has not

Checked on a two-display, non-Retina setup (2 × 2560×1440):

- 24 unit tests pass (image files, file naming, history and its clean-up, save export, settings,
  drag payload, annotation rendering and undo).
- Real area, full-screen and window captures produce valid PNGs at native pixel size.
- A fixed-rectangle capture matches the same region of a full-screen capture pixel for pixel
  (0.2% of values differed, from content that changed between the two shots).
- SnapShelf's thumbnails are absent from a full-screen capture taken while they were showing.
- Hotkey to selection overlay: 9 ms. Memory after launch: 57 MB.
- Dragging a thumbnail out with a real pointer drag: Finder received a 600×400 PNG byte-identical
  to the capture in history, TextEdit embedded the image, and Notes attached the PNG under its
  file name. The thumbnail dismissed itself after each accepted drop.

Not checked, because it needs hands on the pointer or hardware that was not available:

- **Dragging a thumbnail into Slack, Mail, a browser and Figma.** Finder, TextEdit and Notes are
  confirmed. The drag carries a copy-only file URL plus the PNG bytes; the Finder drop was done
  before the PNG bytes were added and has not been repeated since.
- Drawing in the annotation editor, the swipe-to-dismiss gesture, and pin resizing and opacity.
- Retina and mixed-DPI displays. Capture sizes come from ScreenCaptureKit's point-to-pixel scale
  per display and selections snap to whole pixels, but only 1× displays were tested.
- Capture Text, the self-timer, hide desktop icons, launch at login, and JPEG saving in the running app.

## Not built

- Phase 3: screen recording to MP4 and GIF, scrolling capture, capture backgrounds and padding.
- Layout-aware hotkey names: key names in Settings assume a US/UK-style layout.

## Licence

MIT. See [LICENSE](LICENSE).
