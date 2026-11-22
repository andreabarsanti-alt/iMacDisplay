import AppKit
import Carbon.HIToolbox
import Foundation
import HostCore
import Shared

/// State and actions behind the MacBook menu bar app.
@MainActor
final class HostAppModel: ObservableObject {
    enum Quality: String, CaseIterable, Identifiable {
        case lowLatency = "Low latency (12 Mbps)"
        case sharper = "Sharper (20 Mbps)"
        var id: String { rawValue }
        var bitrate: Int { self == .lowLatency ? 12_000_000 : 20_000_000 }
    }

    @Published private(set) var state: HostState = .idle
    @Published private(set) var statsLine = ""
    @Published private(set) var linkLine = ""
    @Published private(set) var screenRecording = HostPermissions.screenRecording()
    @Published private(set) var accessibility = HostPermissions.accessibility()
    @Published var allowControl: Bool { didSet { UserDefaults.standard.set(allowControl, forKey: "allowControl") } }
    @Published var quality: Quality { didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") } }

    private(set) var session: HostSession?
    private var timer: Timer?
    private var hotKey: EventHotKeyRef?
    var log: (String) -> Void = { print($0) }
    /// Self-test hook: forces synthetic frames (no Screen Recording needed).
    var synthetic = false
    var bindHost = WireProtocol.hostAddress
    var simulateMissingPermission: String?
    /// Self-test hook: the address the cable check looks for (simulates unplugging).
    var linkCheckAddress: String?

    init() {
        allowControl = UserDefaults.standard.object(forKey: "allowControl") as? Bool ?? true
        quality = Quality(rawValue: UserDefaults.standard.string(forKey: "quality") ?? "") ?? .lowLatency
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        observeSystem()
        registerHotKey()
    }

    var icon: String {
        switch state {
        case .idle: return "display"
        case .starting, .waiting: return "display.trianglebadge.exclamationmark"
        case .sharing: return "dot.radiowaves.left.and.right"
        case .stopping: return "hourglass"
        case .error: return "exclamationmark.triangle"
        }
    }

    // MARK: Start / stop

    func toggle() { state.isActive ? stop(reason: "stopped from menu") : start() }

    func start() {
        guard !state.isActive, state != .stopping else { return }
        let key: Data
        do { key = try LinkSecurity.loadKey() } catch {
            state = .error("No pairing key (\(error))"); return
        }
        var cfg = HostSession.Config(key: key)
        cfg.bitrate = quality.bitrate
        cfg.viewOnly = !allowControl
        cfg.allowReconnect = true          // brief drops recover; Stop / escape / unplug end the session
        cfg.synthetic = synthetic
        cfg.bindHost = bindHost
        cfg.simulateMissingPermission = simulateMissingPermission
        let s = HostSession(config: cfg)
        s.log = log
        s.onState = { [weak self] st in Task { @MainActor in self?.state = st } }
        s.onEscapeHatch = { [weak self] in Task { @MainActor in self?.stop(reason: "escape hatch on the iMac") } }
        session = s
        Task { @MainActor in try? await s.start() }
    }

    /// Stops sharing; completion runs when everything is torn down.
    func stop(reason: String, completion: (() -> Void)? = nil) {
        guard let s = session, s.state.isActive else { completion?(); return }
        s.stop(reason: reason) { completion?() }
    }

    // MARK: Status and checks

    private func tick() {
        screenRecording = HostPermissions.screenRecording()
        accessibility = HostPermissions.accessibility()
        guard let s = session else { statsLine = ""; return }
        if s.state.isActive, let problem = LinkCheck.localAddressProblem(linkCheckAddress ?? bindHost) {
            s.fail(reason: "cable unplugged (\(problem))")   // automatic stop
        }
        if s.state == .sharing {
            let snap = s.stats.snapshot(seconds: 1)
            statsLine = String(format: "iMac connected · %.0f fps · %.1f Mbps", snap.fps, snap.mbps)
        } else {
            _ = s.stats.snapshot(seconds: 1)
            statsLine = ""
        }
    }

    func checkLink() {
        linkLine = "Checking…"
        let host = bindHost
        DispatchQueue.global().async {
            var parts: [String] = []
            if let p = LinkCheck.localAddressProblem(host) { parts.append("✗ \(p)") } else { parts.append("✓ \(host) up") }
            let ping = Process()
            ping.executableURL = URL(fileURLWithPath: "/sbin/ping")
            ping.arguments = ["-c", "1", "-t", "2", WireProtocol.clientAddress]
            ping.standardOutput = FileHandle.nullDevice; ping.standardError = FileHandle.nullDevice
            try? ping.run(); ping.waitUntilExit()
            parts.append(ping.terminationStatus == 0 ? "✓ iMac answers" : "✗ iMac not reachable")
            let line = parts.joined(separator: " · ")
            DispatchQueue.main.async { self.linkLine = line }
        }
    }

    func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestPermissions() { HostPermissions.request() }

    // MARK: Automatic stop

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.session?.fail(reason: "Mac went to sleep") }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.session?.fail(reason: "screen locked") }
        }
    }

    /// Ctrl-Option-Cmd-S on the MacBook stops sharing (no permission needed).
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            let model = Unmanaged<HostAppModel>.fromOpaque(ctx!).takeUnretainedValue()
            Task { @MainActor in model.stop(reason: "MacBook hotkey Ctrl-Option-Cmd-S") }
            return noErr
        }, 1, &spec, me, nil)
        let id = EventHotKeyID(signature: OSType(0x524D_5354), id: 1)   // "RMST"
        RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey | cmdKey), id,
                            GetApplicationEventTarget(), 0, &hotKey)
    }
}
