import Foundation
import Shared

// RemoteMirrorHost: runs on the MacBook (arm64). Capture/encode/inject arrive in M2+.
let args = CommandLine.arguments.dropFirst()

if args.contains("--video-caps") {
    print(VideoCapabilities.json())
    exit(0)
}

if args.contains("--emit-vectors") {
    print(TestVectors.emit())
    exit(0)
}

print(BuildInfo.banner("RemoteMirrorHost"))
