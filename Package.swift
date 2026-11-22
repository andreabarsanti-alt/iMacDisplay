// swift-tools-version:6.0
// Keep this at or below the OLDER toolchain of the two Macs (iMac: Swift 6.2).
import PackageDescription

let package = Package(
    name: "RemoteMirror",
    platforms: [.macOS(.v13)],   // must stay <= the iMac's macOS (15.7)
    products: [
        .executable(name: "RemoteMirrorHost", targets: ["Host"]),
        .executable(name: "RemoteMirrorClient", targets: ["Client"]),
        .executable(name: "RemoteMirrorHostApp", targets: ["HostApp"]),
    ],
    targets: [
        .target(name: "Shared", path: "Shared"),
        .target(name: "HostCore", dependencies: ["Shared"], path: "HostCore"),
        .executableTarget(name: "Host", dependencies: ["Shared", "HostCore"], path: "Host"),
        .executableTarget(name: "HostApp", dependencies: ["Shared", "HostCore"], path: "HostApp"),
        .executableTarget(name: "Client", dependencies: ["Shared"], path: "Client"),
        .testTarget(name: "SharedTests", dependencies: ["Shared"], path: "Tests/SharedTests"),
        .testTarget(name: "HostCoreTests", dependencies: ["HostCore", "Shared"], path: "Tests/HostCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
