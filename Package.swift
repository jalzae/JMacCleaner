// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "JMacCleaner",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "JMacCleaner",
            path: "Sources/JMacCleaner"
        ),
        .testTarget(
            name: "JMacCleanerTests",
            dependencies: ["JMacCleaner"],
            path: "Tests/JMacCleanerTests"
        )
    ]
)
