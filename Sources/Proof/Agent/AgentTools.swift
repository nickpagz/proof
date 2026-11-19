import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// A failed tool call, with a message written for the agent.
struct AgentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// What agents can do with Proof: list windows, capture, annotate, record and share. Every
/// capture lands in the agent folder (or where the agent asks) and shows a brief notice on screen.
@MainActor
final class AgentTools {
    weak var state: AppState?
    /// Tells Settings what an agent did.
    var record: ((_ client: String, _ summary: String) -> Void)?

    private var recording: AgentRecording?
    var isRecording: Bool { recording != nil }

    /// Longest side of the image an agent sees; models scale anything larger down anyway.
    nonisolated static let previewLongestSide: CGFloat = 1568
    static let recordingLimit: Duration = .seconds(120)

    /// How far along a call is: progress (and the total, when known) and a note for the agent.
    typealias Progress = (_ progress: Double, _ total: Double?, _ message: String?) -> Void

    func run(_ request: AgentRequest, progress: @escaping Progress = { _, _, _ in }) async -> AgentResponse {
        let client = Self.displayName(request.client)
        guard let state, state.prefs.allowAgents else {
            return AgentResponse(id: request.id, ok: false, text: "Proof doesn't allow agents right now. Ask the person to turn on Settings → Agents in Proof.")
        }
        do {
            var response: AgentResponse
            let args = request.arguments
            switch request.tool {
            case "list_windows": response = listWindows()
            case "capture_window": response = try await captureWindow(args, client: client, prefs: state.prefs)
            case "capture_screen": response = try await captureScreen(args, client: client, prefs: state.prefs)
            case "capture_area": response = try await captureArea(args, client: client, prefs: state.prefs)
            case "capture_scrolling": response = try await captureScrolling(args, client: client, state: state, progress: progress)
            case "ask_for_area": response = try await askForArea(args, client: client, state: state)
            case "open_in_editor": response = try openInEditor(args, client: client, state: state)
            case "annotate": response = try annotate(args, client: client, prefs: state.prefs)
            case "start_recording": response = try await startRecording(args, client: client, state: state)
            case "stop_recording": response = try await stopRecording(args, client: client, prefs: state.prefs, progress: progress)
            case "share": response = try await share(args, client: client, state: state, progress: progress)
            default: throw AgentError("Proof has no tool called \(request.tool).")
            }
            return AgentResponse(id: request.id, ok: true, text: response.text, images: response.images)
        } catch {
            let text = Task.isCancelled || error is CancellationError ? "Cancelled before it finished." : error.localizedDescription
            Log.note("agents: \(client) \(request.tool) failed: \(text)")
            return AgentResponse(id: request.id, ok: false, text: text)
        }
    }

    /// "claude-code" → "Claude Code".
    nonisolated static func displayName(_ client: String?) -> String {
        guard let client, !client.isEmpty else { return "An agent" }
        let words = client.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").split(separator: " ")
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: Windows

    private func listWindows() -> AgentResponse {
        let windows: [JSONValue] = ScreenGrabber.pickableWindows().map { window in
            let f = window.frame
            return ["id": .number(Double(window.id)), "app": .string(window.ownerName), "title": .string(window.title),
                    "frame": [.number(f.minX), .number(f.minY), .number(f.width), .number(f.height)]]
        }
        let displays: [JSONValue] = NSScreen.screens.enumerated().map { index, screen in
            let id = ScreenGeometry.displayID(of: screen)
            let b = CGDisplayBounds(id)
            return ["index": .number(Double(index)), "name": .string(screen.localizedName),
                    "bounds": [.number(b.minX), .number(b.minY), .number(b.width), .number(b.height)],
                    "scale": .number(Double(screen.backingScaleFactor)), "main": .bool(id == CGMainDisplayID())]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(JSONValue.object(["windows": .array(windows), "displays": .array(displays)])))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return AgentResponse(id: 0, ok: true, text: "Frames are [x, y, width, height] in global points.\n\(json)")
    }

    private func window(_ args: JSONValue) throws -> PickableWindow {
        let windows = ScreenGrabber.pickableWindows()
        if let id = args["window_id"]?.int {
            guard let match = windows.first(where: { $0.id == CGWindowID(id) }) else {
                throw AgentError("No window on screen has id \(id). Call list_windows for the current ids.")
            }
            return match
        }
        guard let needle = args["window"]?.string?.lowercased(), !needle.isEmpty else {
            throw AgentError("Give window (part of an app name or title) or window_id.")
        }
        if let match = windows.first(where: { $0.ownerName.lowercased().contains(needle) || $0.title.lowercased().contains(needle) }) {
            return match
        }
        let names = windows.prefix(12).map { $0.title.isEmpty ? $0.ownerName : "\($0.ownerName) — \($0.title)" }
        throw AgentError("No window matches \"\(needle)\". On screen: \(names.joined(separator: "; ")).")
    }

    // MARK: Capturing

    private func captureWindow(_ args: JSONValue, client: String, prefs: Preferences) async throws -> AgentResponse {
        let window = try window(args)
        let (image, size) = try await ScreenGrabber.capture(windowID: window.id, shadow: args["shadow"]?.bool ?? false)
        let capture = Capture(image: image, pointSize: size, kind: .window, appName: window.ownerName, date: Date())
        let what = window.title.isEmpty ? "the \(window.ownerName) window" : "the \(window.ownerName) window “\(window.title)”"
        return try save(capture, args, prefs: prefs, client: client, what: what, notice: "captured \(window.ownerName)")
    }

    private func captureScreen(_ args: JSONValue, client: String, prefs: Preferences) async throws -> AgentResponse {
        let screens = NSScreen.screens
        let index = args["display"]?.int ?? 0
        guard screens.indices.contains(index) else { throw AgentError("There's no display \(index); there are \(screens.count).") }
        let id = ScreenGeometry.displayID(of: screens[index])
        let image = try await ScreenGrabber.capture(displayID: id, hideDesktopIcons: prefs.hideDesktopIcons)
        let capture = Capture(image: image, pointSize: CGDisplayBounds(id).size, kind: .fullscreen, appName: nil, date: Date())
        return try save(capture, args, prefs: prefs, client: client, what: "display \(index)", notice: "captured the screen")
    }

    private func captureArea(_ args: JSONValue, client: String, prefs: Preferences) async throws -> AgentResponse {
        let rect = try area(args)
        let image = try await ScreenGrabber.capture(rect: rect, hideDesktopIcons: prefs.hideDesktopIcons)
        // The capture is clipped to the display that holds the area.
        let size = ScreenGeometry.displayID(containing: rect).map { rect.intersection(CGDisplayBounds($0)).integral.size } ?? rect.size
        let capture = Capture(image: image, pointSize: size, kind: .area, appName: nil, date: Date())
        return try save(capture, args, prefs: prefs, client: client, what: "the area \(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.width)) × \(Int(rect.height))", notice: "captured part of the screen")
    }

    private func captureScrolling(_ args: JSONValue, client: String, state: AppState, progress: @escaping Progress) async throws -> AgentResponse {
        guard !state.scroller.isActive else { throw AgentError("A scrolling capture is already running. Try again once it's done.") }
        let rect: CGRect
        let appName: String?
        let what: String
        if args["window"] != nil || args["window_id"] != nil {
            let window = try window(args)
            // Scrolling capture records the screen, so the window has to be in front.
            NSRunningApplication(processIdentifier: window.ownerPID)?.activate()
            try? await Task.sleep(for: .milliseconds(400))
            rect = window.frame
            appName = window.ownerName
            what = window.title.isEmpty ? "the \(window.ownerName) window" : "the \(window.ownerName) window “\(window.title)”"
        } else {
            rect = try area(args)
            appName = nil
            what = "the area \(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.width)) × \(Int(rect.height))"
        }
        AgentNotice.show("\(client) is scrolling \(appName ?? "part of the screen")")
        record?(client, "started a scrolling capture of \(what)")
        let scroller = state.scroller
        let (capture, complete) = try await withTaskCancellationHandler {
            try await scroller.captureForAgent(rect, appName: appName, fromTop: args["from_top"]?.bool ?? true) { points in
                progress(Double(points), nil, "\(points) points captured so far")
            }
        } onCancel: {
            Task { @MainActor in await scroller.cancel() }
        }
        let response = try save(capture, args, prefs: state.prefs, client: client, what: "\(what), scrolled to the end",
                                notice: "captured a scrolling page")
        guard !complete else { return response }
        let warning = "\nWarning: Proof lost track of the page partway (it jumped, reloaded or changed while scrolling), so the image may stop short or have a seam. Check it, and try again once the page has finished loading."
        return AgentResponse(id: 0, ok: true, text: response.text + warning, images: response.images)
    }

    // MARK: Asking the person

    /// Opens the selection overlay with the agent's request on screen, and captures what the
    /// person picks: an area they drag, or a window they click.
    private func askForArea(_ args: JSONValue, client: String, state: AppState) async throws -> AgentResponse {
        guard !state.isCapturing, !state.recorder.isActive, !state.scroller.isActive else {
            throw AgentError("Proof is busy with another capture. Try again in a moment.")
        }
        let request = args["prompt"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds = min(max(args["timeout_seconds"]?.int ?? 120, 10), 600)
        var options = SelectionOverlay.Options()
        options.showMagnifier = state.prefs.showMagnifier
        options.showCrosshair = state.prefs.showCrosshair
        options.hideDesktopIcons = state.prefs.hideDesktopIcons
        options.prompt = "\(client): \(request?.isEmpty == false ? request! : "Show me what you mean")"
        let overlay = SelectionOverlay(options: options)
        record?(client, "asked the person to pick an area")
        let limit = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            overlay.finish(.cancelled)
        }
        let result = await withTaskCancellationHandler {
            await overlay.run()
        } onCancel: {
            Task { @MainActor in overlay.finish(.cancelled) }
        }
        limit.cancel()
        try Task.checkCancellation()
        // Let the overlay leave the screen before capturing what was under it.
        try? await Task.sleep(for: .milliseconds(150))
        let prefs = state.prefs
        switch result {
        case .cancelled:
            throw AgentError("The person didn't pick anything: they pressed Escape, or \(seconds) seconds passed.")
        case .window(let window):
            let (image, size) = try await ScreenGrabber.capture(windowID: window.id, shadow: false)
            let capture = Capture(image: image, pointSize: size, kind: .window, appName: window.ownerName, date: Date())
            return try save(capture, args, prefs: prefs, client: client, what: "the \(window.ownerName) window the person picked (window_id \(window.id))",
                            notice: "captured what you picked")
        case .fullscreen(let displayID):
            let image = try await ScreenGrabber.capture(displayID: displayID, hideDesktopIcons: prefs.hideDesktopIcons)
            let capture = Capture(image: image, pointSize: CGDisplayBounds(displayID).size, kind: .fullscreen, appName: nil, date: Date())
            return try save(capture, args, prefs: prefs, client: client, what: "the whole screen, which the person picked", notice: "captured what you picked")
        case .area(let rect), .selfTimer(let rect), .recordArea(let rect), .scrollArea(let rect):
            return try await saveArea(rect, args, prefs: prefs, client: client)
        case .previousArea:
            guard let rect = prefs.previousArea else { throw AgentError("The person picked their previous area, but there isn't one.") }
            return try await saveArea(rect, args, prefs: prefs, client: client)
        }
    }

    private func saveArea(_ rect: CGRect, _ args: JSONValue, prefs: Preferences, client: String) async throws -> AgentResponse {
        let image = try await ScreenGrabber.capture(rect: rect, hideDesktopIcons: prefs.hideDesktopIcons)
        let size = ScreenGeometry.displayID(containing: rect).map { rect.intersection(CGDisplayBounds($0)).integral.size } ?? rect.size
        let capture = Capture(image: image, pointSize: size, kind: .area, appName: nil, date: Date())
        let r = rect.integral
        return try save(capture, args, prefs: prefs, client: client,
                        what: "the area the person picked: x \(Int(r.minX)), y \(Int(r.minY)), \(Int(r.width)) × \(Int(r.height)) points",
                        notice: "captured what you picked")
    }

    // MARK: The editor

    /// Opens an image in Proof's editor, with the agent's annotations as objects the person can
    /// move, change or delete. Nothing is saved until they save.
    private func openInEditor(_ args: JSONValue, client: String, state: AppState) throws -> AgentResponse {
        guard let path = args["path"]?.string.map({ ($0 as NSString).expandingTildeInPath }),
              let (_, size) = CLI.loadImage(path) else { throw AgentError("Give the path of an image Proof can read.") }
        let annotations = args["annotations"].map { try? AgentAnnotations.parseItems($0, imageSize: size) } ?? nil
        if args["annotations"] != nil, annotations == nil {
            // Report the problem the same way annotate would.
            _ = try AgentAnnotations.parseItems(args["annotations"], imageSize: size)
        }
        let url = URL(fileURLWithPath: path)
        state.openEditor(file: url)
        guard let model = state.lastEditorModel, model.fileURL == url else { throw AgentError("Proof couldn't open \(url.lastPathComponent) in its editor.") }
        let added = annotations?.map(\.annotation) ?? []
        let background = args["background"]?.bool ?? false
        if !added.isEmpty || background {
            model.mutate("Agent's annotations") { document in
                document.annotations += added
                if background { document.background.enabled = true }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        AgentNotice.show("\(client) opened a screenshot for you to edit")
        record?(client, "opened \(url.lastPathComponent) in the editor")
        var text = "Opened \(url.lastPathComponent) in Proof's editor"
        text += added.isEmpty ? "." : " with \(added.count) annotation\(added.count == 1 ? "" : "s") the person can move, change or delete."
        text += " Nothing is saved until they save; that writes a new file in \(state.prefs.saveFolder.path), leaving this one as it is."
        return AgentResponse(id: 0, ok: true, text: text)
    }

    private func area(_ args: JSONValue) throws -> CGRect {
        guard let x = args["x"]?.number, let y = args["y"]?.number, let w = args["width"]?.number, let h = args["height"]?.number else {
            throw AgentError("Give x, y, width and height in global points.")
        }
        guard w >= 1, h >= 1 else { throw AgentError("The area is empty.") }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func save(_ capture: Capture, _ args: JSONValue, prefs: Preferences, client: String, what: String, notice: String) throws -> AgentResponse {
        var options = ImageExporter.Options(prefs)
        // HEIC doesn't open everywhere a screenshot gets attached.
        if options.format != .jpeg { options.format = .png }
        let name = FileNaming.name(template: prefs.fileNameTemplate, date: capture.date, appName: capture.appName, kind: capture.kind)
        let url = try destination(args, prefs: prefs, name: name, ext: options.format.fileExtension)
        try ImageExporter.write(capture.image, pointSize: capture.pointSize, to: url, options: options)
        AgentNotice.show("\(client) \(notice)")
        record?(client, "\(notice) → \(url.lastPathComponent)")
        return describe(capture.image, pointSize: capture.pointSize, savedTo: url, intro: "Captured \(what).")
    }

    /// The saved file, its size, and the image at a size the agent can take in.
    private func describe(_ image: CGImage, pointSize: CGSize, savedTo url: URL, intro: String) -> AgentResponse {
        let w = Int(pointSize.width.rounded()), h = Int(pointSize.height.rounded())
        var text = "\(intro)\nSaved: \(url.path)\nSize: \(w) × \(h) points (\(image.width) × \(image.height) pixels)."
        let (images, note) = Self.previews(image, pointSize: pointSize)
        if !note.isEmpty { text += "\n" + note }
        return AgentResponse(id: 0, ok: true, text: text, images: images)
    }

    /// Most parts a long image is cut into for the agent.
    nonisolated static let maxPreviewParts = 8

    /// What the agent sees of an image: one picture at one pixel per point, smaller if needed, or
    /// for a long scrolling capture, parts from top to bottom wide enough to read. With a note on
    /// how positions in them map back to the points annotate takes.
    nonisolated static func previews(_ image: CGImage, pointSize: CGSize) -> ([AgentResponse.Image], String) {
        let w = max(pointSize.width, 1), h = max(pointSize.height, 1)
        let whole = CGRect(x: 0, y: 0, width: w, height: h)
        let single = min(1, previewLongestSide / max(w, h))
        // Wide or square images stay whole; tall ones go in parts once one picture would be too small to read.
        if h <= w * 1.25 || single >= 0.75 {
            guard let preview = render(image, part: whole, pointSize: pointSize, scale: single, allowPNG: true) else { return ([], "") }
            let note = single >= 0.999
                ? "The image below is 1 pixel per point, so positions in it are the coordinates annotate takes."
                : "The image below is scaled to \(Int((single * 100).rounded()))% of the point size; divide positions in it by \(String(format: "%.3g", single)) for annotate."
            return ([preview], note)
        }
        var scale = min(1, previewLongestSide / w)
        var partHeight = (previewLongestSide / scale).rounded(.down)
        if (h / partHeight).rounded(.up) > CGFloat(maxPreviewParts) {
            partHeight = (h / CGFloat(maxPreviewParts)).rounded(.up)
            scale = min(scale, previewLongestSide / partHeight)
        }
        var images: [AgentResponse.Image] = []
        var tops: [Int] = []
        var top: CGFloat = 0
        while top < h {
            let part = CGRect(x: 0, y: top, width: w, height: min(partHeight, h - top))
            if let preview = render(image, part: part, pointSize: pointSize, scale: scale, allowPNG: false) {
                images.append(preview)
                tops.append(Int(top))
            }
            top += partHeight
        }
        let factor = String(format: "%.3g", scale)
        let note = """
        The image is long, so it comes below in \(images.count) parts, top to bottom, each at \(Int((scale * 100).rounded()))% of \
        the point size. The parts start at y = \(tops.map(String.init).joined(separator: ", ")) points. For annotate, a position \
        in a part is x = across ÷ \(factor), y = the part's start + down ÷ \(factor).
        """
        return (images, note)
    }

    /// `part` of the image (in points) at `scale` pixels per point, as PNG when allowed and not too
    /// heavy to pass along, otherwise JPEG.
    nonisolated private static func render(_ image: CGImage, part: CGRect, pointSize: CGSize, scale: CGFloat, allowPNG: Bool) -> AgentResponse.Image? {
        let pixelsPerPoint = CGFloat(image.width) / max(pointSize.width, 1)
        let crop = CGRect(x: part.minX * pixelsPerPoint, y: part.minY * pixelsPerPoint,
                          width: part.width * pixelsPerPoint, height: part.height * pixelsPerPoint).integral
        guard let source = part.size == pointSize ? image : image.cropping(to: crop) else { return nil }
        let width = max(1, Int((part.width * scale).rounded())), height = max(1, Int((part.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(source, in: bounds)
        guard let small = context.makeImage() else { return nil }
        if allowPNG, let png = encode(small, type: .png, quality: nil), png.count <= 3_000_000 {
            return AgentResponse.Image(data: png.base64EncodedString(), mimeType: "image/png")
        }
        // JPEG has no transparency: put the image on white first.
        context.clear(bounds)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(small, in: bounds)
        guard let flat = context.makeImage(), let jpeg = encode(flat, type: .jpeg, quality: 0.85) else { return nil }
        return AgentResponse.Image(data: jpeg.base64EncodedString(), mimeType: "image/jpeg")
    }

    nonisolated private static func encode(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let properties = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// `save_to` if given (with the extension added when missing), else a new file in the agent folder.
    private func destination(_ args: JSONValue, prefs: Preferences, name: String, ext: String) throws -> URL {
        if let path = args["save_to"]?.string, !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw AgentError("save_to needs a full path, such as /Users/you/Desktop/shot.png.") }
            var url = URL(fileURLWithPath: expanded)
            if url.pathExtension.isEmpty { url.appendPathExtension(ext) }
            return url
        }
        try FileManager.default.createDirectory(at: prefs.agentFolder, withIntermediateDirectories: true)
        return FileNaming.uniqueURL(in: prefs.agentFolder, name: name, ext: ext)
    }

    // MARK: Annotating

    private func annotate(_ args: JSONValue, client: String, prefs: Preferences) throws -> AgentResponse {
        guard let path = args["path"]?.string.map({ ($0 as NSString).expandingTildeInPath }) else { throw AgentError("Give the path of an image.") }
        guard let (image, size) = CLI.loadImage(path) else { throw AgentError("Proof can't read an image at \(path).") }
        var document = AnnotationDocument(imageSize: size, scale: CGFloat(image.width) / max(size.width, 1))
        let drawn = try AgentAnnotations.parseItems(args["annotations"], imageSize: size)
        document.annotations = drawn.map(\.annotation)
        document.background.enabled = args["background"]?.bool ?? false
        guard let rendered = AnnotationRenderer(image: image).render(document) else { throw AgentError("Drawing the annotations failed.") }
        let outputSize = AnnotationRenderer.layout(document).outputSize
        var options = ImageExporter.Options(prefs)
        options.format = URL(fileURLWithPath: path).pathExtension.lowercased() == "jpg" ? .jpeg : .png
        let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let url = try destination(args, prefs: prefs, name: "\(base) annotated", ext: options.format.fileExtension)
        try ImageExporter.write(rendered, pointSize: outputSize, to: url, options: options)
        AgentNotice.show("\(client) annotated a screenshot")
        record?(client, "annotated → \(url.lastPathComponent)")
        let response = describe(rendered, pointSize: outputSize, savedTo: url, intro: "Drew \(document.annotations.count) annotation\(document.annotations.count == 1 ? "" : "s").")
        return AgentResponse(id: 0, ok: true, text: response.text + "\n" + Self.placements(drawn, layout: AnnotationRenderer.layout(document)),
                             images: response.images)
    }

    /// Where each annotation landed in the saved image, so the agent can check its layout.
    nonisolated static func placements(_ drawn: [AgentAnnotations.Drawn], layout: RenderLayout) -> String {
        let output = CGRect(origin: .zero, size: layout.outputSize)
        let lines = drawn.map { item -> String in
            let a = item.annotation
            // Text and counters by what shows; arrows with their head; everything else by its rectangle.
            let box: CGRect
            switch a.tool {
            case .text: box = CGRect(origin: a.start, size: AnnotationRenderer.textSize(for: a))
            case .counter: box = a.badgeRect
            case .arrow: box = a.bounds
            default: box = a.rect
            }
            let r = CGRect(origin: layout.toOutput(box.origin), size: box.size).intersection(output)
            let place = r.isNull || r.isEmpty
                ? "outside the image"
                : "[\(Int(r.minX.rounded())), \(Int(r.minY.rounded())), \(Int(r.width.rounded())), \(Int(r.height.rounded()))]"
            let what = a.tool == .text ? "\(item.name) “\(a.text)”" : item.name
            return "\(item.item + 1). \(what): \(place)"
        }
        return "Where each one landed, [x, y, width, height] in the saved image's points:\n" + lines.joined(separator: "\n")
    }

    // MARK: Recording

    private func startRecording(_ args: JSONValue, client: String, state: AppState) async throws -> AgentResponse {
        guard recording == nil else { throw AgentError("A recording is already running. Call stop_recording first.") }
        guard !state.recorder.isActive else { throw AgentError("The person is recording their screen right now. Try again once they're done.") }
        let source: RecordingSource
        let what: String
        if args["window"] != nil || args["window_id"] != nil {
            let window = try window(args)
            source = .window(window)
            what = "the \(window.ownerName) window"
        } else if args["x"] != nil {
            source = .area(try area(args))
            what = "part of the screen"
        } else {
            let screens = NSScreen.screens
            let index = args["display"]?.int ?? 0
            guard screens.indices.contains(index) else { throw AgentError("There's no display \(index); there are \(screens.count).") }
            source = .display(ScreenGeometry.displayID(of: screens[index]))
            what = "the screen"
        }
        // The border goes up first: the recording leaves out Proof's windows that are on screen when it starts.
        var isFullscreen = false
        if case .display = source { isFullscreen = true }
        let border = AreaBorderPanel(around: source.frame, fullscreen: isFullscreen, activeColor: .systemRed)
        border.isActive = true
        border.orderFrontRegardless()
        let folder = AppInfo.draftsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = RecordingSession()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let config = try await RecordingConfig.make(source: source, prefs: state.prefs, systemAudio: false, microphone: false)
            try await session.prepare(config)
            try await session.beginRecording(tempURL: folder.appendingPathComponent("recording.mov"))
        } catch {
            border.orderOut(nil)
            await session.cancel()
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        let current = AgentRecording(session: session, source: source, client: client, what: what, border: border, folder: folder)
        session.onStreamStopped = { [weak self] error in
            Task { @MainActor in
                Log.note("agents: recording stream ended: \(error.localizedDescription)")
                await self?.end(current)
            }
        }
        current.limit = Task { [weak self] in
            try? await Task.sleep(for: Self.recordingLimit)
            guard !Task.isCancelled else { return }
            await self?.end(current)
        }
        recording = current
        AgentNotice.show("\(client) is recording \(what)")
        record?(client, "started recording \(what)")
        let f = source.frame
        return AgentResponse(id: 0, ok: true, text: "Recording \(what) (\(Int(f.width)) × \(Int(f.height)) points). Do the flow, then call stop_recording. It stops by itself after 2 minutes.")
    }

    /// Stops the session once, keeping what it made for stop_recording.
    private func end(_ current: AgentRecording) async {
        guard current.outcome == nil else { return }
        current.limit?.cancel()
        current.border.orderOut(nil)
        do {
            current.outcome = .success(try await current.session.stop())
        } catch {
            current.outcome = .failure(error)
        }
    }

    private func stopRecording(_ args: JSONValue, client: String, prefs: Preferences, progress: @escaping Progress) async throws -> AgentResponse {
        guard let current = recording else { throw AgentError("Nothing is recording. Call start_recording first.") }
        await end(current)
        recording = nil
        defer { try? FileManager.default.removeItem(at: current.folder) }
        guard case .success(let summary) = current.outcome else {
            if case .failure(let error) = current.outcome { throw AgentError("The recording failed: \(error.localizedDescription)") }
            throw AgentError("The recording failed.")
        }
        let format = args["format"]?.string?.lowercased() == "gif" ? VideoFormat.gif : .mp4
        // Frames for the agent to check the recording by, taken before the file moves.
        let frameCount = min(max(args["frames"]?.int ?? 6, 0), Self.maxRecordingFrames)
        let frames = await Self.frames(of: summary.url, count: frameCount)
        let name = FileNaming.name(template: prefs.fileNameTemplate, date: current.started, appName: current.source.appName, kind: current.source.kind)
        let url = try destination(args, prefs: prefs, name: name, ext: format.fileExtension)
        try? FileManager.default.removeItem(at: url)
        if format == .gif {
            // Once stopped, the recording is kept even if the call is cancelled, so the GIF runs to the end.
            try await VideoExport.gif(from: summary.url, range: nil, maxWidth: args["gif_width"]?.int ?? prefs.gifSize.maxWidth, to: url) { fraction in
                Task { @MainActor in progress(fraction, 1, "Making the GIF") }
            }
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: summary.url, to: url)
        }
        let info = await VideoExport.info(format == .gif ? summary.url : url)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        AgentNotice.show("\(client) saved a recording")
        record?(client, "recorded \(current.what) → \(url.lastPathComponent)")
        var text = "Saved: \(url.path)\nLength: \(String(format: "%.1f", summary.duration)) seconds. File size: \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))."
        if let info, format == .mp4 { text += " Video: \(Int(info.size.width)) × \(Int(info.size.height)) pixels." }
        if summary.duration >= Double(Self.recordingLimit.components.seconds) - 1 { text += "\nIt reached the 2-minute limit and stopped by itself." }
        var images: [AgentResponse.Image] = []
        if let sheet = Self.contactSheet(frames), let jpeg = Self.encode(sheet, type: .jpeg, quality: 0.85) {
            images.append(AgentResponse.Image(data: jpeg.base64EncodedString(), mimeType: "image/jpeg"))
            let times = frames.map { String(format: "%.1f", $0.time) }.joined(separator: ", ")
            text += "\nThe image below shows \(frames.count) frames, left to right and top to bottom, at \(times) seconds."
        }
        return AgentResponse(id: 0, ok: true, text: text, images: images)
    }

    nonisolated static let maxRecordingFrames = 12

    /// When to take `count` frames of a video `duration` seconds long: the middle of each of
    /// `count` equal stretches, so the first and last moments aren't wasted on a blank start.
    nonisolated static func frameTimes(duration: Double, count: Int) -> [Double] {
        guard count > 0, duration > 0 else { return [] }
        return (0..<count).map { duration * (Double($0) + 0.5) / Double(count) }
    }

    /// Frames of a video at `frameTimes`, exactly at those times, no bigger than a preview.
    nonisolated static func frames(of url: URL, count: Int) async -> [(image: CGImage, time: Double)] {
        let asset = AVURLAsset(url: url)
        guard count > 0, let duration = try? await asset.load(.duration).seconds, duration > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: previewLongestSide, height: previewLongestSide)
        var frames: [(image: CGImage, time: Double)] = []
        for time in frameTimes(duration: duration, count: count) {
            if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
                frames.append((image, time))
            }
        }
        return frames
    }

    /// Frames in two columns, each with its time in the corner, at most a preview wide.
    nonisolated static func contactSheet(_ frames: [(image: CGImage, time: Double)]) -> CGImage? {
        guard let first = frames.first?.image else { return nil }
        let columns = frames.count == 1 ? 1 : 2
        let rows = (frames.count + columns - 1) / columns
        let gap = 8
        let tileWidth = (Int(previewLongestSide) - gap * (columns + 1)) / columns
        let tileHeight = Int((CGFloat(tileWidth) * CGFloat(first.height) / CGFloat(max(first.width, 1))).rounded())
        let width = tileWidth * columns + gap * (columns + 1), height = tileHeight * rows + gap * (rows + 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        for (index, frame) in frames.enumerated() {
            let column = index % columns, row = index / columns
            // Core Graphics counts y from the bottom; the first row goes at the top.
            let tile = CGRect(x: gap + column * (tileWidth + gap), y: height - (row + 1) * (tileHeight + gap),
                              width: tileWidth, height: tileHeight)
            context.draw(frame.image, in: tile)
            let label = NSAttributedString(string: String(format: " %.1f s ", frame.time), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.7),
            ])
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            label.draw(at: CGPoint(x: tile.minX + 6, y: tile.maxY - label.size().height - 6))
            NSGraphicsContext.restoreGraphicsState()
        }
        return context.makeImage()
    }

    /// Agents were switched off: drop any recording in progress.
    func stopEverything() {
        guard let current = recording else { return }
        recording = nil
        current.limit?.cancel()
        current.border.orderOut(nil)
        Task {
            await current.session.cancel()
            try? FileManager.default.removeItem(at: current.folder)
        }
    }

    // MARK: Sharing

    private func share(_ args: JSONValue, client: String, state: AppState, progress: @escaping Progress) async throws -> AgentResponse {
        guard let path = args["path"]?.string.map({ ($0 as NSString).expandingTildeInPath }), FileManager.default.fileExists(atPath: path) else {
            throw AgentError("Give the path of a file that exists.")
        }
        let visibility: ShareVisibility = args["visibility"]?.string?.lowercased() == "public" ? .public : .private
        let (result, service) = try await state.sharing.upload(file: URL(fileURLWithPath: path), visibility: visibility) { fraction in
            Task { @MainActor in progress(fraction, 1, "Uploading") }
        }
        AgentNotice.show("\(client) shared a file to \(service)")
        record?(client, "shared \(URL(fileURLWithPath: path).lastPathComponent) → \(result.url.absoluteString)")
        var text = "Shared to \(service): \(result.url.absoluteString)"
        if let direct = result.directURL, direct != result.url { text += "\nDirect link to the file: \(direct.absoluteString)" }
        return AgentResponse(id: 0, ok: true, text: text)
    }
}

/// A recording an agent started.
@MainActor
private final class AgentRecording {
    let session: RecordingSession
    let source: RecordingSource
    let client: String
    let what: String
    let border: AreaBorderPanel
    let folder: URL
    let started = Date()
    var limit: Task<Void, Never>?
    var outcome: Result<RecordingSession.Summary, Error>?

    init(session: RecordingSession, source: RecordingSource, client: String, what: String, border: AreaBorderPanel, folder: URL) {
        self.session = session
        self.source = source
        self.client = client
        self.what = what
        self.border = border
        self.folder = folder
    }
}

/// Turns an agent's annotation list into editor annotations.
enum AgentAnnotations {
    /// One drawn annotation, and which of the agent's items it came from: an arrow with a label
    /// becomes two.
    struct Drawn {
        let item: Int
        let name: String
        let annotation: Annotation
    }

    static func parse(_ value: JSONValue?, imageSize: CGSize? = nil) throws -> [Annotation] {
        try parseItems(value, imageSize: imageSize).map(\.annotation)
    }

    static func parseItems(_ value: JSONValue?, imageSize: CGSize? = nil) throws -> [Drawn] {
        guard let items = value?.array, !items.isEmpty else { throw AgentError("annotations needs at least one annotation.") }
        var nextNumber = 1
        return try items.enumerated().flatMap { index, item -> [Drawn] in
            let type = item["type"]?.string?.lowercased() ?? ""
            let annotation = try parseOne(index, item, nextNumber: &nextNumber)
            var drawn = [Drawn(item: index, name: type, annotation: annotation)]
            if type == "arrow" || type == "line", let label = item["label"]?.string, !label.isEmpty {
                var text = Annotation(tool: .text, start: .zero, end: .zero, style: annotation.style)
                text.text = label
                text.start = labelOrigin(size: AnnotationRenderer.textSize(for: text), tail: annotation.start,
                                         head: annotation.end, imageSize: imageSize)
                text.end = text.start
                drawn.append(Drawn(item: index, name: "\(type) label", annotation: text))
            }
            return drawn
        }
    }

    /// Where a label of `size` goes so it sits just past the arrow's tail, on the side away from the
    /// head, and inside the image when its size is known.
    static func labelOrigin(size: CGSize, tail: CGPoint, head: CGPoint, imageSize: CGSize?) -> CGPoint {
        let dx = tail.x - head.x, dy = tail.y - head.y
        let length = max(hypot(dx, dy), 0.001)
        // Pointing away from the head: from the tail to the label's centre.
        let ux = dx / length, uy = dy / length
        let gap: CGFloat = 6
        // The arrow's line, carried on past the tail, enters the box `gap` points out: the centre
        // sits that far plus the distance from the centre to the box's edge along the line.
        let toEdge = min(abs(ux) > 0.001 ? size.width / 2 / abs(ux) : .infinity,
                         abs(uy) > 0.001 ? size.height / 2 / abs(uy) : .infinity)
        let reach = gap + toEdge
        var origin = CGPoint(x: tail.x + ux * reach - size.width / 2, y: tail.y + uy * reach - size.height / 2)
        if let imageSize {
            origin.x = min(max(origin.x, 0), max(imageSize.width - size.width, 0))
            origin.y = min(max(origin.y, 0), max(imageSize.height - size.height, 0))
        }
        return origin
    }

    private static func parseOne(_ index: Int, _ item: JSONValue, nextNumber: inout Int) throws -> Annotation {
        guard let type = item["type"]?.string?.lowercased() else { throw AgentError("Annotation \(index + 1) has no type.") }
        var style = AnnotationStyle()
        if let color = item["color"]?.string {
            guard let parsed = Self.color(color) else { throw AgentError("Annotation \(index + 1): unknown color \(color).") }
            style.color = parsed
        }
        if let width = item["line_width"]?.number { style.lineWidth = CGFloat(min(max(width, 1), 40)) }
        if let size = item["font_size"]?.number { style.fontSize = CGFloat(min(max(size, 8), 200)) }
        if let raw = item["text_style"]?.string {
            guard let textStyle = TextStyle(rawValue: raw.lowercased()) else { throw AgentError("Annotation \(index + 1): text_style is filled, outlined or plain.") }
            style.textStyle = textStyle
        }
        func point(_ key: String) throws -> CGPoint {
            guard let values = item[key]?.array?.compactMap(\.number), values.count == 2 else {
                throw AgentError("Annotation \(index + 1) (\(type)) needs \(key): [x, y].")
            }
            return CGPoint(x: values[0], y: values[1])
        }
        func rect() throws -> (CGPoint, CGPoint) {
            guard let values = item["rect"]?.array?.compactMap(\.number), values.count == 4 else {
                throw AgentError("Annotation \(index + 1) (\(type)) needs rect: [x, y, width, height].")
            }
            return (CGPoint(x: values[0], y: values[1]), CGPoint(x: values[0] + values[2], y: values[1] + values[3]))
        }
        switch type {
        case "rectangle", "filled_rectangle", "ellipse", "blur", "pixelate", "spotlight":
            let tool: EditorTool = ["rectangle": .rectangle, "filled_rectangle": .filledRectangle, "ellipse": .ellipse,
                                    "blur": .blur, "pixelate": .pixelate, "spotlight": .spotlight][type]!
            let (start, end) = try rect()
            return Annotation(tool: tool, start: start, end: end, style: style)
        case "arrow", "line":
            return Annotation(tool: type == "arrow" ? .arrow : .line, start: try point("from"), end: try point("to"), style: style)
        case "text":
            guard let text = item["text"]?.string, !text.isEmpty else { throw AgentError("Annotation \(index + 1) (text) needs text.") }
            let at = try point("at")
            var annotation = Annotation(tool: .text, start: at, end: at, style: style)
            annotation.text = text
            return annotation
        case "counter":
            let at = try point("at")
            var annotation = Annotation(tool: .counter, start: at, end: at, style: style)
            annotation.number = item["number"]?.int ?? nextNumber
            nextNumber = annotation.number + 1
            return annotation
        default:
            throw AgentError("Annotation \(index + 1): unknown type \(type). Use rectangle, filled_rectangle, ellipse, arrow, line, text, counter, blur, pixelate or spotlight.")
        }
    }

    static func color(_ name: String) -> RGBA? {
        let named: [String: RGBA] = ["red": .red, "orange": .orange, "yellow": .yellow, "green": .green,
                                     "blue": .blue, "purple": .purple, "black": .black, "white": .white]
        if let color = named[name.lowercased()] { return color }
        var hex = name.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return RGBA(r: Double((value >> 16) & 0xFF) / 255, g: Double((value >> 8) & 0xFF) / 255, b: Double(value & 0xFF) / 255)
    }
}
