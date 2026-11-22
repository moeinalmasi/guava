import Foundation

/// A disk image attached to this Mac.
struct MountedImage: Equatable, Sendable {
    let imagePath: String
    let mountPoints: [String]
    let deviceEntries: [String]
}

/// What a cleanup pass removed.
struct CleanupReport: Equatable, Sendable {
    var bytesFreed: Int64 = 0
    /// Items deleted permanently.
    var removed: [String] = []
    /// Installers moved from Downloads to the Trash.
    var trashed: [String] = []
    var detachedVolumes: [String] = []
    var problems: [String] = []

    var isEmpty: Bool {
        removed.isEmpty && trashed.isEmpty && detachedVolumes.isEmpty && problems.isEmpty
    }

    mutating func merge(_ other: CleanupReport) {
        bytesFreed += other.bytesFreed
        removed += other.removed
        trashed += other.trashed
        detachedVolumes += other.detachedVolumes
        problems += other.problems
    }
}

/// Removes everything an update run downloaded.
enum InstallCleanup {

    /// File types that are installers and nothing else.
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip"]

    private static let runPrefix = "run-"

    /// Where update runs keep their downloads until they are installed.
    static var stagingRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("Guava/staging", isDirectory: true)
    }

    /// Create a folder for one run. Its name records the owning process so that another
    /// instance never mistakes a live run for an abandoned one.
    static func makeRunDirectory(in root: URL = stagingRoot) throws -> URL {
        let name = "\(runPrefix)\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))"
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Staging

    /// Detach any disk images mounted from `directory`, then delete it.
    /// Refuses to touch anything that is not inside `root`.
    static func removeDirectory(_ directory: URL, within root: URL = stagingRoot) async -> CleanupReport {
        var report = CleanupReport()
        guard isInside(directory, root) else {
            report.problems.append("Refused to delete \(directory.path): it is outside the staging folder")
            return report
        }
        guard FileManager.default.fileExists(atPath: directory.path) else { return report }

        report.detachedVolumes = await detachImages(under: directory)

        let size = directorySize(directory)
        if (try? FileManager.default.removeItem(at: directory)) == nil {
            // Unpacked bundles can contain read-only folders that block deletion.
            _ = await ProcessRunner.run("/bin/chmod", ["-R", "u+rwX", directory.path], timeout: 120)
            _ = await ProcessRunner.run("/bin/rm", ["-rf", directory.path], timeout: 300)
        }

        if FileManager.default.fileExists(atPath: directory.path) {
            report.problems.append("Could not delete \(directory.path)")
        } else {
            report.bytesFreed += size
            report.removed.append(directory.path)
        }
        return report
    }

    /// Delete run folders left behind by a Guava process that is no longer running.
    static func removeAbandonedRuns(in root: URL = stagingRoot) async -> CleanupReport {
        var report = CleanupReport()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name.hasPrefix(runPrefix) {
            let fields = name.dropFirst(runPrefix.count).split(separator: "-")
            if let pid = fields.first.flatMap({ pid_t($0) }), processExists(pid) {
                continue
            }
            report.merge(await removeDirectory(root.appendingPathComponent(name), within: root))
        }
        return report
    }

    // MARK: - Disk images

    /// Parse the output of `hdiutil info -plist`.
    static func parseMountedImages(_ data: Data) -> [MountedImage] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else {
            return []
        }
        return images.compactMap { image in
            guard let path = image["image-path"] as? String else { return nil }
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            return MountedImage(
                imagePath: path,
                mountPoints: entities.compactMap { $0["mount-point"] as? String },
                deviceEntries: entities.compactMap { $0["dev-entry"] as? String }
            )
        }
    }

    static func mountedImages() async -> [MountedImage] {
        let result = await ProcessRunner.run("/usr/bin/hdiutil", ["info", "-plist"], timeout: 60)
        guard result.success, let data = result.stdout.data(using: .utf8) else { return [] }
        return parseMountedImages(data)
    }

    /// Images whose file or mount point lies under `directory`.
    static func images(_ images: [MountedImage], under directory: URL) -> [MountedImage] {
        images.filter { image in
            isInside(URL(fileURLWithPath: image.imagePath), directory)
                || image.mountPoints.contains { isInside(URL(fileURLWithPath: $0), directory) }
        }
    }

    /// Detach every disk image that was mounted from, or onto, `directory`.
    @discardableResult
    static func detachImages(under directory: URL) async -> [String] {
        var detached: [String] = []
        for image in images(await mountedImages(), under: directory) {
            // Detaching the whole-disk device releases every volume of the image at once.
            let targets = image.deviceEntries.prefix(1) + image.mountPoints
            for target in targets {
                let result = await ProcessRunner.run(
                    "/usr/bin/hdiutil", ["detach", target, "-force"], timeout: 120
                )
                if result.success {
                    detached.append(image.mountPoints.first ?? image.imagePath)
                    break
                }
            }
        }
        return detached
    }

    // MARK: - Downloads folder

    /// Names of the items currently in `directory`.
    static func snapshot(of directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    /// Move installers that appeared in `directory` during a run to the Trash.
    ///
    /// Only unambiguous installer types are touched, and only ones that were absent before the
    /// run and created after it started. They go to the Trash rather than being erased because
    /// Guava cannot prove an item in the user's own Downloads folder came from its agent.
    static func sweepInstallers(
        in directory: URL,
        createdAfter start: Date,
        excluding snapshot: Set<String>,
        dispose: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> CleanupReport {
        var report = CleanupReport()
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []

        for name in names.sorted() where !snapshot.contains(name) {
            let url = directory.appendingPathComponent(name)
            guard installerExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let created = values.creationDate, created >= start else {
                continue
            }
            do {
                try dispose(url)
                report.trashed.append(name)
                report.bytesFreed += Int64(values.fileSize ?? 0)
            } catch {
                report.problems.append("Could not move \(name) to the Trash: \(error.localizedDescription)")
            }
        }
        return report
    }

    // MARK: - Homebrew cache

    /// Homebrew stores every download as "<SHA-256 of its URL>--<file name>".
    static func isBrewDownloadName(_ name: String) -> Bool {
        let digest = name.prefix(64)
        return digest.count == 64
            && digest.allSatisfy { "0123456789abcdef".contains($0) }
            && name.dropFirst(64).hasPrefix("--")
            && name.count > 66
    }

    /// Delete downloads that `brew cleanup` left in Homebrew's cache, and the links to them.
    ///
    /// The cache location comes from Homebrew's configuration, so nothing is deleted on the
    /// strength of the folder alone: only items named the way Homebrew names its downloads go.
    /// A cache pointed at the home folder, where `downloads` is the user's own Downloads on a
    /// case-insensitive disk, therefore loses nothing.
    static func removeBrewCacheLeftovers(cache: URL) -> CleanupReport {
        var report = CleanupReport()
        let fileManager = FileManager.default
        let downloads = cache.appendingPathComponent("downloads", isDirectory: true)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: downloads.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return report
        }

        for name in (try? fileManager.contentsOfDirectory(atPath: downloads.path)) ?? []
        where isBrewDownloadName(name) {
            let url = downloads.appendingPathComponent(name)
            let size = itemSize(url)
            do {
                try fileManager.removeItem(at: url)
                report.removed.append(url.path)
                report.bytesFreed += size
            } catch {
                report.problems.append("Could not delete \(name): \(error.localizedDescription)")
            }
        }

        // Homebrew links "name--version" to each download; drop the links that now lead nowhere.
        for folder in [cache, cache.appendingPathComponent("Cask", isDirectory: true)] {
            for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] {
                let url = folder.appendingPathComponent(name)
                guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
                      !fileManager.fileExists(atPath: url.path),
                      let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
                    continue
                }
                let components = (destination as NSString).pathComponents
                guard components.count >= 2,
                      components[components.count - 2] == "downloads",
                      isBrewDownloadName(components[components.count - 1]) else { continue }
                try? fileManager.removeItem(at: url)
            }
        }
        return report
    }

    // MARK: - Helpers

    /// Total size of the regular files under `url`.
    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static func itemSize(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]) else {
            return 0
        }
        if values.isSymbolicLink == true { return 0 }
        return values.isDirectory == true ? directorySize(url) : Int64(values.fileSize ?? 0)
    }

    /// True when `url` is `directory` or lies beneath it. Compares resolved paths so that a
    /// symbolic link cannot make an outside location look like an inside one.
    static func isInside(_ url: URL, _ directory: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    private static func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
