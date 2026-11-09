import Foundation

/// Turns a template like "Proof {date} at {time}" into a file name.
enum FileNaming {
    static let defaultTemplate = "Proof {date} at {time}"

    static let tokens: [(token: String, meaning: String)] = [
        ("{date}", "2026-11-08"),
        ("{time}", "14.05.09"),
        ("{year}", "2026"), ("{month}", "11"), ("{day}", "08"),
        ("{hour}", "14"), ("{minute}", "05"), ("{second}", "09"),
        ("{app}", "frontmost app"),
        ("{kind}", "area, window or fullscreen"),
        ("{n}", "a number that goes up by one each capture"),
    ]

    private static let counterKey = "fileNaming.counter"

    /// `counter` is only consumed when the template uses {n}.
    static func name(template: String, date: Date, appName: String?, kind: CaptureKind,
                     counter: () -> Int = FileNaming.nextCounter) -> String {
        let source = template.trimmingCharacters(in: .whitespaces).isEmpty ? defaultTemplate : template
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        let year = String(parts.year ?? 0)
        var values: [String: String] = [
            "{date}": "\(year)-\(two(parts.month))-\(two(parts.day))",
            "{time}": "\(two(parts.hour)).\(two(parts.minute)).\(two(parts.second))",
            "{year}": year, "{month}": two(parts.month), "{day}": two(parts.day),
            "{hour}": two(parts.hour), "{minute}": two(parts.minute), "{second}": two(parts.second),
            "{app}": appName ?? "Screen",
            "{kind}": kind.rawValue,
        ]
        if source.contains("{n}") { values["{n}"] = String(counter()) }
        var result = source
        for (token, value) in values { result = result.replacingOccurrences(of: token, with: value) }
        return sanitize(result)
    }

    /// Finder shows ":" as "/" and "/" can't appear in a name at all.
    static func sanitize(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Proof" : String(cleaned.prefix(200))
    }

    /// A meaningless name like `k3j9x2qfm8ap`, for share links that shouldn't say what's in them.
    static func random(length: Int = 12) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }

    /// `folder/name.ext`, or `name 2.ext`, `name 3.ext` … when that exists.
    static func uniqueURL(in folder: URL, name: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(name).appendingPathExtension(ext)
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name) \(index)").appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }

    static func nextCounter() -> Int {
        let next = UserDefaults.standard.integer(forKey: counterKey) + 1
        UserDefaults.standard.set(next, forKey: counterKey)
        return next
    }
}
