// swift-tools-version:6.0
// Keep this at or below the OLDER toolchain of the two Macs (iMac: Swift 6.2).
import PackageDescription

let package = Package(
    name: "RemoteMirror",
    platforms: [.macOS(.v13)],   // must stay <= the iMac's macOS (15.7)
    products: [
        .executable(name: "RemoteMirrorHost", targets: ["Host"]),
        .executable(name: "RemoteMirrorClient", targets: ["Client"]),
    ],
    targets: [
        .target(name: "Shared", path: "Shared"),
        .executableTarget(name: "Host", dependencies: ["Shared"], path: "Host"),
        .executableTarget(name: "Client", dependencies: ["Shared"], path: "Client"),
        .testTarget(name: "SharedTests", dependencies: ["Shared"], path: "Tests/SharedTests"),
    ],
    swiftLanguageModes: [.v5]
)
