import Foundation

/// Copies everything the app prints (JSON event lines) into
/// ~/Library/Logs/RemoteMirror/<name>.log with a timestamp per line, so a
/// disconnection can be explained afterwards. Rotates at 5 MB (keeps one .1 file).
/// Output still goes to the original stdout too (tests read it there).
public enum FileLog {
    public static func url(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RemoteMirror/\(name).log")
    }

    private static var started = false

    public static func captureStdout(name: String) {
        guard !started else { return }
        started = true
        let file = url(name)
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 5_000_000 {
            let old = file.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: file, to: old)
        }
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        guard let out = try? FileHandle(forWritingTo: file) else { return }
        out.seekToEndOfFile()

        let original = dup(STDOUT_FILENO)
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        fflush(stdout)
        dup2(fds[1], STDOUT_FILENO)
        dup2(fds[1], STDERR_FILENO)
        let reader = FileHandle(fileDescriptor: fds[0], closeOnDealloc: false)
        let passthrough = FileHandle(fileDescriptor: original, closeOnDealloc: false)
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fmt.timeZone = .current
        Thread.detachNewThread {
            var pending = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                passthrough.write(chunk)
                pending.append(chunk)
                while let nl = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<nl]
                    pending = Data(pending[(nl + 1)...])
                    out.write(Data((fmt.string(from: Date()) + " ").utf8) + line + Data([0x0A]))
                }
            }
        }
        print("{\"event\":\"log_started\",\"file\":\"\(file.path)\",\"pid\":\(getpid())}")
    }
}
