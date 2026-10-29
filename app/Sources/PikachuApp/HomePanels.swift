import SwiftUI
import PikachuCore

/// The numbers across the top of the home page.
struct StatsBar: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            stat(model.counts.segments, "NOTES")
            stat(model.counts.entities, "NODES")
            stat(model.openTodos, "OPEN TO-DOS")
            stat(model.chat.filter { $0.role == "user" }.count, "MESSAGES")
        }
    }
    private func stat(_ n: Int, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(Theme.mono(28, .light))
            Text(label).font(Theme.mono(10, .bold)).tracking(Theme.track(10)).foregroundStyle(Theme.red)
        }
        .padding(.horizontal, 14).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(Color.white.opacity(0.12)))
    }
}

/// The two voice modes, as compact buttons for the header.
struct VoiceButtons: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            button(icon: "waveform", title: model.live ? "STOP TALKING" : "TALK", help: "Hands-free conversation", on: model.live) { model.onMicTap?(false) }
                .disabled(model.noteSession != nil)
            button(icon: "list.bullet.rectangle", title: model.noteSession == nil ? "START NOTE TAKING" : "STOP NOTE TAKING",
                   help: "A meeting, a call, a thought", on: model.noteSession != nil) { model.onMicTap?(true) }
                .disabled(model.live)
        }
    }
    private func button(icon: String, title: String, help: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: on ? "stop.fill" : icon).font(.system(size: 11, weight: .bold))
                Text(title).font(Theme.mono(11, .bold)).tracking(Theme.track(11))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(on ? .white : Theme.red)
            .background(on ? Theme.red : Theme.red.opacity(0.06))
            .overlay(Rectangle().stroke(Theme.red.opacity(on ? 1 : 0.6)))
            .shadow(color: on ? Theme.red.opacity(0.6) : .clear, radius: 8)
        }.buttonStyle(.plain).help(help)
    }
}

/// To-dos from what you said and saved, with a status you can change.
struct TodoPanel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                let shown = model.todos.filter { $0.status != "dropped" }
                if shown.isEmpty { Text("Nothing to do yet. Tasks from your notes and chats show up here.").font(Theme.sans(12)).foregroundStyle(Theme.dim) }
                ForEach(shown) { t in
                    HStack(alignment: .top, spacing: 8) {
                        Button { Task { await model.setTodo(t.id, status: t.status == "done" ? "open" : "done") } } label: {
                            Image(systemName: t.status == "done" ? "checkmark.square.fill" : "square").foregroundStyle(t.status == "done" ? Theme.dim : Theme.red)
                        }.buttonStyle(.plain).help(t.status == "done" ? "Mark open" : "Mark done")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.text).font(Theme.sans(13)).strikethrough(t.status == "done").foregroundStyle(t.status == "done" ? Theme.dim : Theme.white)
                            Text([t.owner, t.context.uppercased(), String(t.createdAt.prefix(10))].compactMap { $0 }.joined(separator: "  /  "))
                                .font(Theme.mono(9)).foregroundStyle(Theme.dim)
                        }
                        Spacer()
                        Button { Task { await model.setTodo(t.id, status: "dropped") } } label: { Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(Theme.dim) }
                            .buttonStyle(.plain).help("Not a task: hide it")
                    }
                }
            }.padding(12)
        }
        .task(id: model.spaces) { await model.loadTodos() }
        // Learning can finish after the answer, so new to-dos are picked up on a slow refresh.
        .task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(6)); await model.loadTodos() } }
    }
}

/// While note taking runs: how long, how much is saved, and the last lines heard.
struct NoteSessionBanner: View {
    let session: NoteSession
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(Theme.red).frame(width: 8, height: 8)
                TimelineView(.periodic(from: .now, by: 1)) { t in
                    let s = Int(t.date.timeIntervalSince(session.started))
                    Text(String(format: "NOTE TAKING  %02d:%02d", s / 60, s % 60)).font(Theme.mono(11, .bold)).tracking(Theme.track(11))
                }
                Spacer()
                Text("\(session.lines.count) LINES").font(Theme.mono(10)).foregroundStyle(Theme.dim)
            }
            ForEach(Array(session.lines.suffix(3).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(line.speaker.rawValue.uppercased()).font(Theme.mono(10, .bold)).foregroundStyle(line.speaker == .me ? Theme.red : Theme.dim)
                        .frame(width: 34, alignment: .leading)
                    Text(line.text).font(Theme.sans(13)).foregroundStyle(Theme.dim).lineLimit(2)
                }
            }
            if session.lines.isEmpty { Text("Listening to you and to the Mac's sound (a call). When you stop, Jarvis writes the meeting notes.").font(Theme.sans(13)).foregroundStyle(Theme.dim) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).hud("LIVE NOTES")
    }
}

/// Jarvis wants to do something that needs your yes.
struct ApprovalCard: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let pending = model.pendingApproval {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill").foregroundStyle(Theme.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text("JARVIS WANTS TO").font(Theme.mono(10, .bold)).tracking(Theme.track(10)).foregroundStyle(Theme.red)
                    // Every word of what you are agreeing to, never cut off: long actions scroll.
                    ScrollView {
                        Text(pending.action).font(Theme.sans(14)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 240)
                }
                Spacer()
                Button { Task { await model.answerApproval(id: pending.id, ok: false) } } label: {
                    Text("DENY").font(Theme.mono(11, .bold)).tracking(Theme.track(11)).padding(.horizontal, 14).padding(.vertical, 7).overlay(Rectangle().stroke(Theme.dim)).foregroundStyle(Theme.white)
                }.buttonStyle(.plain)
                Button { Task { await model.answerApproval(id: pending.id, ok: true) } } label: {
                    Text("ALLOW").font(Theme.mono(11, .bold)).tracking(Theme.track(11)).padding(.horizontal, 14).padding(.vertical, 7).background(Theme.red).foregroundStyle(.white)
                }.buttonStyle(.plain)
            }
            .padding(12).background(Theme.red.opacity(0.12)).overlay(Rectangle().stroke(Theme.red))
        }
    }
}

/// What Jarvis's own browser shows, and the steps it took with tools.
struct ToolActivity: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if !model.trace.tools.isEmpty { // the browser itself shows in its own window
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(model.trace.tools.suffix(4).enumerated()), id: \.offset) { _, step in
                    Text("\(step.name.replacingOccurrences(of: "_", with: " ").uppercased())  \(step.detail)").font(Theme.mono(10)).foregroundStyle(Theme.dim).lineLimit(1)
                }
            }.padding(.horizontal, 12).padding(.top, 10)
        }
    }
}
