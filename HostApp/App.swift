import AppKit
import HostCore
import Shared
import SwiftUI

/// RemoteMirror for the MacBook: a menu bar app (no Dock icon). Sharing is started
/// and stopped here; nothing listens while Idle, and it never starts by itself.
@main
struct RemoteMirrorHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            MenuLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor lazy var model = HostAppModel()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let selfTest = CommandLine.arguments.contains { $0.hasPrefix("--self-test") || $0.hasSuffix("-permissions") }
        if !selfTest { FileLog.captureStdout(name: "MacBook") }
        Task { @MainActor in SelfTest.runIfRequested(model) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            model.stop(reason: "app quit") { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}

struct MenuLabel: View {
    @ObservedObject var model: HostAppModel
    var body: some View { Image(systemName: model.icon) }
}

struct MenuContent: View {
    @ObservedObject var model: HostAppModel

    var body: some View {
        if let u = model.update {
            Button("Update available: \(u.version) — Download…") { model.openUpdate() }
            Divider()
        }
        Button(model.state.isActive ? "Stop Sharing" : "Start Sharing") { model.toggle() }
            .keyboardShortcut("s")
            .disabled(model.state == .stopping)
        Text(model.state.label)
        if !model.statsLine.isEmpty { Text(model.statsLine) }
        if !model.versionProblem.isEmpty { Text(model.versionProblem) }
        if !model.state.isActive && !model.lastStopLine.isEmpty { Text(model.lastStopLine) }
        Divider()
        Toggle("Allow keyboard & mouse control", isOn: $model.allowControl)
            .disabled(model.state.isActive)
        Picker("Share display", selection: $model.displayChoice) {
            ForEach(DisplayChoice.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .disabled(model.state.isActive)
        Toggle("Fit external display to iMac (16:9)", isOn: $model.fitForIMac)
            .disabled(model.state.isActive)
        Picker("5K frame rate", selection: $model.fps5K) {
            Text("30 fps (less lag)").tag(30)
            Text("60 fps (smoother, more lag)").tag(60)
        }
        .disabled(model.state.isActive)
        if !model.displaysLine.isEmpty { Text(model.displaysLine) }
        Picker("Quality", selection: $model.quality) {
            ForEach(HostAppModel.Quality.allCases) { Text($0.rawValue).tag($0) }
        }
        .disabled(model.state.isActive)
        Divider()
        Menu("Permissions") {
            Button((model.screenRecording ? "✓" : "✗") + " Screen Recording…") { model.openPrivacyPane("Privacy_ScreenCapture") }
            Button((model.accessibility ? "✓" : "✗") + " Accessibility…") { model.openPrivacyPane("Privacy_Accessibility") }
            if !model.screenRecording || !model.accessibility {
                Button("Ask for missing permissions") { model.requestPermissions() }
            }
        }
        Button("Check link") { model.checkLink() }
        Button("Open log") { model.openLog() }
        if !model.linkLine.isEmpty { Text(model.linkLine) }
        Divider()
        Text("Stop anytime: Ctrl-Option-Cmd-S")
        Button("Quit RemoteMirror") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
