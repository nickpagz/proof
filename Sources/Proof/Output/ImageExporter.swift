import AppKit
import CoreGraphics
import CProofWebP
import ImageIO
import UniformTypeIdentifiers

/// Encodes captures to files and the clipboard.
enum ImageExporter {
    struct Options {
        var format: ImageFormat = .png
        var jpegQuality: Double = 0.9
        var scaleTo1x = false
        var convertToSRGB = true

        init() {}

        init(_ prefs: Preferences) {
            format = prefs.format
            jpegQuality = prefs.jpegQuality
            scaleTo1x = prefs.scaleRetinaTo1x
            convertToSRGB = prefs.convertToSRGB
        }
    }

    enum ExportError: LocalizedError {
        case encodeFailed(String)
        var errorDescription: String? {
            switch self {
            case .encodeFailed(let why): return "Couldn't write the image: \(why)"
            }
        }
    }

    /// Applies 1x scaling and colour conversion. Pixel dimensions only change for 1x.
    static func prepare(_ image: CGImage, pointSize: CGSize, options: Options) -> CGImage {
        var result = image
        let targetWidth = Int(pointSize.width.rounded())
        if options.scaleTo1x, targetWidth > 0, targetWidth < image.width {
            result = redraw(image, width: targetWidth, height: Int(pointSize.height.rounded())) ?? image
        }
        // Drawing into an sRGB context converts the colours; copy(colorSpace:) would only relabel them.
        if options.convertToSRGB, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
           result.colorSpace?.name != CGColorSpace.sRGB,
           let converted = redraw(result, width: result.width, height: result.height, space: srgb) {
            result = converted
        }
        return result
    }

    static func data(for image: CGImage, pointSize: CGSize, options: Options) throws -> Data {
        let prepared = prepare(image, pointSize: pointSize, options: options)
        if options.format == .webp { return try webPData(for: prepared) }
        let data = NSMutableData()
        let type: UTType
        switch options.format {
        case .png: type = .png
        case .jpeg: type = .jpeg
        case .heic: type = .heic
        case .webp: type = .webP
        }
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ExportError.encodeFailed("no encoder for \(options.format.label)")
        }
        // DPI metadata makes Retina captures open at their point size in Preview and browsers.
        let dpi = 72.0 * Double(prepared.width) / max(Double(pointSize.width), 1)
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        if options.format != .png {
            properties[kCGImageDestinationLossyCompressionQuality] = options.jpegQuality
        }
        CGImageDestinationAddImage(destination, prepared, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.encodeFailed("the encoder failed")
        }
        return data as Data
    }

    private static func webPData(for image: CGImage) throws -> Data {
        let width = image.width, height = image.height
        let limit = Int(ProofWebPMaxDimension())
        guard width > 0, height > 0, width <= limit, height <= limit else {
            throw ExportError.encodeFailed("WebP supports up to \(limit) pixels per side; choose another format for larger images")
        }
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let stride = width * 4
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: stride, space: colorSpace, bitmapInfo: bitmapInfo),
              let rgba = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw ExportError.encodeFailed("couldn't allocate the WebP pixel buffer")
        }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let profile = colorSpace.copyICCData().map { $0 as Data } ?? Data()
        var output: UnsafeMutablePointer<UInt8>?
        let count = withExtendedLifetime(context) {
            profile.withUnsafeBytes {
                ProofWebPEncode(rgba, Int32(width), Int32(height), Int32(stride),
                               $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &output)
            }
        }
        guard let output else { throw ExportError.encodeFailed("the WebP encoder failed") }
        guard count > 0 else {
            ProofWebPFree(output)
            throw ExportError.encodeFailed("the WebP encoder wrote no data")
        }
        return Data(bytesNoCopy: output, count: count, deallocator: .custom { ptr, _ in ProofWebPFree(ptr) })
    }

    enum FilenameFormats {
        // CLI, agent, and sharing callers keep their original suffix rules.
        case classic
        case editor
    }

    static func write(_ image: CGImage, pointSize: CGSize, to url: URL, options: Options,
                      filenameFormats: FilenameFormats = .classic) throws {
        var options = options
        switch (url.pathExtension.lowercased(), filenameFormats) {
        case ("png", _): options.format = .png
        case ("jpg", _), ("jpeg", .editor), ("jpe", .editor): options.format = .jpeg
        case ("heic", _): options.format = .heic
        case ("webp", .editor): options.format = .webp
        default: break
        }
        let data = try data(for: image, pointSize: pointSize, options: options)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Puts the image on the clipboard, plus the file when there is one, so pasting works in
    /// image editors, chat apps and Finder alike.
    static func copyToClipboard(_ image: CGImage, pointSize: CGSize, file: URL?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let nsImage = NSImage(cgImage: image, size: pointSize)
        var objects: [NSPasteboardWriting] = []
        if let file { objects.append(file as NSURL) }
        objects.append(nsImage)
        pasteboard.writeObjects(objects)
        // PNG data as well: many apps read only public.png, not TIFF.
        var pngOptions = Options()
        pngOptions.format = .png
        if let png = try? data(for: image, pointSize: pointSize, options: pngOptions) {
            pasteboard.setData(png, forType: .png)
        }
    }

    private static func redraw(_ image: CGImage, width: Int, height: Int, space: CGColorSpace? = nil) -> CGImage? {
        let colorSpace = space ?? image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// The shutter sound macOS itself plays.
enum ShutterSound {
    private static let sound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: path, byReference: true)
    }()

    static func play() {
        sound?.stop()
        sound?.play()
    }
}
