import SwiftUI
import PikachuCore

/// Jarvis's browser, picture-in-picture at the bottom right while it browses. Red while Jarvis is in control (watch
/// only); yellow when it hands over and needs you (log in, a code). Expand to watch or to take your turn.
struct BrowserWindow: View {
    @ObservedObject var model: AppModel
    @State private var expanded = false
    @State private var dismissedAt: Date?
    @State private var text = ""
    @State private var note = ""
    @FocusState private var pageFocused: Bool
    private static let keys: [KeyEquivalent: String] = [.return: "Enter", .tab: "Tab", .delete: "Backspace", .deleteForward: "Delete", .escape: "Escape",
        .upArrow: "ArrowUp", .downArrow: "ArrowDown", .leftArrow: "ArrowLeft", .rightArrow: "ArrowRight", .home: "Home", .end: "End", .pageUp: "PageUp", .pageDown: "PageDown"]

    private var yourTurn: Bool { model.browser.state == "needsUser" }
    private var active: Bool { model.browser.state != "idle" }
    private var tint: Color { yourTurn ? Theme.amber : Theme.red }

    var body: some View {
        Group {
            if model.browser.frame != nil && (active || dismissedAt == nil) {
                if expanded { full } else { pip }
            }
        }
        .onChange(of: model.browser.state) { _, state in
            if state != "idle" { dismissedAt = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(yourTurn ? "YOUR TURN" : active ? "JARVIS IS BROWSING" : "BROWSER").font(Theme.mono(10, .bold)).tracking(Theme.track(10)).foregroundStyle(tint)
            Text(model.browser.url).font(Theme.mono(10)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button { expanded.toggle() } label: { Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.plain).help(expanded ? "Minimise" : "Expand")
            if !active { Button { dismissedAt = Date(); expanded = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close") }
        }.padding(.horizontal, 10).padding(.vertical, 7)
    }

    /// The page. On your turn a click goes to the page at that spot and your keys type into it; otherwise it is watch only.
    private func page(_ maxHeight: CGFloat) -> some View {
        let image = model.browser.frame.flatMap { NSImage(data: $0) } ?? NSImage()
        // The click area sits on the picture itself (not the frame around it), so a spot maps to the same spot on the page.
        return Image(nsImage: image).resizable().scaledToFit()
            .overlay {
                GeometryReader { g in
                    Color.clear.contentShape(Rectangle()).gesture(SpatialTapGesture().onEnded { tap in
                        if yourTurn { pageFocused = true; Task { await model.browserClick(x: tap.location.x / g.size.width, y: tap.location.y / g.size.height) } }
                        else if !expanded { expanded = true }
                    })
                }
            }
            .focusable(yourTurn).focused($pageFocused).focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                guard yourTurn else { return .ignored }
                if let key = Self.keys[press.key] { Task { await model.browserKey(key) }; return .handled }
                guard !press.characters.isEmpty, press.modifiers.isDisjoint(with: [.command, .control]) else { return .ignored }
                let typed = press.characters
                Task { await model.browserType(typed) }
                return .handled
            }
            .frame(maxHeight: maxHeight)
            .overlay(alignment: .bottom) {
                if active && !yourTurn && expanded {
                    Text("Jarvis is in control. You can watch; you will get a turn if it needs you.").font(Theme.sans(12))
                        .padding(.horizontal, 10).padding(.vertical, 5).background(.black.opacity(0.7)).padding(8)
                }
            }
    }

    private var pip: some View {
        VStack(spacing: 0) { header; page(200) }
            .frame(width: 340)
            .background(Theme.panel)
            .overlay(Rectangle().stroke(tint, lineWidth: active ? 2 : 1))
            .shadow(color: active ? tint.opacity(0.55) : .clear, radius: 14)
            .padding(18)
    }

    private var full: some View {
        VStack(spacing: 0) {
            header
            if yourTurn {
                Text((model.browser.reason.isEmpty ? "Jarvis needs you on this page." : model.browser.reason) + "  Click the page and type, or reply in the chat.")
                    .font(Theme.sans(15, .medium)).foregroundStyle(.black).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8).background(Theme.amber)
            }
            page(.infinity)
            if yourTurn { controls }
        }
        .background(Theme.panel)
        .overlay(Rectangle().stroke(tint, lineWidth: 2))
        .shadow(color: tint.opacity(0.5), radius: 20)
        .padding(40)
    }

    /// Typing and keys for your turn. Typed text goes straight into the page and is never shown to the model.
    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                SecureField("Or paste here (click a field first)", text: $text).textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                Button("TYPE") { send() }.disabled(text.isEmpty)
                ForEach(["Enter", "Tab", "Backspace"], id: \.self) { k in Button(k.uppercased()) { Task { await model.browserKey(k) } } }
                Button { Task { await model.browserScroll(-400) } } label: { Image(systemName: "arrow.up") }
                Button { Task { await model.browserScroll(400) } } label: { Image(systemName: "arrow.down") }
            }
            HStack(spacing: 8) {
                TextField("Optional note for Jarvis (for example: logged in)", text: $note).textFieldStyle(.roundedBorder)
                Button { Task { await model.browserResume(note); note = ""; expanded = false } } label: {
                    Text("CONTINUE, JARVIS").font(Theme.mono(11, .bold)).tracking(Theme.track(11)).padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Theme.amber).foregroundStyle(.black)
                }.buttonStyle(.plain)
            }
        }
        .font(Theme.mono(10, .bold)).padding(10)
    }

    private func send() {
        let t = text
        text = ""
        Task { await model.browserType(t) }
    }
}
