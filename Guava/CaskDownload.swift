import Foundation

/// The download Homebrew publishes for a cask on one platform.
struct CaskDownload: Equatable, Sendable {
    let token: String
    let version: String
    let url: String
    /// Nil when the cask does not pin a checksum.
    let sha256: String?
    let homepage: String?
}

/// The Mac this process is running on.
enum HostPlatform {
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static var macOSMajorVersion: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    static var macOSVersionString: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

/// Picks the download for a platform out of a Homebrew cask API record.
///
/// The record's top level describes the newest macOS on Apple silicon. `variations` lists only
/// the platforms whose values differ: Intel entries are keyed by the macOS codename and older
/// Apple silicon entries by `arm64_<codename>`.
enum CaskDownloadResolver {

    private static let codenames: [Int: String] = [
        11: "big_sur",
        12: "monterey",
        13: "ventura",
        14: "sonoma",
        15: "sequoia",
        26: "tahoe",
        27: "golden_gate",
    ]

    static func codename(forMajorVersion major: Int) -> String? {
        codenames[major]
    }

    static func resolve(
        cask: [String: Any],
        architecture: String = HostPlatform.architecture,
        macOSMajorVersion: Int = HostPlatform.macOSMajorVersion
    ) -> CaskDownload? {
        guard let token = cask["token"] as? String,
              var version = cask["version"] as? String,
              var url = cask["url"] as? String else {
            return nil
        }
        var sha256 = cask["sha256"] as? String

        let variations = cask["variations"] as? [String: [String: Any]] ?? [:]
        let isAppleSilicon = architecture == "arm64"
        let codename = codename(forMajorVersion: macOSMajorVersion)
        let key = codename.map { isAppleSilicon ? "arm64_\($0)" : $0 }

        if let key, let variation = variations[key] {
            url = variation["url"] as? String ?? url
            version = variation["version"] as? String ?? version
            if variation["sha256"] != nil {
                sha256 = variation["sha256"] as? String
            }
        } else if !isAppleSilicon, codename == nil {
            // An Intel Mac on a macOS release this build does not know: if the cask ships
            // Intel-specific downloads there is no way to tell which one applies.
            let hasIntelVariation = variations.keys.contains {
                !$0.hasPrefix("arm64_") && !$0.hasSuffix("_linux")
            }
            if hasIntelVariation { return nil }
        }

        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }

        if let checksum = sha256, !isValidSHA256(checksum) {
            sha256 = nil
        }

        return CaskDownload(
            token: token,
            version: version,
            url: url,
            sha256: sha256,
            homepage: cask["homepage"] as? String
        )
    }

    /// Homebrew writes `no_check` when a cask's download has no stable checksum.
    private static func isValidSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}
