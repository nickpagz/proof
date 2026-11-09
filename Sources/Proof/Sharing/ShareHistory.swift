import Foundation
import Observation

/// Uploads Proof has made, newest first, so links can be copied again and uploads deleted.
/// A JSON file in Application Support; only links and delete handles, never images or secrets.
struct ShareRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    let date: Date
    let title: String
    let visibility: ShareVisibility
    let result: ShareResult
}

@MainActor @Observable
final class ShareHistory {
    private(set) var records: [ShareRecord] = []
    private let fileURL: URL
    static let limit = 200

    init(fileURL: URL = ShareHistory.defaultURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder.iso.decode([ShareRecord].self, from: data) {
            records = saved
        }
    }

    nonisolated static let defaultURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Proof/shares.json")
    }()

    func add(_ record: ShareRecord) {
        records.insert(record, at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
        persist()
    }

    func remove(_ id: UUID) {
        records.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.iso.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            Log.note("share history not saved: \(error.localizedDescription)")
        }
    }
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
