# Developing Proof

Proof is a menu bar app built with SwiftPM and a shell script that assembles the `.app` bundle.
No Xcode project; the Swift Command Line Tools are enough. It follows Loominate's model
(github.com/a8cteam51/loominate) for building, signing and updating.

## Build and run

```bash
make build        # swift build + assemble build/Proof.app (debug)
make run          # build, copy to /Applications, then open it there
make release      # optimized build
make dmg          # drag-to-Applications disk image in dist/
make clean
```

Launch the app from the bundle (`make run` does), never the bare `.build` binary: macOS ties the
Screen Recording grant to the bundle's code identity. If the project sits in an iCloud-synced
folder (~/Documents often is), iCloud adds Finder attributes to `build/Proof.app` after signing,
strict signature checks then fail, and macOS won't list Proof under Screen Recording. `make run`
copies the app to /Applications without those attributes, so run that copy.

### Signing

macOS ties Screen Recording and Keychain grants to the app's code signature, so every build must be
signed with the same identity. `Scripts/bundle.sh` uses `$SIGN_IDENTITY` if set, else the
self-signed "Proof Dev" certificate (`Scripts/make-dev-cert.sh` creates one, valid ten years), else
signs ad hoc. It never falls back to an Apple Development certificate, whose name includes an email
address anyone can read from the app. Without a Team ID, macOS ties Keychain access to the exact
build, so after each rebuild or update Proof asks once for the login password to read its saved
sign-ins (choose Always Allow). They're all in one item, "Proof sign-ins", read once per launch. Releases must use the same identity forever or
installed copies stop updating; see "Changing the signing identity" in Loominate's DEVELOPMENT.md,
which applies unchanged.

If a build was ever signed ad hoc, reset the stale grant and approve again:

```bash
tccutil reset ScreenCapture io.github.nickpagz.proof
```

## How it works

```
hotkey / menu / proof:// ─► SelectionOverlay (one window per display; area, window, All-In-One)
                                   │ result in global CoreGraphics points
                                   ▼
             ScreenGrabber (ScreenCaptureKit; Proof's windows and Finder's desktop icons excluded)
                                   │ Capture (CGImage + point size)
                                   ▼
        AppState.finish ─► ImageExporter (PNG/JPEG/HEIC, 1x, sRGB, DPI) ─► captures folder
                       └─► clipboard          └─► QuickAccessController (thumbnail, drag out)
```

- The editor keeps annotations as objects in image points (`AnnotationDocument`); crop and
  background only change the layout around them. `AnnotationRenderer` draws the canvas and every
  export with the same code, so the saved file matches the screen. Pixelate and blur read the
  original pixels through Core Image and are cached per rectangle. Undo snapshots the document;
  a mouse drag is one undo step.
- While an editor window is open Proof becomes a regular app (Dock icon, menu bar with Save, Undo
  and Copy) and goes back to menu-bar-only when the last editor closes.
- Coordinates: AppKit's origin is bottom-left, CoreGraphics' top-left. Everything stored or passed
  to the capture engine is in CoreGraphics global points (`ScreenGeometry` converts).
- Area captures use `SCScreenshotManager.captureImage` with a `sourceRect`; window captures use
  macOS 26's `captureScreenshot`, which grows the image to fit the window shadow.
- Freeze screen crops the display snapshot taken when the overlay opened (the same snapshot feeds
  the magnifier); otherwise the area is captured fresh after selection.
- Global shortcuts use Carbon's `RegisterEventHotKey`, which needs no Accessibility permission.
  A shortcut another app owns fails to register and shows a warning in Settings → Shortcuts.
- Settings live in `UserDefaults` as one JSON blob (`preferences.v1`), decoded field by field so
  older builds' settings keep loading. The session log is `~/Library/Logs/Proof/proof.log`.

## Sharing

`Sharing/ShareProvider.swift` is the interface every destination implements (`upload`, `delete`,
`isReady`, `maxBytes`). Settings maps the editor's two share buttons (left and right) to a
provider each. Secrets live in the Keychain (`Keychain` in `Sharing/HTTP.swift`), everything else
in UserDefaults; `ShareHistory` keeps links and delete handles in
`~/Library/Application Support/Proof/shares.json`.

- **CloudUp** uses the original API (`api.cloudup.com/1`) with Basic auth: POST /streams, POST
  /items (which answers with an S3 POST policy), the file to S3 as a form with the file field last,
  then PATCH the item `complete`. One stream per share, so a link never leads to other captures.
  Delete removes the stream. CloudUp is being rebuilt (staff-only relaunch planned for late 2026,
  with OAuth and owner-only private screenshots); the provider will move to that API when it ships.
- **WordPress.com** signs in with the OAuth authorization-code flow on a loopback listener at
  127.0.0.1:52632 (Loominate uses 52631) and uploads with `POST /rest/v1.1/sites/{id}/media/new`.
  Videos go to VideoPress the way Loominate does it: an upload token from
  `POST /wpcom/v2/sites/{id}/media/videopress-upload-jwt`, then a resumable tus upload in 10 MB
  chunks (`TusUploader`), then the title; the link is `videopress.com/v/{guid}`. WordPress.com
  hands out upload tokens even to sites without VideoPress and refuses the finished upload with an
  empty HTTP 400, so each video share first reads the site's `options.videopress_enabled` (fresh,
  so a plan upgrade counts at once), as Loominate's site picker does. Sites without it, and any
  upload VideoPress still refuses, get the MP4 in the media library instead; network and server
  errors are reported. `TusUploader` logs a refusal's status, body and headers.
  The app's ID and secret come from `.secrets/wpcom.env`, injected into the built Info.plist:

  ```
  WPCOM_CLIENT_ID=…
  WPCOM_CLIENT_SECRET=…
  ```

  Register the app at developer.wordpress.com/apps (type Web, redirect URL
  `http://127.0.0.1:52632/callback`).
- **Adding a destination** (S3-compatible storage is next): implement `ShareProvider`, add a case
  to `ProviderKind` and `ShareDestination`, and a section to Settings → Sharing.

If a WordPress.com delete returns `403 unauthorized`, Proof checks the same media item with
an authenticated GET: the delete endpoint checks permissions before checking whether the attachment
exists. Only `404 unknown_media` confirms it is already gone. Proof then removes its Recent shares
entry and explains that the media no longer exists. Other failures keep the entry for retry; a
readable attachment with delete access denied reports a permission error rather than asking for a
new sign-in.

`Scripts/test-sharing.sh` runs real uploads and deletes for both services, with an image and a
12 MB video, against `Scripts/mock-share-server.py`, which plays CloudUp, S3, WordPress.com and
VideoPress and checks each request. Its site 124 has no VideoPress.

## Recording

`Recording/` is Loominate's recording engine without the camera bubble. `RecordingConfig` builds
the ScreenCaptureKit filter (an area is a display filter with a `sourceRect`; Proof's own windows,
the bar and border among them, are left out) and `RecordingSession` writes video and up to two
audio tracks to a .mov, starting at T0 after the countdown and repeating the last frame each
second through still stretches. `Mixdown` turns that into an .mp4 with one audio track, because
players (VideoPress included) play only the first. `RecordingController` runs the bar, border,
countdown and Stop; `VideoWindow` is the result window, with AVPlayerView's own trim bar.
`VideoExport` makes trimmed MP4s (encoded again, so the cut is frame-exact) and GIFs (the latest
frame at each 1/15 s, repeats merged into longer frames).

## Headless test modes

The bundle's binary doubles as a CLI. `--help` lists everything.

```bash
R=build/Proof.app/Contents/MacOS/Proof
swift test --build-system native                 # deletion responses and Recent shares persistence; no accounts needed
$R --self-test                                   # file names, geometry, shortcuts, encoders, prefs
$R --displays                                    # displays with global bounds
$R --windows                                     # capturable windows, frontmost first
$R --capture fullscreen --out /tmp/full.png
$R --capture area --rect 100,100,800,500 --format jpeg --1x
$R --capture window --window Safari [--no-shadow]
$R --ui-test overlay all-in-one 300,200,700,450 # the real overlay, no capture at the end
$R --ui-test quick-access /path/to/image.png     # a thumbnail in the Quick Access Overlay
$R --ui-test editor /path/to/image.png --demo    # the editor with one of every annotation
$R --render-demo /path/to/image.png --out /tmp/demo.png [--background]   # the renderer, no UI
$R --record area --rect 100,100,640,360 --seconds 3 [--mic] [--system-audio] --out /tmp/rec.mp4
$R --gif /tmp/rec.mp4 --out /tmp/rec.gif [--width 640] [--from 0.5 --to 2.5]
$R --trim /tmp/rec.mp4 --from 0.5 --to 2.5 --out /tmp/cut.mp4
$R --ui-test video /tmp/rec.mp4                  # the recording window
$R --ui-test recording-bar 200,200,800,450       # the bar and border, without recording
$R --providers                                   # sharing sign-in state and button mapping
$R --share image.png --to cloudup|wordpress [--delete-after]
Scripts/test-sharing.sh                          # both services end to end against a mock server
$R --check-update
```

Run from a terminal, captures use the terminal's Screen Recording permission. UI tests leave
global shortcuts, the updater and the permission prompt alone.

## Updates and releases

Exactly as in Loominate: `Scripts/publish.sh x.y.z` builds, signs, zips, signs `latest.json` with
the Ed25519 key in `.secrets/update-signing-key`, and publishes a GitHub Release that doubles as the
update feed. **Back up `.secrets/update-signing-key` and the signing certificate** (1Password);
without them no future release can be installed by existing copies.

While the repository is private, the feed URL and the curl installer can't be read anonymously.
Test the updater locally:

```bash
Scripts/publish.sh 0.1.0 --local
python3 -m http.server -d dist 8000 --bind 127.0.0.1
PROOF_UPDATE_FEED=http://127.0.0.1:8000/latest.json build/Proof.app/Contents/MacOS/Proof --check-update
```

## Icons

`Assets/proof-icon.svg` and `Assets/proof-menubar.svg` are the sources; `Scripts/make-icons.sh`
renders the `.icns` and menu bar PNGs with macOS's own SVG support. The outputs are committed.
