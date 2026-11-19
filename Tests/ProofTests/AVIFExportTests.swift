import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import Proof

final class AVIFExportTests: XCTestCase {
    func testAVIFPreferenceRoundTripsWhenWritable() throws {
        var prefs = Preferences()
        prefs.format = .avif
        prefs.jpegQuality = 0.7
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        let supported = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains("public.avif")
        XCTAssertEqual(restored.format, supported ? .avif : .png)
        let options = ImageExporter.Options(restored)
        XCTAssertEqual(options.format.fileExtension, supported ? "avif" : "png")
        XCTAssertEqual(options.jpegQuality, 0.7)
    }

    func testAVIFSaveAsWritesRealAVIFWithOddDimensionsAndAlpha() throws {
        let supported = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains("public.avif")
        XCTAssertEqual(ImageExporter.saveContentTypes.contains { $0.identifier == "public.avif" }, supported)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("export.AVIF")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 83, height: 91, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: 83, height: 91))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 91))
        let image = try XCTUnwrap(context.makeImage())
        let size = CGSize(width: 41.5, height: 45.5)
        // PNG is still the default; the extension must select AVIF.
        let options = ImageExporter.Options()
        if !supported {
            XCTAssertThrowsError(try ImageExporter.write(image, pointSize: size, to: url, options: options))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            return
        }

        try ImageExporter.write(image, pointSize: size, to: url, options: options)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.avif")
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 83)
        XCTAssertEqual(decoded.height, 91)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 83, height: 91, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(decoded, in: CGRect(x: 0, y: 0, width: 83, height: 91))
        let pixels = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(pixels[45 * bitmap.bytesPerRow + 10 * 4 + 3], 255)
        XCTAssertEqual(pixels[45 * bitmap.bytesPerRow + 70 * 4 + 3], 0)
    }
}
