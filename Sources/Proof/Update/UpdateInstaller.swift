import CryptoKit
import Darwin
import Foundation
import Security

/// Downloads, verifies and installs a release over the running bundle, then arranges a relaunch.
/// Pure plumbing: `UpdateController` (app) and `UpdateCLI` (terminal) drive it and show progress.
///
/// Why this is safe without Developer ID: the manifest is Ed25519-signed and pins the zip's hash,
/// the unpacked bundle must satisfy the running app's own designated requirement (same signing
/// identity), and the file is written by this process, so it never carries a quarantine flag and
/// Gatekeeper never gets involved. TCC and Keychain grants key on bundle ID plus code identity,
/// not on the path, so they survive the swap.
enum UpdateInstaller {
    struct Target {
        let bundleURL: URL
        let parent: URL
    }

    enum Step: Sendable {
        case downloading(Int64, Int64)
        case verifying
        case installing
        /// The new bundle has a different signing identity and the signed manifest allowed it.
        case identityChange(String)
    }

    static let stagingPrefix = "ProofUpdate-"
    static let swapPrefix = ".Proof-update-"
    static let oldPrefix = ".Proof-old-"

    // MARK: Pipeline

    /// Runs the whole update. On return the new bundle sits where the old one was and a helper is
    /// waiting for this process to exit before it removes the old bundle (and relaunches).
    @discardableResult
    static func install(_ payload: UpdatePayload, session: URLSession, launchAfter: Bool,
                        report: @escaping @Sendable (Step) -> Void) async throws -> URL {
        guard payload.minimumOSIsSatisfied else { throw UpdateError.osTooOld(payload.minimumSystemVersion) }
        let target = try preflight()
        let staging = try makeStagingDirectory()
        do {
            report(.downloading(0, Int64(payload.zip.size)))
            let zip = try await download(payload, from: UpdateConfig.zipURL(for: payload), into: staging, session: session) {
                report(.downloading($0, $1))
            }
            report(.verifying)
            let app = try await extract(zip, into: staging)
            if let notice = try check(app, against: payload) { report(.identityChange(notice)) }
            report(.installing)
            let old = try await swap(app, into: target, allowsIdentityChange: payload.allowsIdentityChange)
            try? FileManager.default.removeItem(at: staging)
            try scheduleRelaunch(newApp: target.bundleURL, removing: old, launch: launchAfter)
            return old
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    // MARK: Pre-flight

    /// Where the running app lives, and whether it can be replaced there.
    static func preflight(feedOverride: Bool = UpdateConfig.usesFeedOverride) throws -> Target {
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        guard bundle.pathExtension == "app", Bundle.main.bundleIdentifier == UpdateConfig.bundleID else {
            throw UpdateError.notInstallable("Updates only work when Proof runs as an app bundle.")
        }
        let path = bundle.path
        let parent = bundle.deletingLastPathComponent()
        if path.contains("/AppTranslocation/") {
            throw UpdateError.notInstallable("macOS is running Proof from a temporary copy. Move Proof to your Applications folder, open it from there, and update again.")
        }
        if let values = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]), values.volumeIsReadOnly == true {
            throw UpdateError.notInstallable("Proof is running from a disk image. Drag it to your Applications folder, open it from there, and update again.")
        }
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.standardizedFileURL,
           path.hasPrefix(downloads.path + "/") {
            throw UpdateError.notInstallable("Move Proof out of Downloads and into your Applications folder, then update again.")
        }
        if path.contains("/build/") && !feedOverride {
            throw UpdateError.notInstallable("This is a development build, so it doesn't update itself. Use Scripts/publish.sh --local and set \(UpdateConfig.feedDefaultsKey) to test updates.")
        }
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notInstallable("Proof can't replace itself in \(parent.path). Reinstall it with the command below instead.")
        }
        return Target(bundleURL: bundle, parent: parent)
    }

    // MARK: Download

    static func makeStagingDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// Streams the zip to disk while hashing it. Stops early if more bytes arrive than promised.
    static func download(_ payload: UpdatePayload, from url: URL, into directory: URL, session: URLSession,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        guard payload.zip.size <= UpdateConfig.maximumZipSize else { throw UpdateError.tooLarge(payload.zip.size) }
        let total = Int64(payload.zip.size)
        let destination = directory.appendingPathComponent(payload.zip.name)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw UpdateError.downloadFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw UpdateError.downloadFailed("no HTTP response") }
        guard http.statusCode == 200 else { throw UpdateError.downloadFailed("HTTP \(http.statusCode) from \(url.host ?? url.absoluteString)") }
        if http.expectedContentLength > 0, http.expectedContentLength != total {
            throw UpdateError.sizeMismatch(expected: payload.zip.size, actual: Int(http.expectedContentLength))
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw UpdateError.downloadFailed("couldn't create \(destination.path)")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var hasher = SHA256()
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var received: Int64 = 0
        var lastReported: Int64 = 0
        func flush() throws {
            received += Int64(buffer.count)
            guard received <= total else { throw UpdateError.sizeMismatch(expected: payload.zip.size, actual: Int(received)) }
            hasher.update(data: buffer)
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count == 1 << 16 {
                    try flush()
                    try Task.checkCancellation()
                    if received - lastReported >= 1 << 18 {
                        lastReported = received
                        progress(received, total)
                    }
                }
            }
            try flush()
        } catch let error as UpdateError {
            throw error
        } catch is CancellationError {
            throw UpdateError.cancelled
        } catch {
            throw UpdateError.downloadFailed(error.localizedDescription)
        }
        progress(received, total)
        guard received == total else { throw UpdateError.sizeMismatch(expected: payload.zip.size, actual: Int(received)) }
        guard UpdateManifest.hex(hasher.finalize()) == payload.zip.sha256 else { throw UpdateError.hashMismatch }
        return destination
    }

    // MARK: Unpack and check

    /// `ditto` keeps signatures, resource forks and symlinks intact; `unzip` does not.
    static func extract(_ zip: URL, into directory: URL) async throws -> URL {
        let out = directory.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let result = try await run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        guard result.status == 0 else {
            throw UpdateError.extractFailed(result.output.isEmpty ? "ditto exited with status \(result.status)" : result.output)
        }
        let items = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
        guard items.count == 1, items[0].pathExtension == "app" else {
            throw UpdateError.extractFailed("the archive should contain exactly one app")
        }
        return items[0]
    }

    /// The bundle must be the one the manifest describes, run on this macOS, and satisfy the running
    /// app's designated requirement. Returns a notice when the identity changed and that was allowed.
    static func check(_ app: URL, against payload: UpdatePayload) throws -> String? {
        guard let info = Bundle(url: app)?.infoDictionary else { throw UpdateError.bundleMismatch("it has no Info.plist") }
        let id = info["CFBundleIdentifier"] as? String ?? ""
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = Int(info["CFBundleVersion"] as? String ?? "") ?? -1
        guard id == payload.bundleID else { throw UpdateError.bundleMismatch("its bundle ID is \(id)") }
        guard version == payload.version, build == payload.build else {
            throw UpdateError.bundleMismatch("it is \(version) (\(build)), not \(payload.version) (\(payload.build))")
        }
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            let parts = AppVersion(minimum).components
            let needed = OperatingSystemVersion(majorVersion: parts.count > 0 ? parts[0] : 0,
                                                minorVersion: parts.count > 1 ? parts[1] : 0,
                                                patchVersion: parts.count > 2 ? parts[2] : 0)
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(needed) else { throw UpdateError.osTooOld(minimum) }
        }
        return try checkIdentity(of: app, allowsChange: payload.allowsIdentityChange)
    }

    /// Validates the new bundle's signature against the running app's designated requirement in
    /// one call: "validly signed, nothing modified, same identity as me".
    static func checkIdentity(of app: URL, allowsChange: Bool) throws -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else {
            throw UpdateError.identityMismatch("couldn't read this app's own signature")
        }
        var selfStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic else {
            throw UpdateError.identityMismatch("couldn't read this app's own signature")
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.identityMismatch("this app has no designated requirement (is it signed?)")
        }
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw UpdateError.identityMismatch("couldn't read the new app's signature")
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSCheckNestedCode) | UInt32(kSecCSStrictValidate))
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(newCode, flags, requirement, &error)
        if status == errSecSuccess { return nil }
        let detail = describe(status, error)
        var signedError: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(newCode, flags, nil, &signedError) == errSecSuccess else {
            throw UpdateError.identityMismatch("its signature is invalid (\(detail))")
        }
        guard allowsChange else { throw UpdateError.identityMismatch(detail) }
        return "Proof was updated to a build signed by a new identity. macOS will ask again for Screen Recording, microphone and camera access, and you may need to sign in to your sharing accounts again."
    }

    /// Security's own wording ("code failed to satisfy specified code requirement(s)") beats the
    /// CFError description, which is just the status number.
    private static func describe(_ status: OSStatus, _ error: Unmanaged<CFError>?) -> String {
        _ = error?.takeRetainedValue()
        switch status {
        case errSecCSReqFailed: return "it was signed by someone else"
        case errSecCSUnsigned: return "it isn't signed at all"
        case errSecCSSignatureFailed, errSecCSBadResource, errSecCSSignatureInvalid: return "its signature doesn't match its contents"
        default: return (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        }
    }

    // MARK: Swap

    /// Copies the new bundle next to the old one (same volume), re-checks the copy, then swaps the two
    /// directory entries atomically. The old bundle ends up at the staged path for the helper to remove.
    static func swap(_ newApp: URL, into target: Target, allowsIdentityChange: Bool) async throws -> URL {
        let staged = target.parent.appendingPathComponent(swapPrefix + UUID().uuidString + ".app", isDirectory: true)
        let copy = try await run("/usr/bin/ditto", [newApp.path, staged.path])
        guard copy.status == 0 else {
            try? FileManager.default.removeItem(at: staged)
            throw UpdateError.swapFailed("couldn't copy into \(target.parent.path): \(copy.output)")
        }
        do {
            _ = try checkIdentity(of: staged, allowsChange: allowsIdentityChange)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        if renamex_np(staged.path, target.bundleURL.path, UInt32(RENAME_SWAP)) == 0 {
            return staged
        }
        let code = errno
        if code == EACCES || code == EPERM {
            try? FileManager.default.removeItem(at: staged)
            throw UpdateError.swapFailed("no permission to replace \(target.bundleURL.path). Reinstall it with the command below instead.")
        }
        // Not APFS, or the swap is unsupported here: two moves, rolled back if the second fails.
        let old = target.parent.appendingPathComponent(oldPrefix + UUID().uuidString + ".app", isDirectory: true)
        do {
            try FileManager.default.moveItem(at: target.bundleURL, to: old)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw UpdateError.swapFailed(error.localizedDescription)
        }
        do {
            try FileManager.default.moveItem(at: staged, to: target.bundleURL)
        } catch {
            try? FileManager.default.moveItem(at: old, to: target.bundleURL)
            try? FileManager.default.removeItem(at: staged)
            throw UpdateError.swapFailed(error.localizedDescription)
        }
        return old
    }

    // MARK: Relaunch

    /// A detached shell waits for this process to exit (30 s at most), removes the old bundle, touches the
    /// new one so Launch Services notices it, and opens it. No stdio, so it outlives the app.
    static func scheduleRelaunch(newApp: URL, removing old: URL?, launch: Bool) throws {
        let script = """
        i=0
        while kill -0 "$1" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i + 1)); done
        if [ -n "$2" ]; then rm -rf "$2"; fi
        touch "$3"
        if [ "$4" = "1" ]; then open "$3"; fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "proof-relaunch",
                             String(ProcessInfo.processInfo.processIdentifier), old?.path ?? "", newApp.path, launch ? "1" : "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.swapFailed("the new version is in place but couldn't be relaunched automatically: \(error.localizedDescription). Quit and reopen Proof.")
        }
    }

    // MARK: Housekeeping

    /// Removes staging folders from runs that died halfway, and old bundles a helper failed to delete.
    /// Anything added in the last two minutes is left alone in case another copy is mid-swap.
    static func cleanUpLeftovers() {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent.hasPrefix(stagingPrefix) {
                try? fm.removeItem(at: item)
            }
        }
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        guard let items = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.addedToDirectoryDateKey]) else { return }
        for item in items {
            let name = item.lastPathComponent
            guard name.hasPrefix(swapPrefix) || name.hasPrefix(oldPrefix) else { continue }
            let added = (try? item.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate ?? .distantPast
            if Date().timeIntervalSince(added) > 120 {
                try? fm.removeItem(at: item)
            }
        }
    }

    // MARK: Process helper

    struct RunResult {
        let status: Int32
        let output: String
    }

    static func run(_ executable: String, _ arguments: [String]) async throws -> RunResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: RunResult(status: finished.terminationStatus, output: output))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: UpdateError.extractFailed("couldn't run \(executable): \(error.localizedDescription)"))
            }
        }
    }
}
