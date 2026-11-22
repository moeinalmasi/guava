import Foundation
import Testing
@testable import Guava

@Suite("Install cleanup")
struct InstallCleanupTests {

    @Test("deletes a staging folder and reports the space it freed")
    func removesStagingFolder() async throws {
        let scratch = try TemporaryDirectory()
        let root = try scratch.makeDirectory("staging")
        let run = try InstallCleanup.makeRunDirectory(in: root)
        try String(repeating: "x", count: 4096).write(
            to: run.appendingPathComponent("installer.dmg"), atomically: true, encoding: .utf8
        )

        let report = await InstallCleanup.removeDirectory(run, within: root)

        #expect(!FileManager.default.fileExists(atPath: run.path))
        #expect(report.bytesFreed == 4096)
        #expect(report.removed == [run.path])
        #expect(report.problems.isEmpty)
    }

    @Test("deletes unpacked bundles even when they contain read-only folders")
    func removesReadOnlyContents() async throws {
        let scratch = try TemporaryDirectory()
        let root = try scratch.makeDirectory("staging")
        let run = try InstallCleanup.makeRunDirectory(in: root)
        let locked = run.appendingPathComponent("payload/App.app/Contents")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try "data".write(to: locked.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)

        let report = await InstallCleanup.removeDirectory(run, within: root)

        #expect(!FileManager.default.fileExists(atPath: run.path))
        #expect(report.problems.isEmpty)
    }

    @Test("refuses to delete anything outside the staging folder")
    func refusesOutsidePaths() async throws {
        let scratch = try TemporaryDirectory()
        let root = try scratch.makeDirectory("staging")
        let outside = try scratch.makeDirectory("precious")
        let escape = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)

        let direct = await InstallCleanup.removeDirectory(outside, within: root)
        let throughLink = await InstallCleanup.removeDirectory(escape, within: root)
        let traversal = await InstallCleanup.removeDirectory(root.appendingPathComponent("../precious"), within: root)

        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(direct.problems.count == 1)
        #expect(throughLink.problems.count == 1)
        #expect(traversal.problems.count == 1)
    }

    @Test("clears runs left by processes that have exited but not live ones")
    func removesOnlyAbandonedRuns() async throws {
        let scratch = try TemporaryDirectory()
        let root = try scratch.makeDirectory("staging")
        let live = try InstallCleanup.makeRunDirectory(in: root)
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        let abandoned = try scratch.makeDirectory("staging/run-\(finished.processIdentifier)-deadbeef")
        let unrelated = try scratch.makeDirectory("staging/notes")

        let report = await InstallCleanup.removeAbandonedRuns(in: root)

        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(report.removed == [abandoned.path])
    }

    @Test("finds the disk images mounted from or onto a folder")
    func matchesMountedImages() throws {
        let plist: [String: Any] = [
            "images": [
                [
                    "image-path": "/stage/run/app/downloads/app.dmg",
                    "system-entities": [
                        ["dev-entry": "/dev/disk9"],
                        ["dev-entry": "/dev/disk9s1", "mount-point": "/Volumes/App"],
                    ],
                ],
                [
                    "image-path": "/Users/me/Downloads/other.dmg",
                    "system-entities": [["dev-entry": "/dev/disk7s1", "mount-point": "/stage/run/app/mnt"]],
                ],
                [
                    "image-path": "/Users/me/Downloads/unrelated.dmg",
                    "system-entities": [["dev-entry": "/dev/disk5s1", "mount-point": "/Volumes/Unrelated"]],
                ],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        let images = InstallCleanup.parseMountedImages(data)
        let matching = InstallCleanup.images(images, under: URL(fileURLWithPath: "/stage/run"))

        #expect(images.count == 3)
        #expect(images[0].deviceEntries == ["/dev/disk9", "/dev/disk9s1"])
        #expect(matching.map(\.imagePath) == ["/stage/run/app/downloads/app.dmg", "/Users/me/Downloads/other.dmg"])
        #expect(InstallCleanup.parseMountedImages(Data("garbage".utf8)).isEmpty)
    }

    @Test("detaches a disk image the agent left mounted before deleting the folder")
    func detachesLeftoverImages() async throws {
        let scratch = try TemporaryDirectory()
        let root = try scratch.makeDirectory("staging")
        let run = try InstallCleanup.makeRunDirectory(in: root)
        let image = run.appendingPathComponent("downloads/app.dmg")
        let mountPoint = run.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)

        let created = await ProcessRunner.run(
            "/usr/bin/hdiutil",
            ["create", "-size", "2m", "-fs", "HFS+", "-volname", "GuavaCleanupTest", "-quiet", image.path],
            timeout: 120
        )
        try #require(created.success, "hdiutil create failed: \(created.failureMessage)")
        let attached = await ProcessRunner.run(
            "/usr/bin/hdiutil",
            ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path, image.path],
            timeout: 120
        )
        try #require(attached.success, "hdiutil attach failed: \(attached.failureMessage)")
        let mountedBefore = InstallCleanup.images(await InstallCleanup.mountedImages(), under: run)
        try #require(mountedBefore.count == 1)

        let report = await InstallCleanup.removeDirectory(run, within: root)

        #expect(report.detachedVolumes.count == 1)
        #expect(InstallCleanup.images(await InstallCleanup.mountedImages(), under: run).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: run.path))
        #expect(report.problems.isEmpty)
    }

    @Test("moves only installers that appeared during the run out of Downloads")
    func sweepsNewInstallers() async throws {
        let scratch = try TemporaryDirectory()
        let downloads = try scratch.makeDirectory("Downloads")
        try scratch.write("old", to: "Downloads/Existing.dmg")
        let snapshot = InstallCleanup.snapshot(of: downloads)
        let start = Date().addingTimeInterval(-1)

        try scratch.write("new installer", to: "Downloads/Fresh.dmg")
        try scratch.write("new package", to: "Downloads/Setup.PKG")
        try scratch.write("holiday photos", to: "Downloads/Photos.zip")
        try scratch.write("report", to: "Downloads/Report.pdf")
        try scratch.makeDirectory("Downloads/Folder.dmg")

        let disposed = Collector<String>()
        let report = InstallCleanup.sweepInstallers(in: downloads, createdAfter: start, excluding: snapshot) {
            disposed.append($0.lastPathComponent)
            try FileManager.default.removeItem(at: $0)
        }

        #expect(disposed.values == ["Fresh.dmg", "Setup.PKG"])
        #expect(report.trashed == ["Fresh.dmg", "Setup.PKG"])
        #expect(report.bytesFreed == Int64("new installer".utf8.count + "new package".utf8.count))
        #expect(scratch.exists("Downloads/Existing.dmg"))
        #expect(scratch.exists("Downloads/Photos.zip"))
        #expect(scratch.exists("Downloads/Report.pdf"))
        #expect(scratch.exists("Downloads/Folder.dmg"))
    }

    @Test("leaves an installer alone when it predates the run, even if it was not in the snapshot")
    func ignoresOlderInstallers() async throws {
        let scratch = try TemporaryDirectory()
        let downloads = try scratch.makeDirectory("Downloads")
        try scratch.write("moved in from elsewhere", to: "Downloads/Older.dmg")

        let report = InstallCleanup.sweepInstallers(
            in: downloads, createdAfter: Date().addingTimeInterval(60), excluding: []
        ) { _ in
            Issue.record("Nothing should be disposed of")
        }

        #expect(report.isEmpty)
        #expect(scratch.exists("Downloads/Older.dmg"))
    }

    /// Names shaped like Homebrew's: the SHA-256 of the download's URL, then the file name.
    private static let bottle = String(repeating: "0a", count: 32) + "--jq--1.8.arm64_tahoe.bottle.tar.gz"
    private static let package = String(repeating: "f1", count: 32) + "--tool-2.0.pkg"

    @Test("empties Homebrew's download folder and dangling links but keeps its metadata")
    func removesBrewLeftovers() throws {
        let scratch = try TemporaryDirectory()
        let cache = try scratch.makeDirectory("Homebrew")
        try scratch.write("bottle", to: "Homebrew/downloads/\(Self.bottle)")
        try scratch.write("pkg", to: "Homebrew/downloads/\(Self.package)")
        try scratch.write("{}", to: "Homebrew/api/cask.json")
        try scratch.makeDirectory("Homebrew/Cask")
        let fileManager = FileManager.default
        try fileManager.createSymbolicLink(
            atPath: cache.appendingPathComponent("jq--1.8").path,
            withDestinationPath: "downloads/\(Self.bottle)"
        )
        try fileManager.createSymbolicLink(
            atPath: cache.appendingPathComponent("Cask/tool.pkg").path,
            withDestinationPath: "../downloads/\(Self.package)"
        )
        try fileManager.createSymbolicLink(
            atPath: cache.appendingPathComponent("live-link").path,
            withDestinationPath: "api/cask.json"
        )

        let report = InstallCleanup.removeBrewCacheLeftovers(cache: cache)

        #expect(try fileManager.contentsOfDirectory(atPath: cache.appendingPathComponent("downloads").path).isEmpty)
        #expect(report.removed.count == 2)
        #expect(report.bytesFreed == Int64("bottle".utf8.count + "pkg".utf8.count))
        #expect(scratch.exists("Homebrew/api/cask.json"))
        #expect((try? fileManager.destinationOfSymbolicLink(atPath: cache.appendingPathComponent("jq--1.8").path)) == nil)
        #expect((try? fileManager.destinationOfSymbolicLink(atPath: cache.appendingPathComponent("Cask/tool.pkg").path)) == nil)
        #expect((try? fileManager.destinationOfSymbolicLink(atPath: cache.appendingPathComponent("live-link").path)) != nil)
    }

    @Test("does nothing when the folder is not a Homebrew cache")
    func ignoresNonCacheFolders() throws {
        let scratch = try TemporaryDirectory()
        try scratch.write("keep", to: "file.dmg")

        let report = InstallCleanup.removeBrewCacheLeftovers(cache: scratch.url)

        #expect(report.isEmpty)
        #expect(scratch.exists("file.dmg"))
    }

    @Test("deletes only what Homebrew put there, even if its cache is somewhere unexpected")
    func sparesFilesThatAreNotBrewDownloads() throws {
        // As if HOMEBREW_CACHE were the home folder: on a case-insensitive disk its
        // "downloads" is the user's own Downloads.
        let scratch = try TemporaryDirectory()
        try scratch.write("mine", to: "downloads/Tax return.pdf")
        try scratch.write("mine", to: "downloads/Installer.dmg")
        try scratch.write("mine", to: "downloads/abc--looks-similar.tar.gz")
        try scratch.write("mine", to: "downloads/\(String(repeating: "0A", count: 32))--upper-case.tar.gz")
        try scratch.write("bottle", to: "downloads/\(Self.bottle)")
        let fileManager = FileManager.default
        try fileManager.createSymbolicLink(
            atPath: scratch.url.appendingPathComponent("broken-shortcut").path,
            withDestinationPath: "Documents/gone.txt"
        )
        try fileManager.createSymbolicLink(
            atPath: scratch.url.appendingPathComponent("broken-download-shortcut").path,
            withDestinationPath: "downloads/gone.dmg"
        )

        let report = InstallCleanup.removeBrewCacheLeftovers(cache: scratch.url)

        let remaining = try fileManager.contentsOfDirectory(atPath: scratch.url.appendingPathComponent("downloads").path)
        #expect(Set(remaining) == [
            "Tax return.pdf", "Installer.dmg", "abc--looks-similar.tar.gz",
            "\(String(repeating: "0A", count: 32))--upper-case.tar.gz",
        ])
        #expect(report.removed.count == 1)
        #expect(report.problems.isEmpty)
        #expect((try? fileManager.destinationOfSymbolicLink(atPath: scratch.url.appendingPathComponent("broken-shortcut").path)) != nil)
        #expect((try? fileManager.destinationOfSymbolicLink(atPath: scratch.url.appendingPathComponent("broken-download-shortcut").path)) != nil)
    }

    @Test("recognises the names Homebrew gives its downloads", arguments: [
        (String(repeating: "0a", count: 32) + "--jq--1.8.bottle.tar.gz", true),
        (String(repeating: "0a", count: 32) + "--x", true),
        (String(repeating: "0a", count: 32) + "--", false),
        (String(repeating: "0a", count: 32) + "-jq", false),
        (String(repeating: "0a", count: 31) + "--jq.tar.gz", false),
        (String(repeating: "0g", count: 32) + "--jq.tar.gz", false),
        ("Installer.dmg", false),
        ("", false),
    ])
    func recognisesBrewDownloadNames(name: String, isDownload: Bool) {
        #expect(InstallCleanup.isBrewDownloadName(name) == isDownload)
    }
}
