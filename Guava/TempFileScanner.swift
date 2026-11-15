import Foundation

/// Scans macOS temporary and cache directories for files that can be safely deleted
struct TempFileScanner {
    
    /// All directories to scan for temporary/cache files
    private static var scanDirectories: [(URL, TempFileCategory)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            (home.appendingPathComponent("Library/Caches"), .cache),
            (home.appendingPathComponent("Library/Logs"), .logs),
            (home.appendingPathComponent("Library/Application Support/CrashReporter"), .crashReports),
            (URL(fileURLWithPath: "/tmp"), .tempFiles),
            (URL(fileURLWithPath: "/private/var/folders"), .tempFiles),
        ]
    }
    
    /// Scan all known temp/cache locations and return file entries
    static func scan() -> [TempFileInfo] {
        var results: [TempFileInfo] = []
        let fm = FileManager.default
        
        for (directory, category) in scanDirectories {
            guard fm.fileExists(atPath: directory.path) else { continue }
            
            switch category {
            case .cache, .logs, .crashReports:
                results.append(contentsOf: scanAppSubdirectories(at: directory, category: category))
            case .tempFiles:
                results.append(contentsOf: scanFlatDirectory(at: directory, category: category))
            }
        }
        
        return results.sorted { $0.size > $1.size }
    }
    
    /// Scan a directory where each subdirectory represents an app (e.g. ~/Library/Caches/<AppName>/)
    private static func scanAppSubdirectories(at directory: URL, category: TempFileCategory) -> [TempFileInfo] {
        let fm = FileManager.default
        var results: [TempFileInfo] = []
        
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return results
        }
        
        for item in contents {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            
            if isDir {
                let dirSize = directorySize(at: item)
                if dirSize > 0 {
                    let appName = friendlyAppName(from: item.lastPathComponent)
                    results.append(TempFileInfo(
                        fileName: item.lastPathComponent,
                        appName: appName,
                        path: item.path,
                        size: dirSize,
                        category: category,
                        isCritical: isCritical(path: item.path, fileName: item.lastPathComponent)
                    ))
                }
            } else {
                let fileSize = (try? fm.attributesOfItem(atPath: item.path)[.size] as? Int64) ?? 0
                if fileSize > 0 {
                    results.append(TempFileInfo(
                        fileName: item.lastPathComponent,
                        appName: friendlyAppName(from: item.lastPathComponent),
                        path: item.path,
                        size: fileSize,
                        category: category,
                        isCritical: isCritical(path: item.path, fileName: item.lastPathComponent)
                    ))
                }
            }
        }
        
        return results
    }
    
    /// Scan a flat temp directory (e.g. /tmp/)
    private static func scanFlatDirectory(at directory: URL, category: TempFileCategory) -> [TempFileInfo] {
        let fm = FileManager.default
        var results: [TempFileInfo] = []
        
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return results
        }
        
        for item in contents {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size: Int64
            
            if isDir {
                size = directorySize(at: item)
            } else {
                size = (try? fm.attributesOfItem(atPath: item.path)[.size] as? Int64) ?? 0
            }
            
            if size > 0 {
                results.append(TempFileInfo(
                    fileName: item.lastPathComponent,
                    appName: "System",
                    path: item.path,
                    size: size,
                    category: category,
                    isCritical: isCritical(path: item.path, fileName: item.lastPathComponent)
                ))
            }
        }
        
        return results
    }
    
    /// Calculate total size of a directory recursively
    private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize else { continue }
            total += Int64(fileSize)
        }
        return total
    }
    
    /// Paths and directory names that are critical to system operation and should not be deleted
    private static let criticalPaths: Set<String> = [
        "/tmp/com.apple.launchd",
        "/tmp/com.apple.security",
        "/tmp/powerlog",
        "/private/var/folders",
    ]
    
    private static let criticalNames: Set<String> = [
        "com.apple.LaunchServices",
        "com.apple.bird",
        "com.apple.nsurlsessiond",
        "com.apple.Spotlight",
        "com.apple.DiskManagement",
        "com.apple.coreservices",
        "com.apple.iconservices",
        "com.apple.kernel",
        "com.apple.launchd",
        "com.apple.xpc",
        "com.apple.sandbox",
        "com.apple.appkit",
        "CloudKit",
        "FamilyCircle",
        "com.apple.mediaanalysisd",
        "com.apple.SecurityServer",
    ]
    
    /// Check if a temp file entry is critical to system operation
    static func isCritical(path: String, fileName: String) -> Bool {
        if criticalPaths.contains(path) { return true }
        for critical in criticalPaths where path.hasPrefix(critical + "/") { return true }
        if criticalNames.contains(fileName) { return true }
        return false
    }
    
    /// Convert a bundle identifier or directory name to a friendly app name
    private static func friendlyAppName(from dirName: String) -> String {
        // If it looks like a bundle ID (e.g. com.apple.Safari), extract the last component
        if dirName.contains(".") && dirName.split(separator: ".").count >= 3 {
            let lastPart = dirName.split(separator: ".").last.map(String.init) ?? dirName
            // Capitalize first letter
            return lastPart.prefix(1).uppercased() + lastPart.dropFirst()
        }
        return dirName
    }
    
    /// Delete a temporary file or directory
    static func deleteItem(at path: String) -> Bool {
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            print("Failed to delete \(path): \(error.localizedDescription)")
            return false
        }
    }
}
