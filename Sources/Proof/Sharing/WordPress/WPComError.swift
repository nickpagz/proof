import Foundation

enum WPComError: LocalizedError, Equatable {
    case missingClientSecret
    case notSignedIn
    case authExpired
    case portInUse
    case timedOut
    case cancelled
    case denied
    case stateMismatch
    case keychain(OSStatus)
    case keychainAccessDenied
    case retryable(String)
    case failed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingClientSecret:
            return "This build has no WordPress.com app ID and secret, so sign-in is unavailable. Add them to .secrets/wpcom.env and rebuild (see docs/DEVELOPMENT.md)."
        case .notSignedIn:
            return "Not signed in to WordPress.com."
        case .authExpired:
            return "WordPress.com no longer accepts the saved sign-in. Sign in again."
        case .portInUse:
            return "Port \(WPComConfig.callbackPort) is in use, so the sign-in callback cannot be received. Quit whatever holds it (lsof -i :\(WPComConfig.callbackPort)) and try again."
        case .timedOut:
            return "Timed out waiting for the browser. Try signing in again."
        case .cancelled:
            return "Cancelled."
        case .denied:
            return "Sign-in was cancelled in the browser."
        case .stateMismatch:
            return "The browser returned an unexpected response. Try signing in again."
        case .keychain(let status):
            return "Keychain error \(status)."
        case .keychainAccessDenied:
            return "Keychain access was denied, so the saved sign-in cannot be read. Sign in again."
        case .retryable(let message):
            return "Temporary problem: \(message)"
        case .failed(let message):
            return message
        case .invalidResponse(let detail):
            return "Unexpected response from WordPress.com (\(detail))."
        }
    }

    var isRetryable: Bool {
        if case .retryable = self { return true }
        return false
    }
}
