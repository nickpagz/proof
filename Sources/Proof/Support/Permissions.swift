import AVFoundation
import AppKit
import CoreGraphics

enum PermissionState: Equatable {
    case notDetermined, granted, denied

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .granted
        case .notDetermined: self = .notDetermined
        default: self = .denied
        }
    }
}

enum Permissions {
    /// True when this app may enumerate and capture screen content.
    static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt once; the app has to be relaunched after the grant.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func state(for mediaType: AVMediaType) -> PermissionState {
        PermissionState(AVCaptureDevice.authorizationStatus(for: mediaType))
    }

    static func request(_ mediaType: AVMediaType) async -> Bool {
        await AVCaptureDevice.requestAccess(for: mediaType)
    }

    enum SettingsPane: String {
        case screenRecording = "Privacy_ScreenCapture"
        case microphone = "Privacy_Microphone"
        case camera = "Privacy_Camera"
    }

    @MainActor
    static func openSystemSettings(_ pane: SettingsPane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }
}
