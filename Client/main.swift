import Foundation
import Shared

// RemoteMirrorClient: runs on the iMac (x86_64). Receive/display/input capture arrive in M3+.
let args = CommandLine.arguments.dropFirst()

if args.contains("--video-caps") {
    print(VideoCapabilities.json())
    exit(0)
}

if args.contains("--verify-vectors") {
    // Reads hex lines emitted by the Host on another machine from stdin.
    let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    let failures = TestVectors.verify(input)
    if failures.isEmpty {
        print("PASS: \(TestVectors.messages.count) vectors decoded identically on \(BuildInfo.architecture)")
        exit(0)
    }
    failures.forEach { print("FAIL: \($0)") }
    exit(1)
}

print(BuildInfo.banner("RemoteMirrorClient"))
