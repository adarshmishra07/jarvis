import SwiftUI
import AVFoundation
import PikachuCore

/// What Jarvis needs to work, each with a tick or a way to fix it: the local models, the mic, the Hindi voice, the
/// helper (companion) and the API keys. Keys go to the companion, which checks them and keeps them in the Keychain.
struct SetupPanel: View {
    @ObservedObject var model: AppModel
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var drafts: [String: String] = [:]

    private static let models = [("Speech recognition (Qwen3-ASR)", "models/qwen3-asr/config.json"), ("Voice (Kokoro)", "models/kokoro/config.json"),
                                 ("Pronunciation", "models/hf")]
    private var hindiVoice: Bool { AVSpeechSynthesisVoice.speechVoices().contains { $0.language == "hi-IN" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.models, id: \.0) { name, path in
                let present = Bundle.main.resourceURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(path).path) } ?? false
                row(name, ok: present, detail: present ? "On this Mac" : "Missing: reinstall Jarvis to get it back")
            }
            row("Microphone", ok: mic == .authorized, detail: mic == .authorized ? "Allowed" : "Needed for voice and notes",
                fix: mic == .authorized ? nil : (mic == .notDetermined ? "ALLOW" : "OPEN SETTINGS")) {
                if mic == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in mic = AVCaptureDevice.authorizationStatus(for: .audio) } } }
                else { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }
            }
            row("Hindi voice", ok: hindiVoice, detail: hindiVoice ? "Installed" : "Optional: System Settings > Accessibility > Spoken Content > Manage Voices > Hindi",
                fix: hindiVoice ? nil : "OPEN SETTINGS", required: false) { open("x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") }
            row("Helper (companion)", ok: model.connected, detail: model.connected ? "Running" : "Not running: run scripts/install-app.sh, or wait a few seconds after saving a key")
            Divider().overlay(Theme.line)
            ForEach(model.setupKeys) { key in keyRow(key) }
            if model.setupKeys.isEmpty { Text("Keys show here once the helper is running.").foregroundStyle(Theme.dim).font(Theme.sans(12)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await model.loadSetup() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            mic = AVCaptureDevice.authorizationStatus(for: .audio)
            Task { await model.loadSetup() }
        }
    }

    private func keyRow(_ key: SetupKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row(key.name, ok: key.set, detail: key.purpose, required: key.required)
            HStack(spacing: 8) {
                SecureField(key.set ? "Saved. Paste a new key to replace it" : "Paste key (kept in the Keychain)", text: Binding(get: { drafts[key.name] ?? "" }, set: { drafts[key.name] = $0 }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                Button("SAVE") {
                    let value = drafts[key.name] ?? ""
                    Task { if await model.saveKey(key.name, value: value) { drafts[key.name] = nil; try? await Task.sleep(for: .seconds(12)); await model.loadSetup() } }
                }.buttonStyle(.plain).font(Theme.mono(11, .bold)).foregroundStyle(Theme.red).disabled((drafts[key.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                if key.set {
                    Button("REMOVE") { Task { if await model.saveKey(key.name, value: "") { try? await Task.sleep(for: .seconds(12)); await model.loadSetup() } } }
                        .buttonStyle(.plain).font(Theme.mono(11, .bold)).foregroundStyle(Theme.dim)
                }
            }.padding(.leading, 22)
        }
    }

    private func row(_ name: String, ok: Bool, detail: String, fix: String? = nil, required: Bool = true, action: @escaping () -> Void = {}) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : (required ? "xmark.circle.fill" : "circle"))
                .foregroundStyle(ok ? Color.green : (required ? Theme.red : Theme.dim)).frame(width: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Theme.mono(12, .bold))
                Text(detail).foregroundStyle(Theme.dim).font(Theme.sans(12)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let fix {
                Button(action: action) {
                    Text(fix).font(Theme.mono(10, .bold)).tracking(Theme.track(10)).padding(.horizontal, 10).padding(.vertical, 4).overlay(Rectangle().stroke(Theme.red)).foregroundStyle(Theme.red)
                }.buttonStyle(.plain)
            }
        }
    }

    private func open(_ link: String) { if let url = URL(string: link) { NSWorkspace.shared.open(url) } }
}
