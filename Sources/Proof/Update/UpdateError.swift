import Foundation

/// Everything that can go wrong between "check for updates" and "relaunched". Messages are
/// shown to the user as-is, so they say what happened and what to do, not which call failed.
enum UpdateError: LocalizedError, Equatable {
    case feedUnavailable(String)
    case badManifest(String)
    case unknownKey(String)
    case badSignature
    case wrongBundle(String)
    case tooLarge(Int)
    case osTooOld(String)
    case downloadFailed(String)
    case hashMismatch
    case sizeMismatch(expected: Int, actual: Int)
    case extractFailed(String)
    case bundleMismatch(String)
    case identityMismatch(String)
    case notInstallable(String)
    case swapFailed(String)
    case busy
    case cancelled

    var errorDescription: String? {
        switch self {
        case .feedUnavailable(let why): return "Couldn't reach the update feed: \(why)"
        case .badManifest(let why): return "The update feed isn't usable: \(why)"
        case .unknownKey(let id): return "The update is signed with a key this build doesn't know (\(id)). Install the latest version by hand."
        case .badSignature: return "The update's signature doesn't match. Nothing was installed."
        case .wrongBundle(let id): return "The update is for a different app (\(id))."
        case .tooLarge(let bytes): return "The update is unexpectedly large (\(bytes / 1_048_576) MB). Nothing was downloaded."
        case .osTooOld(let needed): return "This version needs macOS \(needed) or newer."
        case .downloadFailed(let why): return "The download failed: \(why)"
        case .hashMismatch: return "The downloaded file doesn't match what the release promised. Nothing was installed."
        case .sizeMismatch(let expected, let actual): return "The download was \(actual) bytes but the release promised \(expected). Nothing was installed."
        case .extractFailed(let why): return "Couldn't unpack the update: \(why)"
        case .bundleMismatch(let why): return "The downloaded app isn't the one the release describes: \(why)"
        case .identityMismatch(let why): return "The downloaded app isn't signed by the same identity as this one: \(why)"
        case .notInstallable(let why): return why
        case .swapFailed(let why): return "Couldn't replace the app: \(why)"
        case .busy: return "Finish the recording or upload first."
        case .cancelled: return "Update cancelled."
        }
    }
}
