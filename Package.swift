// swift-tools-version: 6.0
import Foundation
import PackageDescription

// With only the Command Line Tools installed, the Swift 6.4 build system intermittently leaves
// out the compiler plugin search path, and Swift Testing's macros then fail to expand with
// "plugin for module 'TestingMacros' not found". Naming the path makes test builds repeatable.
// Xcode's toolchain finds its own copy and is left alone so the two are never mixed.
let commandLineTools = "/Library/Developer/CommandLineTools"

let activeDeveloperDirectory: String = {
    if let override = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !override.isEmpty {
        return override
    }
    if let selected = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
        return selected
    }
    let xcode = "/Applications/Xcode.app/Contents/Developer"
    return FileManager.default.fileExists(atPath: xcode) ? xcode : commandLineTools
}()

let testingPlugins = commandLineTools + "/usr/lib/swift/host/plugins/testing"

let testSettings: [SwiftSetting] =
    activeDeveloperDirectory.hasPrefix(commandLineTools) && FileManager.default.fileExists(atPath: testingPlugins)
        ? [.unsafeFlags(["-plugin-path", testingPlugins])]
        : []

let package = Package(
    name: "Guava",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Guava",
            path: "Guava"
        ),
        .testTarget(
            name: "GuavaTests",
            dependencies: ["Guava"],
            path: "Tests/GuavaTests",
            swiftSettings: testSettings
        )
    ],
    swiftLanguageModes: [.v5]
)
