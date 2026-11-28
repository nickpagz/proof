import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import Proof

final class WebPExportTests: XCTestCase {
    func testWebPExportPreservesOddDimensionsAndLosslessRGBA() throws {
        let size = CGSize(width: 83, height: 91)
        let context = try bitmap(width: 83, height: 91)
        context.clear(CGRect(origin: .zero, size: size))
        context.setBlendMode(.copy)
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 1, y: 5, width: 30, height: 36))
        context.setFillColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 0.5)
        context.fill(CGRect(x: 44, y: 35, width: 34, height: 52))
        let image = try XCTUnwrap(context.makeImage())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("screenshot.WEBP")
        try ImageExporter.write(image, pointSize: size, to: url, options: ImageExporter.Options(), filenameFormats: .editor)
        let result = try decode(Data(contentsOf: url))
        XCTAssertEqual(result.width, 83)
        XCTAssertEqual(result.height, 91)
        let decoded = try bitmap(width: 83, height: 91)
        decoded.setBlendMode(.copy)
        decoded.draw(result, in: CGRect(origin: .zero, size: size))
        let originalBytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let decodedBytes = try XCTUnwrap(decoded.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Data(bytes: originalBytes, count: 91 * context.bytesPerRow),
                       Data(bytes: decodedBytes, count: 91 * decoded.bytesPerRow))
    }

    func testWebPPreferenceRespectsScaleTo1x() throws {
        var prefs = Preferences()
        prefs.format = .webp
        prefs.scaleRetinaTo1x = true
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        let options = ImageExporter.Options(restored)
        XCTAssertEqual(options.format.fileExtension, "webp")
        let image = try XCTUnwrap(bitmap(width: 200, height: 100).makeImage())
        let result = try decode(ImageExporter.data(for: image, pointSize: CGSize(width: 100, height: 50), options: options))
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 50)
    }

    func testJPEGExtensionOverridesWebPPreference() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try XCTUnwrap(bitmap(width: 32, height: 32).makeImage())
        var options = ImageExporter.Options()
        options.format = .webp
        for suffix in ["jpg", "JPEG", "jpe"] {
            let url = directory.appendingPathComponent("screenshot.\(suffix)")
            try ImageExporter.write(image, pointSize: CGSize(width: 32, height: 32), to: url, options: options,
                                    filenameFormats: .editor)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg", suffix)
        }
    }

    func testClassicWriterKeepsLegacySuffixRules() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try XCTUnwrap(bitmap(width: 32, height: 32).makeImage())
        for (suffix, expectedType) in [("jpeg", "public.png"), ("JPE", "public.png"), ("webp", "public.png"), ("jpg", "public.jpeg")] {
            let url = directory.appendingPathComponent("screenshot.\(suffix)")
            try ImageExporter.write(image, pointSize: CGSize(width: 32, height: 32), to: url, options: ImageExporter.Options())
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, expectedType, suffix)
        }
    }

    func testWebPEmbedsTheSelectedRGBProfile() throws {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try bitmap(width: 4, height: 4, colorSpace: p3)
        context.setFillColor(red: 1, green: 0.25, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try XCTUnwrap(context.makeImage())
        var options = ImageExporter.Options()
        options.format = .webp
        for (convert, expected) in [(false, p3), (true, srgb)] {
            options.convertToSRGB = convert
            let data = try ImageExporter.data(for: image, pointSize: CGSize(width: 4, height: 4), options: options)
            let profile = try XCTUnwrap(expected.copyICCData()) as Data
            XCTAssertNotNil(data.range(of: profile))
            XCTAssertEqual(try decode(data).colorSpace?.copyICCData() as Data?, profile)
        }
    }

    func testOversizedWebPReportsTheLimitAndKeepsCaptureForSaveAs() throws {
        let image = try XCTUnwrap(bitmap(width: 1, height: 16_384).makeImage())
        var prefs = Preferences()
        prefs.format = .webp
        prefs.scaleRetinaTo1x = false
        prefs.afterCapture = .quickAccess
        prefs.saveAfterCapture = true
        prefs.showQuickAccess = false
        prefs.copyAfterCapture = false
        prefs.openEditorAfterCapture = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("scroll.webp")
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try ImageExporter.write(image, pointSize: CGSize(width: 1, height: 16_384),
                                                     to: url, options: ImageExporter.Options(prefs))) {
            XCTAssertTrue($0.localizedDescription.contains("16383 pixels per side"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        for copy in [false, true] {
            prefs.copyAfterCapture = copy
            prefs.showQuickAccess = false
            XCTAssertTrue(AppState.shouldOpenAfterCapture(prefs, savedURL: nil))
            XCTAssertFalse(AppState.shouldOpenAfterCapture(prefs, savedURL: url))
            prefs.showQuickAccess = true
            XCTAssertFalse(AppState.shouldOpenAfterCapture(prefs, savedURL: nil))
        }
    }

    private func bitmap(width: Int, height: Int, colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 4 * width,
                                 space: colorSpace,
                                 bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func decode(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "org.webmproject.webp")
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
}
