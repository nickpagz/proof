import CoreGraphics

/// The crop controls operate in image points, but Custom sizes are specified in source pixels.
enum CropFormat: String, CaseIterable {
    case freeform = "Freeform", wide = "16:9", standard = "4:3", square = "1:1", portrait = "9:16", custom = "Custom"

    var ratio: CGFloat? {
        switch self {
        case .wide: return 16.0 / 9
        case .standard: return 4.0 / 3
        case .square: return 1
        case .portrait: return 9.0 / 16
        case .freeform, .custom: return nil
        }
    }
}

struct CropPixelSize: Codable, Equatable {
    let width: Int
    let height: Int
}

enum CropGeometry {
    static func centered(_ size: CGSize, at center: CGPoint, in bounds: CGSize) -> CGRect {
        positioned(size, at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), in: bounds)
    }

    static func positioned(_ size: CGSize, at origin: CGPoint, in bounds: CGSize) -> CGRect {
        CGRect(x: min(max(0, origin.x), max(0, bounds.width - size.width)),
               y: min(max(0, origin.y), max(0, bounds.height - size.height)),
               width: size.width, height: size.height)
    }

    static func fit(_ ratio: CGFloat, inside rect: CGRect) -> CGRect {
        let width = min(rect.width, rect.height * ratio)
        return centered(CGSize(width: width, height: width / ratio),
                        at: CGPoint(x: rect.midX - rect.minX, y: rect.midY - rect.minY), in: rect.size)
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }

    /// A zero direction denotes an edge handle: resize symmetrically on that axis.
    /// Nonzero directions keep the opposite edge or corner anchored at its drag-start position.
    static func lockedDrag(from anchor: CGPoint, to point: CGPoint, dx: CGFloat, dy: CGFloat,
                           ratio: CGFloat, in bounds: CGSize) -> CGRect {
        let maxWidth = dx == 0 ? 2 * min(anchor.x, bounds.width - anchor.x) : dx < 0 ? anchor.x : bounds.width - anchor.x
        let maxHeight = dy == 0 ? 2 * min(anchor.y, bounds.height - anchor.y) : dy < 0 ? anchor.y : bounds.height - anchor.y
        let x = (point.x - anchor.x) * dx, y = (point.y - anchor.y) * dy
        let requestedWidth: CGFloat
        if dx == 0 { requestedWidth = y * ratio }
        else if dy == 0 { requestedWidth = x }
        else { requestedWidth = (x * ratio + y) * ratio / (ratio * ratio + 1) }
        let width = min(max(0, requestedWidth), max(0, maxWidth), max(0, maxHeight) * ratio)
        let height = width / ratio
        return CGRect(x: anchor.x - (dx < 0 ? width : dx == 0 ? width / 2 : 0),
                      y: anchor.y - (dy < 0 ? height : dy == 0 ? height / 2 : 0),
                      width: width, height: height)
    }
}
