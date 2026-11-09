import AppKit
import Carbon.HIToolbox
import Foundation
import ImageIO
import SwiftUI

/// `Proof --self-test`: checks for the pieces that don't need the screen. Prints one line per
/// check and returns false if any failed.
enum SelfTest {
    private static var failures = 0

    static func run() -> Bool {
        failures = 0
        fileNames()
        geometry()
        shortcuts()
        encoding()
        preferences()
        editor()
        print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
        return failures == 0
    }

    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("ok   \(name)")
        } else {
            failures += 1
            print("FAIL \(name) \(detail())")
        }
    }

    private static func fileNames() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 3; parts.day = 7; parts.hour = 9; parts.minute = 5; parts.second = 4
        let date = Calendar.current.date(from: parts)!
        let name = FileNaming.name(template: FileNaming.defaultTemplate, date: date, appName: "Safari", kind: .area)
        check("default file name", name == "Proof 2026-03-07 at 09.05.04", name)
        let custom = FileNaming.name(template: "{app}/{kind} {n}", date: date, appName: "Mail: Inbox", kind: .window, counter: { 42 })
        check("tokens and sanitising", custom == "Mail- Inbox-window 42", custom)
        check("empty template falls back", FileNaming.name(template: "  ", date: date, appName: nil, kind: .area).hasPrefix("Proof "))
        let random = FileNaming.random()
        check("random share names", random.count == 12 && random.allSatisfy { $0.isLowercase || $0.isNumber }
              && random != FileNaming.random(), random)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("proof-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = FileNaming.uniqueURL(in: folder, name: "Shot", ext: "png")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = FileNaming.uniqueURL(in: folder, name: "Shot", ext: "png")
        check("unique names", first.lastPathComponent == "Shot.png" && second.lastPathComponent == "Shot 2.png", second.lastPathComponent)
    }

    private static func geometry() {
        let h = ScreenGeometry.mainDisplayHeight
        let global = CGRect(x: 10, y: 20, width: 300, height: 200)
        let cocoa = ScreenGeometry.cocoaRect(fromGlobal: global)
        check("global → cocoa", cocoa == NSRect(x: 10, y: h - 220, width: 300, height: 200), "\(cocoa)")
        check("cocoa → global round trip", ScreenGeometry.globalRect(fromCocoa: cocoa) == global)
        check("main display found", ScreenGeometry.displayID(containing: CGRect(x: 1, y: 1, width: 10, height: 10)) != nil)
    }

    private static func shortcuts() {
        let area = HotKeyAction.captureArea.defaultShortcut
        check("default area shortcut", area?.displayString == "⇧⌘4", area?.displayString ?? "nil")
        check("menu key equivalent", area?.menuKeyEquivalent?.0 == "4")
        var prefs = Preferences()
        prefs.shortcuts[HotKeyAction.captureArea.rawValue] = .some(nil)
        check("cleared shortcut stays cleared", prefs.shortcut(for: .captureArea) == nil)
        let custom = Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | optionKey))
        prefs.shortcuts[HotKeyAction.captureWindow.rawValue] = custom
        check("custom shortcut", prefs.shortcut(for: .captureWindow)?.displayString == "⌃⌥A")
    }

    private static func encoding() {
        // A 200x100 px image standing in for a 100x50 pt Retina capture, in Display P3.
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = context.makeImage()!
        let size = CGSize(width: 100, height: 50)

        for format in ImageFormat.allCases {
            var options = ImageExporter.Options()
            options.format = format
            guard let data = try? ImageExporter.data(for: image, pointSize: size, options: options),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                check("encode \(format.label)", false, "no data")
                continue
            }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let dpi = props?[kCGImagePropertyDPIWidth] as? Double ?? 0
            check("encode \(format.label) keeps pixels and Retina DPI", decoded.width == 200 && Int(dpi.rounded()) == 144, "\(decoded.width) px, \(dpi) dpi")
            check("encode \(format.label) converts to sRGB", decoded.colorSpace?.name == CGColorSpace.sRGB, "\(String(describing: decoded.colorSpace?.name))")
        }
        var oneX = ImageExporter.Options()
        oneX.scaleTo1x = true
        let scaled = ImageExporter.prepare(image, pointSize: size, options: oneX)
        check("1x scaling", scaled.width == 100 && scaled.height == 50, "\(scaled.width)x\(scaled.height)")

        let snapshotCrop = AppState.crop(image, displayID: CGMainDisplayID(), to: CGRect(x: 0, y: 0, width: 10, height: 10))
        check("freeze crop", snapshotCrop != nil)
    }

    private static func editor() {
        let size = CGSize(width: 400, height: 300)
        var doc = AnnotationDocument(imageSize: size, scale: 2)
        check("layout without background", AnnotationRenderer.layout(doc).outputSize == size)
        doc.background.enabled = true
        doc.background.padding = 50
        check("background padding", AnnotationRenderer.layout(doc).outputSize == CGSize(width: 500, height: 400))
        doc.background.aspect = .sixteenNine
        let wide = AnnotationRenderer.layout(doc).outputSize
        check("background aspect 16:9", abs(wide.width / wide.height - 16.0 / 9.0) < 0.01, "\(wide)")
        doc.background = BackgroundSettings()
        doc.crop = CGRect(x: 100, y: 50, width: 200, height: 100)
        let cropped = AnnotationRenderer.layout(doc)
        check("crop sets output size", cropped.outputSize == CGSize(width: 200, height: 100))
        let point = CGPoint(x: 150, y: 80)
        check("crop coordinates round trip", cropped.toImage(cropped.toOutput(point)) == point && cropped.toOutput(point) == CGPoint(x: 50, y: 30))

        let rect = Annotation(tool: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 110, y: 60), style: AnnotationStyle())
        check("rectangle hit on edge", rect.hitTest(CGPoint(x: 10, y: 35), tolerance: 4))
        check("rectangle miss inside", !rect.hitTest(CGPoint(x: 60, y: 35), tolerance: 4))
        let arrow = Annotation(tool: .arrow, start: .zero, end: CGPoint(x: 100, y: 100), style: AnnotationStyle())
        check("arrow hit along shaft", arrow.hitTest(CGPoint(x: 50, y: 51), tolerance: 4))
        check("arrow path", !AnnotationRenderer.arrowPath(from: .zero, to: CGPoint(x: 100, y: 0), width: 4, style: .tapered).isEmpty)

        // A blank 800x600 px image, rendered with every annotation.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        let image = context.makeImage()!
        var demo = EditorDemo.document(imageSize: size, scale: 2)
        let renderer = AnnotationRenderer(image: image)
        let plain = renderer.render(demo)
        check("render keeps pixel size", plain?.width == 800 && plain?.height == 600, "\(plain?.width ?? 0)")
        demo.background.enabled = true
        let framed = renderer.render(demo)
        check("render with background", framed?.width == 800 + 96 * 2, "\(framed?.width ?? 0)")

        MainActor.assumeIsolated {
            EditorModel.persistsStyle = false
            let model = EditorModel(image: image, pointSize: size, fileURL: nil, title: "Test")
            // In the app each change is its own event; here they need explicit undo groups.
            let undo = model.undoManager
            undo.groupsByEvent = false
            func step(_ body: () -> Void) { undo.beginUndoGrouping(); body(); undo.endUndoGrouping() }
            let a = Annotation(tool: .ellipse, start: .zero, end: CGPoint(x: 40, y: 40), style: AnnotationStyle())
            step { model.mutate("Add") { $0.annotations.append(a) } }
            model.selection = a.id
            step { model.style.color = .blue }
            check("style edit restyles selection", model.annotation(a.id)?.style.color == .blue)
            model.undoManager.undo()
            check("undo style", model.annotation(a.id)?.style.color == AnnotationStyle().color)
            model.undoManager.undo()
            check("undo add", model.document.annotations.isEmpty)
            model.undoManager.redo()
            check("redo add", model.document.annotations.count == 1)
            model.tool = .crop
            model.pendingCrop = CGRect(x: 0, y: 0, width: 200, height: 150)
            step { model.applyCrop() }
            check("apply crop", model.document.crop == CGRect(x: 0, y: 0, width: 200, height: 150) && model.tool == .select)
            check("counter numbering", model.document.nextCounterNumber == 1)
            check("unsaved capture needs Save as…", model.needsSaveAs && model.hasUnhandledChanges)
            model.markHandled()
            check("copied capture closes quietly", !model.hasUnhandledChanges)
            step { model.mutate("Add") { $0.annotations.append(Annotation(tool: .line, start: .zero, end: CGPoint(x: 9, y: 9), style: AnnotationStyle())) } }
            check("new edits need handling again", model.hasUnhandledChanges)
            let toolbar = NSHostingView(rootView: EditorToolbar(model: model)).fittingSize.width
            check("toolbar width is sane (\(Int(toolbar)) pt)", toolbar > 500 && toolbar < 1400)
            let small = EditorWindowController(model: EditorModel(image: image, pointSize: CGSize(width: 120, height: 80), fileURL: nil, title: "Small"))
            let windowWidth = small.window?.frame.width ?? 0
            check("small capture window fits the toolbar (\(Int(windowWidth)) pt)", windowWidth >= toolbar)
        }
    }

    private static func sharing() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("proof-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let payload = folder.appendingPathComponent("a.png")
        try? Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 3]).write(to: payload)
        var form = MultipartForm()
        form.add("key", "abc")
        form.addFile("file", filename: "a \"b\".png", mimeType: "image/png", url: payload)
        let body = (try? form.write()).flatMap { try? Data(contentsOf: $0) } ?? Data()
        let text = String(decoding: body, as: UTF8.self)
        check("multipart has fields, file and closing boundary",
              text.contains("name=\"key\"\r\n\r\nabc\r\n") && text.contains("filename=\"a 'b'.png\"") && text.hasSuffix("--\(form.boundary)--\r\n"))
        check("multipart keeps file bytes", body.range(of: Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 3])) != nil)

        let record = ShareRecord(date: Date(timeIntervalSince1970: 1_800_000_000), title: "Shot", visibility: .private,
                                 result: ShareResult(url: URL(string: "https://cloudup.com/i1")!, directURL: nil,
                                                     receipt: ShareReceipt(kind: .cloudup, identifiers: ["stream": "c1"])))
        MainActor.assumeIsolated {
            let historyURL = folder.appendingPathComponent("shares.json")
            ShareHistory(fileURL: historyURL).add(record)
            let reloaded = ShareHistory(fileURL: historyURL).records
            check("share history round trip", reloaded == [record])
        }
        let big = ShareFile(url: payload, filename: "a.png", mimeType: "image/png", byteCount: 300 * 1024 * 1024, pixelSize: nil, title: "a")
        check("CloudUp's http S3 address becomes https", CloudUpProvider.secure("http://cldup.s3.amazonaws.com/")?.absoluteString == "https://cldup.s3.amazonaws.com/")
        check("test servers keep http", CloudUpProvider.secure("http://127.0.0.1:8765/s3")?.scheme == "http")
        check("CloudUp refuses files over its limit", (try? CloudUpProvider(account: CloudUpAccount(username: "x", displayName: "x")).checkSize(big)) == nil)
    }

    private static func preferences() {
        var prefs = Preferences()
        prefs.format = .jpeg
        prefs.previousArea = CGRect(x: 1, y: 2, width: 3, height: 4)
        prefs.shortcuts[HotKeyAction.selfTimer.rawValue] = Shortcut(keyCode: 1, modifiers: UInt32(cmdKey))
        let data = try? JSONEncoder().encode(prefs)
        let decoded = data.flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) }
        check("preferences round trip", decoded == prefs)
        let old = try? JSONDecoder().decode(Preferences.self, from: Data(#"{"format":"heic"}"#.utf8))
        check("older preferences still load", old?.format == .heic && old?.saveAfterCapture == true)
        check("captures open the editor by default", old?.afterCapture == .editor && old?.capturesOpenEditor == true)
        check("share defaults: CloudUp private, WordPress.com public", old?.destination(for: .private) == .cloudup && old?.destination(for: .public) == .wordpress)
        var none = Preferences()
        none.publicDestination = .none
        let reloaded = (try? JSONEncoder().encode(none)).flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) }
        check("a cleared share button stays cleared", reloaded?.destination(for: .public) == nil)
        sharing()
    }
}
