import Foundation

/// Keeps the log of each run in a file, so that what a run did can still be read once its
/// window has been closed.
enum RunLog {

    /// `~/Library/Logs/Guava`, where macOS keeps an app's logs and Console looks for them.
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Guava", isDirectory: true)
    }

    /// How many runs are kept. The oldest go first.
    static let kept = 20

    /// The run as text: every log entry with its time, then what became of each item.
    static func text(log: [UpdateLogEntry], items: [UpdateItem], timeZone: TimeZone = .current) -> String {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = timeZone
        clock.dateFormat = "HH:mm:ss"

        var lines = log.map { entry -> String in
            let time = clock.string(from: entry.date)
            switch entry.level {
            case .phase: return "\n\(time) ==> \(entry.text)"
            case .info: return "\(time)   \(entry.text)"
            case .detail: return "\(time)   \(entry.text)"
            case .success: return "\(time)   ✓ \(entry.text)"
            case .warning: return "\(time)   ! \(entry.text)"
            case .error: return "\(time)   ✗ \(entry.text)"
            }
        }
        if !items.isEmpty {
            lines.append("\nResults")
            lines += items.map { "  \(HeadlessRunner.marker(for: $0.state)) \($0.name): \($0.state.detail)" }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    /// Writes the text of a run that began at `started`, and deletes the logs of all but the
    /// most recent runs. Returns the file, or nil when it could not be written.
    @discardableResult
    static func write(_ text: String, started: Date, in directory: URL = directory, timeZone: TimeZone = .current) -> URL? {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = timeZone
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let file = directory.appendingPathComponent("update-\(stamp.string(from: started)).log")

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        // The names sort by time, so the oldest come first.
        let logs = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("update-") && $0.hasSuffix(".log") }
            .sorted()
        for name in logs.dropLast(kept) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        return file
    }
}
