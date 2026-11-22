import Foundation

/// What Guava remembers about this Mac between launches: the apps it leaves out of its list,
/// and the updates that turned out not to be on offer here. Both name the apps on this Mac,
/// so the record is kept in the home folder and is never part of the repository.
struct LocalRecord: Codable, Equatable {

    /// An app nothing can update.
    struct HiddenApp: Codable, Equatable {
        var name: String
        var path: String
    }

    /// An update that was attempted and did not arrive: the app is still at `installedVersion`
    /// although `latestVersion` exists.
    struct HeldUpdate: Codable, Equatable {
        var name: String
        var path: String
        var installedVersion: String
        var latestVersion: String
    }

    var hidden: [HiddenApp] = []
    var held: [HeldUpdate] = []

    init(hidden: [HiddenApp] = [], held: [HeldUpdate] = []) {
        self.hidden = hidden
        self.held = held
    }

    /// A record written by hand, or by an earlier version, may leave a list out.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hidden = try container.decodeIfPresent([HiddenApp].self, forKey: .hidden) ?? []
        held = try container.decodeIfPresent([HeldUpdate].self, forKey: .held) ?? []
    }
}

/// Where the record is kept.
struct LocalStore {
    /// Nil keeps the record in memory only.
    let url: URL?
    /// False for a run that must leave nothing behind: the record is read but never written.
    var isWritable = true

    /// The file `.guava` in the home folder.
    static var home: LocalStore {
        LocalStore(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".guava"))
    }

    /// Remembers nothing beyond the life of the model that uses it.
    static let none = LocalStore(url: nil)

    /// The same record, for reading only.
    var readOnly: LocalStore {
        LocalStore(url: url, isWritable: false)
    }

    /// An empty record when there is no file yet, or when the file cannot be read as one.
    func load() -> LocalRecord {
        guard let url,
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(LocalRecord.self, from: data) else {
            return LocalRecord()
        }
        return record
    }

    func save(_ record: LocalRecord) {
        guard let url, isWritable else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
