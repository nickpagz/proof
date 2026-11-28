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
        AppState.finish ─► ImageExporter (PNG/JPEG/HEIC/WebP, 1x, sRGB) ─► captures folder
                       └─► clipboard          └─► QuickAccessController (thumbnail, drag out)
```

- SwiftPM compiles [the pinned libwebp sources](../Vendor/libwebp/UPSTREAM.md) into Proof.
  The app bundle includes the upstream notices. Proof writes lossless WebP with an ICC profile
  when available, but without DPI metadata, so reopened WebPs use pixel size as point size.
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

- **CloudUp** speaks two APIs, because cloudup.com is moving from one to the other on the same
  host (`api.cloudup.com`) and Proof has to work on both sides of that day. `CloudUpAccount.api`
  records which one a sign-in belongs to.
  - *Original API* (`api.cloudup.com/1`, Basic auth, documented at dev.cloudup.com): POST
    /streams, POST /items (which answers with an S3 POST policy), the file to S3 as a form with
    the file field last, then PATCH the item `complete`.
  - *Rebuilt CloudUp* (same host without `/1`, Bearer token): sign-in is the OAuth
    authorization-code flow with PKCE on a loopback listener at 127.0.0.1:52633
    (`auth.cloudup.com/auth`, then `POST /oauth/token`; `CloudUpAuth`). Tokens last six hours and
    are renewed with the refresh token, one renewal at a time (`CloudUpTokenStore`), because
    CloudUp replaces the refresh token on each use. Uploads are POST /streams, POST /items (which
    answers with a presigned `s3_url`), PUT the file there with only a Content-Type header, then
    PATCH the item `complete`.
  - *Telling them apart* (`CloudUpConfig.classify`): the rebuilt CloudUp answers every
    unauthenticated request, the old `/1` paths included, with `401 {"error":"access_denied"}`;
    the original answers 401 without that. Settings asks when it opens and shows the matching
    sign-in. A saved password that the server refuses this way gets "CloudUp has moved to signing
    in through the browser" instead of "wrong password".

  One stream per share on both, so a link never leads to other captures; delete removes the
  stream, and stream IDs survive the move, so older shares stay deletable. Once cloudup.com has
  moved, the original API's code can go.

  Browser sign-in needs a CloudUp OAuth app with redirect URL `http://127.0.0.1:52633/callback`.
  The rebuilt CloudUp has no open registration, so ask the CloudUp team for one. Its ID and secret
  come from `.secrets/cloudup.env`, injected into the built Info.plist:

  ```
  CLOUDUP_CLIENT_ID=…
  CLOUDUP_CLIENT_SECRET=…
  ```

  To try another CloudUp server, point Proof at it with that server's own app:
  `PROOF_CLOUDUP_API=https://<its API host>/1` plus `PROOF_CLOUDUP_CLIENT_ID` and
  `PROOF_CLOUDUP_CLIENT_SECRET`, then `Proof --sign-in cloudup`. Signing in there replaces the
  saved cloudup.com sign-in, so sign out and back in afterwards.
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

## Scrolling capture

`ScrollingCaptureController` puts a border, a bar and a preview around the chosen area and, on
Start, streams it with ScreenCaptureKit at up to 15 frames a second (BGRA, no cursor, Proof's
windows left out). Each frame goes to `ScrollStitcher` on the grabber's queue; frames that arrive
while one is being matched are dropped. The stitcher hashes every row and every column in six
sections across the area (ignoring the low bits of each channel and the 12 points where an overlay
scroll bar sits) and finds the shift that lines up most of the distinctive section-lines that
changed: blank lines repeat, so they don't vote, and anything that stays put (a header, a footer,
a feedback tab on the side) can't show movement, so it doesn't either. Sections keep a tab or
button from spoiling the whole row it crosses. The first movement fixes the direction.

Rows that stay put across the whole width at the bottom are a footer, kept once. The header runs
from the top down to the first line where content is seen moving with the scroll, ending at the
last line above it that stayed put or changed in place. It needn't be the same from frame to frame:
Safari's toolbar on macOS 26 is tinted by the page under it, and sticky bars (Google's search bar)
slide in once the page scrolls. A change whose earlier view was covered (by a side tab, say)
doesn't count, so a tab can't pass for a header. Anything else that
stays put while the content moves, or doesn't match where its content was (a "new updates"
button, a toast fading in, a link preview), marks that spot on screen as covered for the next
eight moves. A line goes into the image once it has been seen twice, isn't covered, and matches its
earlier view. So something fixed over the page shows up only once, in the last view, and the first
frame is kept only down to the first covered line. Lines about to slide under the header or off the
edge go in from the previous frame either way, so nothing is skipped. Scrolling back is ignored,
and a frame with no overlap (scrolled too fast) asks the person to scroll back a little, since
matching always resumes from the last accepted frame. The image is capped at 50,000 pixels long or
400 MB.

Auto-scroll (vertical only) needs Accessibility, because it posts scroll events to another app.
Scroll events go to whatever is under the pointer, so it only scrolls while the pointer is inside
the area (and not over the bar). Outside, it pauses and a click-through panel over the area asks
for the pointer back; that panel is put up before the stream starts, empty, so the capture leaves
it out. It aims to move a quarter of the area each step, in six small pixel-unit wheel events.
Apps don't all scroll exactly as far as asked, so it measures the ratio of what moved to what it
asked for and corrects the next ask. After each step it waits for the stitcher to report something
and then 0.3 seconds of quiet. If nothing moves for 1.5 seconds after a full step, it's the end of
the page and the capture finishes. If the stitcher loses track, it scrolls back the part the
stitcher didn't follow, which returns the page to the last frame the stitcher saw, and halves the
step, which grows back after steps that work. Each step is written to
`~/Library/Logs/Proof/proof.log`.

## Agents (MCP)

`Proof --mcp` is a Model Context Protocol server on stdin and stdout (`Agent/MCPServer.swift`):
newline-delimited JSON-RPC, `initialize`, `ping`, `tools/list` and `tools/call`. It does no
capturing itself. Started by an agent app, the binary would count as part of the agent's terminal
for Screen Recording, so each tool call goes over a Unix socket to the running app
(`AgentLink.socketPath`, in `~/Library/Application Support/io.github.nickpagz.proof/`, a folder
and socket only the user can open; the app also checks each connection's user). If the app isn't
running the bridge opens it and waits for the socket; if Settings → Agents is off it says so
without starting anything.

Tool calls run side by side. The bridge reads stdin on its main thread and runs each `tools/call`
on a worker, so a `notifications/cancelled` can arrive mid-call; it passes `{"cancel": id}` to the
app and sends no reply for that call. When the agent sends a `progressToken`, progress the app
reports (`AgentProgress` lines before the answer) goes out as `notifications/progress`: scrolling
captures report the length so far, uploads and GIF exports a fraction. One reader thread on each
side matches lines to calls by id; `LineWriter` keeps writes whole.

In the app, `AgentServer` listens only while `allowAgents` is on, and runs each request as its own
task through `AgentTools`; a cancel cancels that task, and so does the connection closing.
`ask_for_area` opens `SelectionOverlay` with the agent's prompt at the top and captures what the
person picks (Escape or the time limit report nothing picked; cancelling closes the overlay).
`open_in_editor` opens the image in the editor and adds the agent's annotations as editable
objects; nothing is saved until the person saves. Captures reuse `ScreenGrabber`, `ImageExporter` and `FileNaming`; `annotate` maps the
agent's list onto editor annotations (`AgentAnnotations`) and draws them with
`AnnotationRenderer`. An arrow or line can carry a `label`, a text annotation measured with the
renderer's own text size and set where the line, carried on past the tail, enters it 6 points out,
kept inside the image. The reply lists where each annotation landed, in the saved image's points
(shifted by the padding when there's a background). Recordings use `RecordingSession` directly, with a red `AreaBorderPanel` put
up first so the recording leaves it out, and a 2-minute limit; `stop_recording` also returns frames
from across the video (six by default, the middle of each equal stretch, taken exactly at those
times with `AVAssetImageGenerator`) in one two-column sheet, each labelled with its time, so an
agent can check what it recorded; `share` uses
`SharingController.upload(file:visibility:)`, which records the upload in Recent shares and leaves
the clipboard alone. `capture_scrolling` runs `ScrollingCaptureController.captureForAgent`: the
window comes to the front, the pointer goes to the middle of the area (and back afterwards), the
page goes to the top unless `from_top` is false, then auto-scroll runs to the end with the usual
bar, so the person can stop it; if auto-scroll gives up, the agent gets what was joined so far, and
a cancel or a five-minute limit answers it too. If the page moves back instead of on (a bounce at
the end, or a page that reloads to its top), auto-scroll finishes there; if it loses track and
gives up, the agent is told the image may be incomplete. Tall images reach the agent as up to eight parts
from top to bottom, wide enough to read, and the reply says where each part starts. Every image result carries a preview at one pixel per point (scaled down to
1568 px on the long side, and JPEG past 3 MB), so coordinates in what the model sees are the ones
`annotate` takes. `AgentNotice` shows what happened under the menu bar, and Settings → Agents
lists this session's activity.

To try the bridge by hand:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"test"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_windows","arguments":{}}}' \
  | /Applications/Proof.app/Contents/MacOS/Proof --mcp
```

## Headless test modes

The bundle's binary doubles as a CLI. `--help` lists everything.

```bash
R=build/Proof.app/Contents/MacOS/Proof
swift test --build-system native                 # scrolling capture stitching, the MCP server, deletion responses, Recent shares; no accounts needed
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
$R --share image.png --to cloudup|wordpress [--delete-after [--wait N]]
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
