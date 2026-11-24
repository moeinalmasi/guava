import Foundation
@testable import Guava

/// A scratch directory that is removed when the value is released.
final class TemporaryDirectory {
    let url: URL

    init(_ label: String = "guava-tests") throws {
        // Resolve /var -> /private/var so paths compare equal to what tools report back.
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        url = base.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) throws -> URL {
        let directory = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    func write(_ contents: String, to relativePath: String, executable: Bool = false) throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: file, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return file
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(relativePath).path)
    }

    func read(_ relativePath: String) -> String? {
        try? String(contentsOf: url.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

/// Collects values from concurrently invoked callbacks.
final class Collector<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }

    var values: [Value] {
        lock.withLock { storage }
    }
}

enum Fixture {

    /// Builds a minimal ad-hoc signed `.app` bundle whose executable is a shell script.
    @discardableResult
    static func makeApp(
        at url: URL,
        bundleIdentifier: String = "com.example.fixture",
        version: String,
        name: String = "Fixture",
        minimumSystemVersion: String? = nil,
        extraInfo: [String: Any] = [:],
        sign: Bool = true
    ) async throws -> URL {
        let contents = url.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        var plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": name,
            "CFBundleExecutable": name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
        ]
        if let minimumSystemVersion {
            plist["LSMinimumSystemVersion"] = minimumSystemVersion
        }
        plist.merge(extraInfo) { _, extra in extra }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let executable = macOS.appendingPathComponent(name)
        try "#!/bin/sh\necho \(name) \(version)\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        if sign {
            let result = await ProcessRunner.run(
                "/usr/bin/codesign", ["--force", "--sign", "-", url.path], timeout: 60
            )
            guard result.success else {
                throw FixtureError.signingFailed(result.failureMessage)
            }
        }
        return url
    }

    static func version(ofAppAt url: URL) -> String? {
        AppScanner.readCurrentVersion(for: url.path)
    }

    /// Puts Finder information on a file or folder, as some vendors' disk images carry it on
    /// everything inside: no position in a Finder window, and nothing else.
    static func setFinderInfo(on path: String) throws {
        var info = [UInt8](repeating: 0, count: 32)
        info.replaceSubrange(10..<14, with: [0xFF, 0xFF, 0xFF, 0xFF])
        guard setxattr(path, "com.apple.FinderInfo", &info, info.count, 0, XATTR_NOFOLLOW) == 0 else {
            throw FixtureError.attributeNotSet(path)
        }
    }

    static func hasFinderInfo(_ path: String) -> Bool {
        getxattr(path, "com.apple.FinderInfo", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
}

enum FixtureError: Error {
    case signingFailed(String)
    case attributeNotSet(String)
}

extension GuavaViewModel {
    /// A model for tests: what it remembers stays in memory, and the home folder is left alone.
    convenience init() {
        self.init(store: .none)
    }
}

/// Whether Gatekeeper assessments are switched on for this Mac.
let gatekeeperEnabled: Bool = {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
    process.arguments = ["--status"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else { return false }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).contains("assessments enabled")
}()
