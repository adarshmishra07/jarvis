import SwiftUI
import AppKit
import LocalAuthentication
import PikachuCore

@MainActor
final class Brain: ObservableObject {
    let model = AppModel(api: CompanionClient(socketPath: NSHomeDirectory() + "/companion.sock"),
                         // Snapshot runs (a debug aid) get their own chat, so they never show or touch yours.
                         store: ChatStore(directory: URL.applicationSupportDirectory.appendingPathComponent(UserDefaults.standard.string(forKey: "snapshot") == nil ? "chats" : "chats-snapshot")),
                         meetings: MeetingStore(directory: URL.applicationSupportDirectory.appendingPathComponent(UserDefaults.standard.string(forKey: "snapshot") == nil ? "meetings" : "meetings-snapshot")))
    private var voice: VoiceController?
    private var notifier: Notifier?
    init() {
        Theme.registerFonts()
        // Speech front-end files ship inside the app; point the model library there so it never downloads.
        if let hf = Bundle.main.resourceURL?.appendingPathComponent("models/hf").path { setenv("HF_HUB_CACHE", hf, 1) }
        voice = VoiceController(model: model)
        // The companion link lives as long as the app, not the window: closing it keeps approvals, tasks and updates.
        let model = self.model
        Task { while !Task.isCancelled { await model.refreshStatus(); try? await Task.sleep(for: .seconds(3)) } }
        Task { await model.watchBrowser() }
        Task { await model.watchTasks() }
        if UserDefaults.standard.string(forKey: "snapshot") == nil {
            OpenAtLogin.enableOnFirstLaunch()
            let notifier = Notifier(model: model)
            self.notifier = notifier
            model.onReminder = { [weak voice] id, text in notifier.post(id: id, text: text); voice?.announce(text) }
        }
        model.openURL = { NSWorkspace.shared.open($0) } // Composio's sign-in opens in your normal browser
        model.authorize = { reason in
            // Touch ID, or the Mac password when Touch ID is not available.
            (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        }
    }
}

/// Closing the window keeps Jarvis running in the menu bar (listening, note taking, the companion link).
final class StayOpen: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct PikachuApp: App {
    @NSApplicationDelegateAdaptor(StayOpen.self) private var stayOpen
    @StateObject private var brain = Brain()
    private var model: AppModel { brain.model }
    /// Large enough that nothing looks broken, but never larger than a small screen.
    static var minSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: min(1180, screen.width * 0.95), height: min(760, screen.height * 0.92))
    }

    var body: some Scene {
        WindowGroup("Mission Control", id: "main") {
            MissionControl(model: model).frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
                .ignoresSafeArea(.all, edges: .top)
                // In the Dock only while this window is open, like other menu bar apps: closed, Jarvis keeps listening
                // from the menu bar and nothing in the Dock invites quitting it.
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); Snapshot.scheduleIfRequested(model: model) }
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }
        .windowStyle(.hiddenTitleBar)
        MenuBarExtra { StatusMenu(model: model) } label: { MenuIcon(model: model) }
    }
}
