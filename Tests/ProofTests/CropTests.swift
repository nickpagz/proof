import AppKit
import ImageIO
import XCTest
@testable import Proof

final class CropTests: XCTestCase {
    @MainActor
    func testCropBorderFindsEdgesBetweenHandlesAndVisibleCornerGrips() {
        let crop = CGRect(x: 0, y: 0, width: 500, height: 300)
        func handle(_ x: CGFloat, _ y: CGFloat) -> CanvasView.Handle? {
            CanvasView.cropHandle(at: CGPoint(x: x, y: y), in: crop, tolerance: 10)
        }
        XCTAssertEqual(handle(495, 295), .bottomRight)
        XCTAssertEqual(handle(5, 5), .topLeft)
        XCTAssertEqual(handle(120, 5), .top)
        XCTAssertEqual(handle(360, 297), .bottom)
        XCTAssertEqual(handle(3, 70), .left)
        XCTAssertEqual(handle(495, 180), .right)
        XCTAssertNil(handle(95, 75))
        XCTAssertNil(handle(515, 75))
    }

    func testPresetsFitAndPreserveRatioAtImageEdges() {
        let bounds = CGSize(width: 500, height: 300)
        for format in [CropFormat.wide, .standard, .square, .portrait] {
            let ratio = format.ratio!
            let fitted = CropGeometry.fit(ratio, inside: CGRect(origin: .zero, size: bounds))
            XCTAssertEqual(fitted.width / fitted.height, ratio, accuracy: 0.00001)
            let corner = CropGeometry.lockedDrag(from: CGPoint(x: 40, y: 10), to: CGPoint(x: 500, y: 300),
                                                 dx: 1, dy: 1, ratio: ratio, in: bounds)
            XCTAssertEqual(corner.width / corner.height, ratio, accuracy: 0.00001)
            XCTAssertEqual(corner.origin, CGPoint(x: 40, y: 10))
            XCTAssertLessThanOrEqual(corner.maxX, 500.00001)
            XCTAssertLessThanOrEqual(corner.maxY, 300.00001)
            let edge = CropGeometry.lockedDrag(from: CGPoint(x: 250, y: 250), to: CGPoint(x: 250, y: 0),
                                               dx: 0, dy: -1, ratio: ratio, in: bounds)
            XCTAssertEqual(edge.width / edge.height, ratio, accuracy: 0.00001)
            XCTAssertEqual(edge.midX, 250, accuracy: 0.00001)
            XCTAssertEqual(edge.maxY, 250, accuracy: 0.00001)
        }
    }

    @MainActor
    func testCustomCropSavesExactPixelsWithRetinaDownscalingEnabled() throws {
        let model = try makeEditor()
        model.tool = .crop
        model.selectCropFormat(.custom)
        model.cropWidth = "833"
        model.cropHeight = "901"
        model.moveCrop(to: CGPoint(x: 999, y: -10))
        let rect = try XCTUnwrap(model.pendingCrop)
        XCTAssertEqual(rect, CGRect(x: 183.5, y: 0, width: 416.5, height: 450.5))
        model.applyCrop()
        XCTAssertEqual(model.document.exactCropSize, CropPixelSize(width: 833, height: 901))
        let image = try XCTUnwrap(model.renderedImage())
        var prefs = Preferences()
        prefs.scaleRetinaTo1x = true
        XCTAssertTrue(ImageExporter.Options(prefs).scaleTo1x)
        let options = ImageExporter.Options(prefs, preservePixelSize: model.document.exactCropSize != nil)
        let data = try ImageExporter.data(for: image, pointSize: model.outputPointSize, options: options)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let saved = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(saved.width, 833)
        XCTAssertEqual(saved.height, 901)
        model.undoManager.undo()
        XCTAssertNil(model.document.exactCropSize)
        model.undoManager.redo()
        model.tool = .crop
        XCTAssertEqual(model.cropFormat, .custom)
        XCTAssertEqual(model.pendingCrop, rect)
    }

    @MainActor
    func testCustomCropRejectsInvalidSizeAndConflictingBackground() throws {
        let model = try makeEditor()
        model.setBackground { $0.enabled = true }
        model.tool = .crop
        model.selectCropFormat(.custom)
        XCTAssertFalse(model.canApplyCrop)
        model.applyCrop()
        XCTAssertTrue(model.document.background.enabled)
        XCTAssertNil(model.document.crop)
        model.setBackground { $0.enabled = false }
        for invalid in ["1201", "0", "3.5", "", "9999999999999999999999999999999"] {
            model.cropWidth = invalid
            XCTAssertFalse(model.canApplyCrop, invalid)
        }
        model.cropWidth = "834"
        model.cropHeight = "900"
        XCTAssertTrue(model.canApplyCrop)
        model.applyCrop()
        model.setBackground { $0.enabled = true }
        XCTAssertFalse(model.document.background.enabled)
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    private func makeEditor() throws -> EditorModel {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 1000, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return EditorModel(image: try XCTUnwrap(context.makeImage()), pointSize: CGSize(width: 600, height: 500),
                           fileURL: nil, title: "Crop test")
    }
}
