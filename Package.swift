// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GitLabClient",
    platforms: [.macOS(.v14)],
    targets: [
        // Services, parsing and models. No UI, so it is fast to build and test.
        .target(
            name: "GitLabClientCore",
            path: "Sources/GitLabClientCore"
        ),
        // The SwiftUI app. scripts/build.sh wraps the binary into GitLab Client.app.
        .executableTarget(
            name: "GitLabClient",
            dependencies: ["GitLabClientCore"],
            path: "Sources/GitLabClient"
        ),
        .testTarget(
            name: "GitLabClientCoreTests",
            dependencies: ["GitLabClientCore"],
            path: "Tests/GitLabClientCoreTests"
        ),
    ]
)
