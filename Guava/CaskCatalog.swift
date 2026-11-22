import Foundation

/// Homebrew's cask catalogue, arranged so that an installed app can be matched to its cask.
///
/// Nothing here knows any particular app. A cask is matched on what it says about itself:
/// its token and names, the app bundle it installs, and what its uninstall and zap steps
/// remove. A wrong match would compare an app with another product's version, and could have
/// that product's download installed over it, so a claim that cannot be told from a
/// competing one counts as no match at all.
struct CaskCatalog {

    struct Cask {
        let token: String
        /// The cask's version, without Homebrew's build metadata.
        let version: String
        /// The token and the display names, lowercased.
        let names: Set<String>
        /// The bundles it installs, lowercased and without ".app".
        let apps: Set<String>
        /// The bundle in an Applications folder that its uninstall deletes, for a cask that
        /// installs from a package and so names no bundle of its own. Only when that is
        /// exactly one: a cask that removes several is a suite, whose version is not that of
        /// any one of its apps.
        let ownedApp: String?
        /// The folder in /Applications its uninstall deletes, when the cask names no bundle.
        let ownedFolder: String?
        /// What its zap step removes, as lowercased path components. The settings and caches
        /// of the cask's own app are among them, filed under that app's bundle identifier.
        let traces: Set<String>

        /// The token without its channel: "sample@beta" belongs to "sample".
        var family: String {
            token.split(separator: "@", maxSplits: 1).first.map(String.init) ?? token
        }

        /// A beta, nightly or other side channel of another cask.
        var isVariant: Bool { token.contains("@") }

        /// Whether the cask's zap step removes what an app with this bundle identifier leaves.
        func leavesTraces(of identifier: String) -> Bool {
            traces.contains(identifier) || traces.contains { $0.hasPrefix(identifier + ".") }
        }
    }

    struct Match: Equatable {
        let token: String
        let version: String
    }

    /// What the catalogue says about an installed app.
    enum Answer: Equatable {
        /// This cask is the app's.
        case match(Match)
        /// Casks of different products claim the app, and nothing says which of them it is.
        case contested
        /// No cask claims it.
        case unclaimed
    }

    /// One cask's claim on an app.
    private struct Claim {
        let index: Int
        /// The cask installs or removes this very bundle, rather than merely sharing its name.
        let isForBundle: Bool
        /// Homebrew installed the cask on this Mac.
        let isInstalled: Bool
        /// The cask's zap step carries the app's bundle identifier.
        let isIdentified: Bool
        /// The cask goes by the app's name.
        let isNamed: Bool

        /// Claims are compared on this first: the bundle, then Homebrew's own record, then
        /// the identifier.
        var strength: Int {
            (isForBundle ? 4 : 0) + (isInstalled ? 2 : 0) + (isIdentified ? 1 : 0)
        }
    }

    private var casks: [Cask] = []
    private var indexByKey: [String: [Int]] = [:]
    private var indexByFolder: [String: [Int]] = [:]
    private var indexByToken: [String: Int] = [:]

    var isEmpty: Bool { casks.isEmpty }

    init() {}

    /// - Parameter records: the array Homebrew serves at `formulae.brew.sh/api/cask.json`.
    init(records: [[String: Any]]) {
        for record in records {
            guard let cask = Self.cask(from: record) else { continue }
            let index = casks.count
            casks.append(cask)
            indexByToken[cask.token.lowercased()] = index
            for key in cask.names.union(cask.apps).union([cask.ownedApp].compactMap { $0 }) {
                indexByKey[key, default: []].append(index)
            }
            if let folder = cask.ownedFolder {
                indexByFolder[folder, default: []].append(index)
            }
        }
    }

    /// The cask with exactly this token.
    func cask(withToken token: String) -> Match? {
        indexByToken[token.lowercased()].map(match)
    }

    /// Finds the cask that claims an installed app.
    ///
    /// - Parameters:
    ///   - name: the app's display name.
    ///   - path: where its bundle is.
    ///   - bundleIdentifier: the app's bundle identifier.
    ///   - installedVersion: the version on disk, without build metadata.
    ///   - installedTokens: the casks Homebrew has installed on this Mac.
    ///   - isOnlyAppInFolder: whether the bundle is the only app in its folder.
    func lookUp(
        name: String,
        path: String,
        bundleIdentifier: String? = nil,
        installedVersion: String? = nil,
        installedTokens: Set<String> = [],
        isOnlyAppInFolder: () -> Bool = { false }
    ) -> Answer {
        let display = name.lowercased()
        let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        let folder = (path as NSString).deletingLastPathComponent.lowercased()
        let spellings: Set<String> = [display, file, Self.hyphenated(display), Self.hyphenated(file)]
        let identifier = bundleIdentifier?.lowercased()

        var candidates = Set(spellings.flatMap { indexByKey[$0] ?? [] })
        let folderOwners = Set(indexByFolder[folder] ?? [])
        // Looking inside the folder is only worth it when a cask claims that folder.
        let isAloneInOwnedFolder = !folderOwners.isEmpty && isOnlyAppInFolder()
        if isAloneInOwnedFolder {
            candidates.formUnion(folderOwners)
        }

        let claims = candidates.compactMap { index -> Claim? in
            let cask = casks[index]
            let isIdentified = identifier.map(cask.leavesTraces(of:)) ?? false
            let installs = cask.apps.contains(file)
            // What an uninstall removes may be a companion of the cask's app rather than the
            // app itself. It counts only when the cask's own traces carry this app's identifier.
            let removes = isIdentified
                && (cask.ownedApp == file || (isAloneInOwnedFolder && folderOwners.contains(index)))
            let isNamed = !cask.names.isDisjoint(with: spellings)
            // A bundle that was renamed on disk still shows the name the cask installs it under.
            guard installs || removes || isNamed || cask.apps.contains(display) else { return nil }
            return Claim(
                index: index,
                isForBundle: installs || removes,
                isInstalled: installedTokens.contains(cask.token),
                isIdentified: isIdentified,
                isNamed: isNamed
            )
        }
        guard let strongest = claims.map(\.strength).max() else { return .unclaimed }
        return settle(claims.filter { $0.strength == strongest }, installedVersion: installedVersion)
    }

    /// Chooses between claims of equal strength, or finds that there is no choosing.
    private func settle(_ claims: [Claim], installedVersion: String?) -> Answer {
        let families = Set(claims.map { casks[$0.index].family })
        var pool = claims
        if families.count == 1 {
            // Channels of one product. The one whose current version continues the line the
            // installed copy is on is the app's own: an extended-support build is not to be
            // compared with the main release, or replaced by it.
            let onTheSameLine = claims.filter { continuesLine(of: installedVersion, casks[$0.index].version) }
            if !onTheSameLine.isEmpty {
                pool = onTheSameLine
            }
        } else {
            // Different products. When they disagree about the latest version, nothing says
            // which one this app is. When they agree, they are only taken for one another if
            // one is plainly an edition of the other, as "sample-for-teams" is of "sample".
            let versions = Set(claims.map { casks[$0.index].version })
            guard versions.count == 1, Self.areEditionsOfOne(families) else { return .contested }
        }

        let best = pool.min { first, second in
            if first.isNamed != second.isNamed { return first.isNamed }
            let (a, b) = (casks[first.index], casks[second.index])
            if a.isVariant != b.isVariant { return !a.isVariant }
            if a.token.count != b.token.count { return a.token.count < b.token.count }
            return a.token < b.token
        }
        return best.map { .match(match($0.index)) } ?? .unclaimed
    }

    private func match(_ index: Int) -> Match {
        Match(token: casks[index].token, version: casks[index].version)
    }

    /// Whether `latest` could be a later release of what is installed: the same major version,
    /// and not older.
    private func continuesLine(of installed: String?, _ latest: String) -> Bool {
        guard let installed, let major = Self.major(of: installed), major == Self.major(of: latest) else {
            return false
        }
        return VersionChecker.compareVersions(installed, latest) != .orderedDescending
    }

    private static func major(of version: String) -> Int? {
        Int(version.prefix { $0.isNumber })
    }

    /// Whether every one of these tokens is the shortest of them with something added.
    private static func areEditionsOfOne(_ families: Set<String>) -> Bool {
        guard let base = families.min(by: { $0.count < $1.count }) else { return false }
        return families.allSatisfy { $0 == base || $0.hasPrefix(base + "-") }
    }

    /// "Sample Editor" and "sample.editor" as a cask token would spell them.
    static func hyphenated(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    // MARK: - Reading a record

    /// The kinds of artifact that put an application on the Mac. A cask with none of them, a
    /// font or a command-line tool for instance, has nothing to do with an installed app,
    /// whatever it is called.
    private static let applicationArtifacts: Set<String> = ["app", "pkg", "installer", "suite"]

    private static func cask(from record: [String: Any]) -> Cask? {
        guard let token = record["token"] as? String,
              let version = record["version"] as? String else { return nil }
        let artifacts = (record["artifacts"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        guard artifacts.contains(where: { !applicationArtifacts.isDisjoint(with: $0.keys) }) else {
            return nil
        }

        var names: Set<String> = [token.lowercased()]
        for name in record["name"] as? [String] ?? [] {
            names.insert(name.lowercased())
        }

        var apps: Set<String> = []
        var deleted: [String] = []
        var traces: Set<String> = []
        for artifact in artifacts {
            if let entry = artifact["app"] as? [Any] {
                // A bundle that is renamed on installation is known by the name it ends up
                // with. Its original name is often that of another channel's bundle.
                let target = entry.compactMap { ($0 as? [String: Any])?["target"] as? String }.first
                let installed = target.map { [$0] } ?? entry.compactMap { $0 as? String }
                apps.formUnion(installed.compactMap(bundleName))
            }
            for step in steps(artifact["uninstall"]) {
                deleted.append(contentsOf: strings(step["delete"]))
            }
            for step in steps(artifact["zap"]) {
                for path in ["trash", "delete", "rmdir"].flatMap({ strings(step[$0]) }) {
                    for component in path.lowercased().split(separator: "/") {
                        traces.insert(component.hasSuffix("*") ? String(component.dropLast()) : String(component))
                    }
                }
            }
        }

        let deletedApps = Set(deleted.filter(isInApplications).compactMap(bundleName))
        let deletedFolders = Set(deleted.compactMap(applicationsFolder))
        return Cask(
            token: token,
            version: VersionChecker.cleanVersion(version),
            names: names,
            apps: apps,
            ownedApp: apps.isEmpty && deletedApps.count == 1 ? deletedApps.first : nil,
            ownedFolder: apps.isEmpty && deletedApps.isEmpty && deletedFolders.count == 1 ? deletedFolders.first : nil,
            traces: traces
        )
    }

    private static func steps(_ value: Any?) -> [[String: Any]] {
        (value as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    private static func strings(_ value: Any?) -> [String] {
        if let string = value as? String { return [string] }
        return (value as? [Any] ?? []).compactMap { $0 as? String }
    }

    /// "Sample.app" and "/Applications/Sample.app" give "sample". Nil for anything that is not
    /// one bundle.
    private static func bundleName(_ path: String) -> String? {
        let file = (path as NSString).lastPathComponent
        guard file.lowercased().hasSuffix(".app"), !path.contains("*") else { return nil }
        return (file as NSString).deletingPathExtension.lowercased()
    }

    /// Whether a path lies in one of the folders Guava looks for applications in.
    private static func isInApplications(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.hasPrefix("/applications/") || lowered.hasPrefix("~/applications/")
    }

    /// "/Applications/Sample Suite" gives itself, lowercased. Nil for any other path.
    private static func applicationsFolder(_ path: String) -> String? {
        let folder = path.hasSuffix("/") ? String(path.dropLast()) : path
        let lowered = folder.lowercased()
        guard lowered.hasPrefix("/applications/"), !lowered.hasSuffix(".app"), !lowered.contains("*"),
              (lowered as NSString).pathComponents.count == 3 else { return nil }
        return lowered
    }
}
