import AppKit
import Foundation

/// Command-line entry points, mostly for headless testing. `--help` prints `usage`.
enum CLI {
    static let usage = """
    usage: Proof [command]                (no command opens the menu bar app)

    Capturing (the terminal running this needs Screen Recording permission)
      --capture fullscreen [--display INDEX]
      --capture area --rect X,Y,W,H       global points, origin top-left of the main display
      --capture window --window SUBSTRING [--no-shadow]
          common: --out PATH (default: the captures folder)  --format png|jpeg|heic
                  --1x  --show-icons  --no-srgb
      --displays                          list displays with their global bounds
      --windows                           list capturable windows, frontmost first
      --permissions                       Screen Recording permission state

    Sharing (PROOF_CLOUDUP_API / PROOF_WPCOM_API point at a test server; see Scripts/mock-share-server.py)
      --providers                         sign-in state of each sharing service and the editor buttons
      --share <file> --to cloudup|wordpress [--title T] [--delete-after]
                                          upload a file, print the link; --delete-after removes it again

    Checks
      --self-test                         run the built-in checks (file names, geometry, encoding)
      --render-demo <image> --out PATH [--background]
                                          draw one of every annotation on an image, headlessly

    Updates (feed: GitHub Releases, or PROOF_UPDATE_FEED / defaults updateFeedURL)
      --check-update                      fetch and verify the feed, compare with this build
      --install-update [--no-launch]      install the newest release over this bundle and relaunch

    UI tests (launch through the bundle: open build/Proof.app --args …)
      --ui-test quick-access <image>      show an image in the Quick Access Overlay
      --ui-test overlay area|window|all-in-one [X,Y,W,H]
      --ui-test settings
      --ui-test editor <image> [--demo]   open the editor, optionally with one of every annotation
    """

    /// Returns normally when no CLI flag is present; otherwise runs the command and exits.
    static func runIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first, command.hasPrefix("-") else { return }
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffer stdout so output shows up when piped
        switch command {
        case "--help", "-h":
            print(usage)
            exit(0)
        case "--version":
            print(AppInfo.version)
            exit(0)
        case "--capture":
            runBlocking { await HeadlessCapture.run(Array(args.dropFirst())) }
            exit(0)
        case "--displays":
            for (index, screen) in NSScreen.screens.enumerated() {
                let id = ScreenGeometry.displayID(of: screen)
                let b = CGDisplayBounds(id)
                print("\(index): \(screen.localizedName) id=\(id) bounds=\(Int(b.minX)),\(Int(b.minY)),\(Int(b.width)),\(Int(b.height)) scale=\(screen.backingScaleFactor)\(id == CGMainDisplayID() ? " (main)" : "")")
            }
            exit(0)
        case "--windows":
            for window in ScreenGrabber.pickableWindows() {
                let f = window.frame
                print("\(window.id)\t\(window.ownerName)\t\(window.title)\t\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))")
            }
            exit(0)
        case "--permissions":
            print("screen recording: \(Permissions.screenRecordingGranted() ? "granted" : "not granted")")
            exit(0)
        case "--providers":
            let prefs = Preferences.load()
            for kind in ProviderKind.allCases {
                let provider = ShareProviders.make(kind)
                print("\(kind.label): \(provider.isReady ? "ready" : "not signed in")\(provider.destinationLabel.map { " · \($0)" } ?? "")")
            }
            print("Share Private → \(prefs.privateDestination.label), Share Public → \(prefs.publicDestination.label)")
            print("WordPress.com app in this build: \(WPComConfig.isConfigured ? "yes" : "no")")
            exit(0)
        case "--share":
            guard args.count > 1, let to = value("--to", in: args), let kind = ProviderKind(rawValue: to) else {
                fail("usage: Proof --share <file> --to cloudup|wordpress [--title T] [--delete-after]")
            }
            runBlocking { await ShareCLI.share(path: args[1], kind: kind, title: value("--title", in: args), deleteAfter: args.contains("--delete-after")) }
            exit(0)
        case "--self-test":
            exit(SelfTest.run() ? 0 : 1)
        case "--render-demo":
            guard args.count > 1, let out = value("--out", in: args) else { fail("usage: Proof --render-demo <image> --out PATH [--background]") }
            guard let (image, size) = loadImage(args[1]) else { fail("can't read \(args[1])") }
            var document = EditorDemo.document(imageSize: size, scale: CGFloat(image.width) / size.width)
            document.background.enabled = args.contains("--background")
            guard let rendered = AnnotationRenderer(image: image).render(document) else { fail("render failed") }
            do {
                try ImageExporter.write(rendered, pointSize: AnnotationRenderer.layout(document).outputSize, to: URL(fileURLWithPath: out), options: ImageExporter.Options())
            } catch { fail(error.localizedDescription) }
            print(out)
            exit(0)
        case "--check-update":
            requireBundle()
            runBlocking { await UpdateCLI.check() }
            exit(0)
        case "--install-update":
            requireBundle()
            runBlocking { await UpdateCLI.install(launch: !args.contains("--no-launch")) }
            exit(0)
        case "--ui-test":
            return   // handled by UITest once the app has launched
        default:
            // Any other dash-prefixed argument is a typo, not a request to open the app.
            FileHandle.standardError.write("Proof: unknown option \(command)\n\n\(usage)\n".data(using: .utf8)!)
            exit(64)
        }
    }

    static func requireBundle() {
        guard AppInfo.isRunningFromBundle else {
            fail("Run this command through the app bundle: build/Proof.app/Contents/MacOS/Proof …")
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        exit(1)
    }

    static func value(_ flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static func runBlocking(_ body: @escaping () async -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await body()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) != .success {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }
}

/// `Proof --capture …`: the same capture and export code the app uses, without the overlay.
enum HeadlessCapture {
    static func run(_ args: [String]) async {
        guard let kind = args.first else { CLI.fail("usage: Proof --capture fullscreen|area|window …") }
        let prefs = Preferences.load()
        var options = ImageExporter.Options(prefs)
        if let format = CLI.value("--format", in: args) {
            guard let parsed = ImageFormat(rawValue: format) else { CLI.fail("unknown format \(format)") }
            options.format = parsed
        }
        if args.contains("--1x") { options.scaleTo1x = true }
        if args.contains("--no-srgb") { options.convertToSRGB = false }
        let hideIcons = !args.contains("--show-icons")

        let capture: Capture
        do {
            switch kind {
            case "fullscreen":
                let screens = NSScreen.screens
                let index = Int(CLI.value("--display", in: args) ?? "0") ?? 0
                guard screens.indices.contains(index) else { CLI.fail("no display \(index); see --displays") }
                let id = ScreenGeometry.displayID(of: screens[index])
                let image = try await ScreenGrabber.capture(displayID: id, hideDesktopIcons: hideIcons)
                capture = Capture(image: image, pointSize: CGDisplayBounds(id).size, kind: .fullscreen, appName: nil, date: Date())
            case "area":
                guard let raw = CLI.value("--rect", in: args) else { CLI.fail("--capture area needs --rect X,Y,W,H") }
                let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard parts.count == 4 else { CLI.fail("--rect wants four numbers: X,Y,W,H") }
                let rect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                let image = try await ScreenGrabber.capture(rect: rect, hideDesktopIcons: hideIcons)
                capture = Capture(image: image, pointSize: rect.size, kind: .area, appName: nil, date: Date())
            case "window":
                guard let needle = CLI.value("--window", in: args)?.lowercased() else { CLI.fail("--capture window needs --window SUBSTRING") }
                guard let window = ScreenGrabber.pickableWindows().first(where: {
                    $0.ownerName.lowercased().contains(needle) || $0.title.lowercased().contains(needle)
                }) else { CLI.fail("no window matching \(needle); see --windows") }
                let (image, size) = try await ScreenGrabber.capture(windowID: window.id, shadow: !args.contains("--no-shadow"))
                capture = Capture(image: image, pointSize: size, kind: .window, appName: window.ownerName, date: Date())
            default:
                CLI.fail("unknown capture kind \(kind)")
            }
        } catch {
            CLI.fail("capture failed: \(error.localizedDescription)")
        }

        let url: URL
        if let out = CLI.value("--out", in: args) {
            url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        } else {
            let name = FileNaming.name(template: prefs.fileNameTemplate, date: capture.date, appName: capture.appName, kind: capture.kind)
            url = FileNaming.uniqueURL(in: prefs.saveFolder, name: name, ext: options.format.fileExtension)
        }
        do {
            try ImageExporter.write(capture.image, pointSize: capture.pointSize, to: url, options: options)
        } catch {
            CLI.fail(error.localizedDescription)
        }
        FileHandle.standardError.write("captured \(capture.kind.rawValue) \(capture.image.width)x\(capture.image.height) px (\(Int(capture.pointSize.width))x\(Int(capture.pointSize.height)) pt)\n".data(using: .utf8)!)
        print(url.path)
    }
}

enum UpdateCLI {
    static var running: (version: String, build: Int) {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleShortVersionString"] as? String ?? "0.0.0", Int(info["CFBundleVersion"] as? String ?? "") ?? 0)
    }

    static func check() async {
        print("feed: \(UpdateConfig.feedURL.absoluteString)\(UpdateConfig.usesFeedOverride ? " (override)" : "")")
        do {
            let payload = try await UpdateFeed().fetchManifest()
            let me = running
            print("latest: \(payload.version) (\(payload.build)), published \(payload.publishedAt), macOS \(payload.minimumSystemVersion)+")
            print("zip: \(UpdateConfig.zipURL(for: payload).absoluteString) · \(payload.zip.size) bytes · sha256 \(payload.zip.sha256)")
            print("running: \(me.version) (\(me.build)) at \(Bundle.main.bundleURL.path)")
            if payload.isNewer(thanVersion: me.version, build: me.build) {
                print("update available")
                do {
                    _ = try UpdateInstaller.preflight()
                    print("this copy can update itself")
                } catch {
                    print("but this copy cannot update itself: \(error.localizedDescription)")
                }
            } else {
                print("up to date")
            }
        } catch {
            CLI.fail("check failed: \(error.localizedDescription)")
        }
    }

    static func install(launch: Bool) async {
        let stderr = FileHandle.standardError
        do {
            let payload = try await UpdateFeed().fetchManifest()
            let me = running
            guard payload.isNewer(thanVersion: me.version, build: me.build) else {
                print("already up to date: \(me.version) (\(me.build)); the feed offers \(payload.version) (\(payload.build))")
                return
            }
            stderr.write("Installing \(payload.version) (\(payload.build)) over \(Bundle.main.bundleURL.path)\n".data(using: .utf8)!)
            let old = try await UpdateInstaller.install(payload, session: UpdateFeed.makeSession(), launchAfter: launch) { step in
                switch step {
                case .downloading(let done, let total):
                    stderr.write("  downloaded \(done)/\(total)\n".data(using: .utf8)!)
                case .verifying:
                    stderr.write("  verifying\n".data(using: .utf8)!)
                case .installing:
                    stderr.write("  installing\n".data(using: .utf8)!)
                case .identityChange(let notice):
                    stderr.write("  note: \(notice)\n".data(using: .utf8)!)
                }
            }
            print("Installed \(payload.version) (\(payload.build)). The old bundle at \(old.path) is removed\(launch ? " and the app relaunched" : "") as soon as this process exits.")
        } catch {
            CLI.fail("install failed: \(error.localizedDescription)")
        }
    }
}

/// `open build/Proof.app --args --ui-test …`: puts a piece of real UI on screen with no clicks,
/// so it can be screenshotted and checked.
@MainActor
enum UITest {
    static var isRequested: Bool { CommandLine.arguments.contains("--ui-test") }

    static func runIfRequested(state: AppState) {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--ui-test"), index + 1 < args.count else { return }
        let what = args[index + 1]
        let rest = Array(args.dropFirst(index + 2))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            switch what {
            case "quick-access":
                guard let path = rest.first, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    Log.note("ui-test quick-access: can't read image"); return
                }
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                let capture = Capture(image: image, pointSize: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale),
                                      kind: .area, appName: "UITest", date: Date())
                state.quickAccess.show(QuickAccessItem(capture: capture, savedURL: URL(fileURLWithPath: path)))
            case "overlay":
                // The overlay on its own, without the permission check or a capture at the end.
                var options = SelectionOverlay.Options()
                options.startMode = rest.first == "window" ? .window : .area
                options.allInOne = rest.first == "all-in-one"
                options.hasPreviousArea = true
                if let raw = rest.dropFirst().first {
                    let n = raw.split(separator: ",").compactMap { Double($0) }
                    if n.count == 4 { options.initialSelection = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) }
                }
                let result = await SelectionOverlay(options: options).run()
                Log.note("ui-test overlay result: \(result)")
                print("ui-test overlay result: \(result)")
            case "settings":
                state.openSettings()
            case "editor":
                guard let path = rest.first else { return }
                state.openEditor(file: URL(fileURLWithPath: path))
                if rest.contains("--demo"), let model = state.lastEditorModel {
                    let demo = EditorDemo.document(imageSize: model.document.imageSize, scale: model.document.scale)
                    model.mutate("Demo") { $0.annotations = demo.annotations }
                    model.tool = .select
                    model.selection = demo.annotations.first(where: { $0.tool == .arrow })?.id
                }
            default:
                Log.note("unknown ui-test \(what)")
            }
        }
    }
}

extension CLI {
    /// An image and its size in points, from its DPI (144 dpi = Retina).
    static func loadImage(_ path: String) -> (CGImage, CGSize)? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let scale = max(1, ((props?[kCGImagePropertyDPIWidth] as? Double ?? 72) / 72).rounded())
        return (image, CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }
}

/// One of every annotation, laid out relative to the image size, for render checks.
enum EditorDemo {
    static func document(imageSize: CGSize, scale: CGFloat) -> AnnotationDocument {
        var doc = AnnotationDocument(imageSize: imageSize, scale: scale)
        let w = imageSize.width, h = imageSize.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: w * x, y: h * y) }
        var style = AnnotationStyle()
        func add(_ tool: EditorTool, _ a: CGPoint, _ b: CGPoint, _ edit: (inout Annotation) -> Void = { _ in }) {
            var annotation = Annotation(tool: tool, start: a, end: b, style: style)
            edit(&annotation)
            doc.annotations.append(annotation)
        }
        add(.rectangle, p(0.05, 0.08), p(0.3, 0.3))
        style.color = .blue
        add(.ellipse, p(0.35, 0.08), p(0.55, 0.3))
        style.color = .yellow
        add(.filledRectangle, p(0.6, 0.08), p(0.75, 0.18))
        style.color = .red
        add(.arrow, p(0.1, 0.6), p(0.3, 0.4))
        style.arrowStyle = .tapered
        style.color = .green
        add(.arrow, p(0.35, 0.6), p(0.5, 0.42))
        style.color = .purple
        add(.line, p(0.55, 0.6), p(0.7, 0.45))
        add(.pixelate, p(0.75, 0.25), p(0.95, 0.45))
        add(.blur, p(0.75, 0.5), p(0.95, 0.7))
        style.color = .red
        add(.text, p(0.05, 0.7), p(0.05, 0.7)) { $0.text = "Filled text" }
        style.textStyle = .outlined
        add(.text, p(0.05, 0.82), p(0.05, 0.82)) { $0.text = "Outlined text" }
        style.textStyle = .plain
        style.color = .blue
        add(.text, p(0.35, 0.82), p(0.35, 0.82)) { $0.text = "Plain text" }
        style.color = .orange
        for (i, x) in [0.4, 0.47, 0.54].enumerated() {
            add(.counter, p(CGFloat(x), 0.72), p(CGFloat(x), 0.72)) { $0.number = i + 1 }
        }
        style.color = .yellow
        add(.highlighter, .zero, .zero) { $0.points = stride(from: 0.6, through: 0.9, by: 0.02).map { p(CGFloat($0), 0.8 + 0.01 * sin(CGFloat($0) * 30)) } }
        style.color = .red
        add(.pencil, .zero, .zero) { $0.points = stride(from: 0.0, through: 6.28, by: 0.2).map { p(0.85 + 0.05 * cos(CGFloat($0)), 0.9 + 0.04 * sin(CGFloat($0))) } }
        add(.spotlight, p(0.6, 0.72), p(0.98, 0.98))
        return doc
    }
}

enum ShareCLI {
    static func share(path: String, kind: ProviderKind, title: String?, deleteAfter: Bool) async {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), let bytes = attributes[.size] as? Int else {
            CLI.fail("can't read \(url.path)")
        }
        let ext = url.pathExtension.lowercased()
        let mime = ext == "jpg" || ext == "jpeg" ? "image/jpeg" : ext == "gif" ? "image/gif" : ext == "mp4" ? "video/mp4" : "image/png"
        let pixels = CLI.loadImage(url.path).map { CGSize(width: $0.0.width, height: $0.0.height) }
        let file = ShareFile(url: url, filename: url.lastPathComponent, mimeType: mime, byteCount: bytes, pixelSize: pixels,
                             title: title ?? url.deletingPathExtension().lastPathComponent)
        let provider = ShareProviders.make(kind)
        do {
            let result = try await provider.upload(file) { fraction in
                FileHandle.standardError.write("  sent \(Int(fraction * 100))%\n".data(using: .utf8)!)
            }
            print(result.url.absoluteString)
            if let direct = result.directURL, direct != result.url { print("direct: \(direct.absoluteString)") }
            if deleteAfter {
                try await provider.delete(result.receipt)
                print("deleted")
            }
        } catch {
            CLI.fail("share failed: \(error.localizedDescription)")
        }
    }
}
