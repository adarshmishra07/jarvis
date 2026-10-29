import SwiftUI
import ServiceManagement
import PikachuCore

/// The menu bar icon: what Jarvis is doing right now, and quick controls. The app keeps running here when its window
/// is closed.
struct StatusMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var atLogin = OpenAtLogin.isOn

    var body: some View {
        Text(model.connected ? "Companion online" : "Companion offline")
        Text(model.noteSession != nil ? "Taking notes" : model.live ? "Hands-free talk on" : model.asking ? "Thinking" : model.wakeWord ? "Listening for \"Hey Jarvis\"" : "Standing by")
        let running = model.tasks.filter { $0.status == "running" }.count
        if running > 0 { Text("\(running) background task\(running == 1 ? "" : "s") running") }
        if model.waitingForYou { Text("Jarvis needs you: \(model.browser.reason)") }
        else if model.browser.state == "working" { Text("Browsing") }
        Divider()
        Button("Open Mission Control") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button(model.live ? "Stop Talking" : "Talk") { model.onMicTap?(false) }.disabled(model.noteSession != nil)
        Button(model.noteSession == nil ? "Start Note Taking" : "Stop Note Taking") { model.onMicTap?(true) }.disabled(model.live)
        // A request for your yes is answerable here too, with the window closed.
        if let pending = model.pendingApproval {
            Divider()
            Text("Jarvis wants to: \(pending.action)")
            Button("Allow") { Task { await model.answerApproval(id: pending.id, ok: true) } }
            Button("Deny") { Task { await model.answerApproval(id: pending.id, ok: false) } }
        }
        if let u = model.update, u.ready {
            Divider()
            Button("Install Update (\(u.notes.count) change\(u.notes.count == 1 ? "" : "s"))") { Task { await model.installUpdate() } }
        }
        Divider()
        Toggle("Listen for \"Hey Jarvis\" (while unlocked)", isOn: $model.wakeWord)
        Toggle("Open at Login", isOn: Binding(get: { atLogin }, set: { atLogin = OpenAtLogin.set($0) }))
        Button("Quit Jarvis") { NSApplication.shared.terminate(nil) }
    }

    /// The icon shows the state at a glance.
    static func icon(_ model: AppModel) -> String {
        model.pendingApproval != nil || model.waitingForYou ? "exclamationmark.bubble.fill" : model.noteSession != nil ? "record.circle" : model.live ? "waveform" : model.asking ? "ellipsis.circle" : "bolt.fill"
    }
}

/// The menu bar icon itself, redrawn as the state changes.
struct MenuIcon: View {
    @ObservedObject var model: AppModel
    var body: some View { Image(systemName: StatusMenu.icon(model)) }
}

/// Starting with the Mac. On by default the first time; the switch in the menu changes it.
enum OpenAtLogin {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns whether it is on afterwards (macOS may ask you to allow it in System Settings).
    @discardableResult static func set(_ on: Bool) -> Bool {
        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        return isOn
    }

    static func enableOnFirstLaunch() {
        // Already on: register again, so the login item follows the app if it moved (Pikachu.app became Jarvis.app).
        guard !UserDefaults.standard.bool(forKey: "openAtLoginChosen") else { if isOn { try? SMAppService.mainApp.register() }; return }
        UserDefaults.standard.set(true, forKey: "openAtLoginChosen")
        set(true)
    }
}
