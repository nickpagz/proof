import AppKit
import ScreenCaptureKit

enum CaptureKind: String, Codable {
    case area, window, fullscreen
}

/// One finished screenshot, before it is written anywhere.
struct Capture {
    let image: CGImage
    /// Size in points; `image` is usually larger on Retina displays.
    let pointSize: CGSize
    let kind: CaptureKind
    /// The app that owned the captured window, or the frontmost app, for file names.
    let appName: String?
    let date: Date

    var scale: CGFloat { pointSize.width > 0 ? CGFloat(image.width) / pointSize.width : 1 }
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplay
    case windowGone
    case emptyArea

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Proof needs Screen Recording permission. Allow it in System Settings → Privacy & Security, then reopen Proof."
        case .noDisplay: return "That area isn't on any display."
        case .windowGone: return "That window closed before it could be captured."
        case .emptyArea: return "The selected area is empty."
        }
    }
}

/// A window that can be picked, front to back, from the window server's list.
struct PickableWindow {
    let id: CGWindowID
    /// Global CoreGraphics points.
    let frame: CGRect
    let ownerName: String
    let ownerPID: pid_t
    let title: String
}

/// Marks Proof's own capture furniture (the selection overlay, the countdown, Quick Access
/// thumbnails), which never appears in a capture. Editor and Settings windows do.
protocol CaptureChrome: NSWindow {}

/// ScreenCaptureKit wrappers. Every rectangle here is in global CoreGraphics points.
enum ScreenGrabber {
    @MainActor
    static func chromeWindowIDs() -> Set<CGWindowID> {
        Set(NSApplication.shared.windows.filter { $0 is CaptureChrome && $0.windowNumber > 0 }.map { CGWindowID($0.windowNumber) })
    }

    static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if !Permissions.screenRecordingGranted() { throw CaptureError.permissionDenied }
            throw error
        }
    }

    /// Proof's capture furniture, and Finder's desktop (the icons) when they should be hidden.
    /// The wallpaper belongs to another process, so it stays.
    static func excludedWindows(in content: SCShareableContent, hideDesktopIcons: Bool, chrome: Set<CGWindowID>) -> [SCWindow] {
        content.windows.filter { window in
            if chrome.contains(window.windowID) { return true }
            guard let app = window.owningApplication else { return false }
            return hideDesktopIcons && app.bundleIdentifier == "com.apple.finder" && window.windowLayer < 0
        }
    }

    /// Captures `rect`, clipped to the display that holds most of it.
    static func capture(rect: CGRect, hideDesktopIcons: Bool) async throws -> CGImage {
        guard rect.width >= 1, rect.height >= 1 else { throw CaptureError.emptyArea }
        let content = try await shareableContent()
        guard let displayID = ScreenGeometry.displayID(containing: rect),
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplay
        }
        let bounds = CGDisplayBounds(displayID)
        let local = rect.intersection(bounds).offsetBy(dx: -bounds.minX, dy: -bounds.minY).integral
        guard local.width >= 1, local.height >= 1 else { throw CaptureError.emptyArea }

        let chrome = await chromeWindowIDs()
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows(in: content, hideDesktopIcons: hideDesktopIcons, chrome: chrome))
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = Int((local.width * scale).rounded())
        config.height = Int((local.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func capture(displayID: CGDirectDisplayID, hideDesktopIcons: Bool) async throws -> CGImage {
        try await capture(rect: CGDisplayBounds(displayID), hideDesktopIcons: hideDesktopIcons)
    }

    /// One window on its own, independent of what covers it. Uses macOS 26's screenshot API,
    /// which grows the image to fit the shadow; the older captureImage squeezes the window instead.
    static func capture(windowID: CGWindowID, shadow: Bool) async throws -> (CGImage, CGSize) {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureError.windowGone }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCScreenshotConfiguration()
        config.ignoreShadows = !shadow
        let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
        guard let image = output.sdrImage else { throw CaptureError.windowGone }
        let scale = max(CGFloat(filter.pointPixelScale), 1)
        return (image, CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }

    /// Normal app windows on screen, frontmost first, Proof's editor and Settings included. Uses
    /// the window server's list because it is ordered; ScreenCaptureKit's is not. The overlay and
    /// thumbnails sit above layer 0, so they're never offered.
    static func pickableWindows() -> [PickableWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return info.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 40, bounds.height > 40 else { return nil }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0 { return nil }
            return PickableWindow(id: id, frame: bounds,
                                  ownerName: entry[kCGWindowOwnerName as String] as? String ?? "",
                                  ownerPID: pid,
                                  title: entry[kCGWindowName as String] as? String ?? "")
        }
    }

    static var frontmostAppName: String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }
}
