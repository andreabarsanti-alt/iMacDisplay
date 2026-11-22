import AppKit
import HostCore
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
        Button(model.state.isActive ? "Stop Sharing" : "Start Sharing") { model.toggle() }
            .keyboardShortcut("s")
            .disabled(model.state == .stopping)
        Text(model.state.label)
        if !model.statsLine.isEmpty { Text(model.statsLine) }
        Divider()
        Toggle("Allow keyboard & mouse control", isOn: $model.allowControl)
            .disabled(model.state.isActive)
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
        if !model.linkLine.isEmpty { Text(model.linkLine) }
        Divider()
        Text("Stop anytime: Ctrl-Option-Cmd-S")
        Button("Quit RemoteMirror") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
