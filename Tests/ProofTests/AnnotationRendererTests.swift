import CoreGraphics
import XCTest
@testable import Proof

final class AnnotationRendererTests: XCTestCase {
    func testClassicArrowsHaveNoTransparentGapAtTheHead() throws {
        let size = CGSize(width: 120, height: 40)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let canvas = try XCTUnwrap(CGContext(data: nil, width: 120, height: 40, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo))
        canvas.clear(CGRect(origin: .zero, size: size))
        let renderer = AnnotationRenderer(image: try XCTUnwrap(canvas.makeImage()))
        let pixel = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                            bytesPerRow: 4, space: colorSpace, bitmapInfo: bitmapInfo))
        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)

        for tool in [EditorTool.arrow, .numberedArrow] {
            let arrow = Annotation(tool: tool, start: CGPoint(x: 10, y: 20), end: CGPoint(x: 110, y: 20),
                                   number: 1, style: AnnotationStyle(lineWidth: 6, shadow: false))
            let document = AnnotationDocument(imageSize: size, scale: 1, annotations: [arrow])
            let rendered = try XCTUnwrap(renderer.render(document))

            // Sample the shaft, its join with the head, and the head beyond the join.
            for x in [80, 91, 101] {
                let sample = try XCTUnwrap(rendered.cropping(to: CGRect(x: x, y: 20, width: 1, height: 1)))
                pixel.clear(unitRect)
                pixel.draw(sample, in: unitRect)
                let alpha = try XCTUnwrap(pixel.data).load(fromByteOffset: 3, as: UInt8.self)
                XCTAssertEqual(alpha, 255, "\(tool) should be opaque at x=\(x)")
            }
        }
    }
}
