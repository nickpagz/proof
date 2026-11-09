import AppKit
import CoreGraphics

/// AppKit puts the origin at the bottom-left of the main display with y going up; CoreGraphics and
/// ScreenCaptureKit put it at the top-left with y going down. Everything stored or passed to the
/// capture engine is in CoreGraphics ("global") points; views convert at the edge.
enum ScreenGeometry {
    /// Height of the display that holds the menu bar, which anchors both coordinate systems.
    static var mainDisplayHeight: CGFloat {
        CGDisplayBounds(CGMainDisplayID()).height
    }

    static func globalRect(fromCocoa rect: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func cocoaRect(fromGlobal rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func globalPoint(fromCocoa point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: mainDisplayHeight - point.y)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { self.displayID(of: $0) == displayID }
    }

    /// The screen under the mouse pointer, where captures start by default.
    static var screenUnderMouse: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// The display that holds most of `rect` (global points).
    static func displayID(containing rect: CGRect) -> CGDirectDisplayID? {
        var best: (CGDirectDisplayID, CGFloat)?
        for screen in NSScreen.screens {
            let id = displayID(of: screen)
            let overlap = CGDisplayBounds(id).intersection(rect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if best == nil || area > best!.1 { best = (id, area) }
        }
        return best?.0
    }
}
