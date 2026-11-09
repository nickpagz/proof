import Foundation
import os

enum Log {
    static let subsystem = "io.github.nickpagz.proof"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")

    /// Plain-text session log at ~/Library/Logs/Proof/proof.log, for diagnosing a run
    /// after the fact without the unified log. Keeps the last 512 KB.
    static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Proof", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("proof.log")
    }()

    private static let fileQueue = DispatchQueue(label: "io.github.nickpagz.proof.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func note(_ message: String) {
        app.notice("\(message)")
        let line = "\(stamp.string(from: Date())) \(message)\n"
        fileQueue.async {
            if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > 512 * 1024 {
                try? FileManager.default.removeItem(at: fileURL)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? line.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }
}
