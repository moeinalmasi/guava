// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Guava",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Guava",
            path: "Guava"
        )
    ],
    swiftLanguageModes: [.v5]
)
