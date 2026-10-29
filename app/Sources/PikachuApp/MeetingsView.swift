import SwiftUI
import MarkdownUI
import PikachuCore

/// Past note-taking sessions: each meeting's notes (summary, decisions, action items) and its whole transcript.
struct MeetingsView: View {
    @ObservedObject var model: AppModel
    @State private var selected: UUID?

    private var current: Meeting? { model.meetings.first { $0.id == selected } ?? model.meetings.first }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Theme.label("Meetings")
                if model.meetings.isEmpty {
                    Text("Start note taking in a meeting or a call. When you stop, the notes and the transcript appear here.")
                        .font(Theme.sans(13)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.meetings) { m in
                            Button { selected = m.id } label: { MeetingRow(meeting: m, on: m.id == current?.id) }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20).frame(width: 280, alignment: .topLeading)
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            if let m = current { MeetingDetail(model: model, meeting: m) } else { Spacer() }
        }
        .task { await model.loadMeetings() }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let on: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title ?? (meeting.ended == nil ? "In progress" : "Meeting")).font(Theme.sans(14, .medium)).lineLimit(2)
            HStack(spacing: 8) {
                Text(meeting.started.formatted(date: .abbreviated, time: .shortened)).font(Theme.mono(10)).foregroundStyle(Theme.dim)
                if let d = duration(meeting) { Text(d).font(Theme.mono(10)).foregroundStyle(Theme.dim) }
                if meeting.note == nil, meeting.ended != nil { Text("NO NOTES YET").font(Theme.mono(9, .bold)).foregroundStyle(Theme.amber) }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(on ? Theme.red.opacity(0.12) : Color.clear)
        .overlay(Rectangle().stroke(on ? Theme.red : Color.white.opacity(0.08)))
    }
}

private struct MeetingDetail: View {
    @ObservedObject var model: AppModel
    let meeting: Meeting
    @State private var working = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title ?? "Meeting").font(Theme.sans(22, .semibold))
                        Text("\(meeting.started.formatted(date: .complete, time: .shortened))\(duration(meeting).map { "  ·  \($0)" } ?? "")  ·  \(meeting.lines.count) lines")
                            .font(Theme.mono(11)).foregroundStyle(Theme.dim)
                    }
                    Spacer()
                    if meeting.ended != nil, !meeting.lines.isEmpty {
                        action(meeting.note == nil ? "WRITE NOTES" : "REWRITE") { working = true; await model.writeNote(meeting.id); working = false }
                            .disabled(working)
                    }
                    action("DELETE") { await model.deleteMeeting(meeting.id) }
                }
                if let note = meeting.note {
                    Markdown(note).markdownTheme(.jarvis).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).hud("NOTES")
                } else if meeting.ended != nil {
                    Text(working ? "Writing the notes…" : "No notes yet. Write them from the transcript below.").font(Theme.sans(13)).foregroundStyle(Theme.dim)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(meeting.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(line.at.formatted(date: .omitted, time: .shortened)).font(Theme.mono(10)).foregroundStyle(Theme.dim).frame(width: 60, alignment: .leading)
                            Text(line.speaker.rawValue.uppercased()).font(Theme.mono(10, .bold)).foregroundStyle(line.speaker == .me ? Theme.red : Theme.dim).frame(width: 36, alignment: .leading)
                            Text(line.text).font(Theme.sans(13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.hud("TRANSCRIPT")
            }.padding(24)
        }
    }

    private func action(_ title: String, _ run: @escaping () async -> Void) -> some View {
        Button { Task { await run() } } label: {
            Text(title).font(Theme.mono(11, .bold)).tracking(Theme.track(11)).padding(.horizontal, 12).padding(.vertical, 6)
                .overlay(Rectangle().stroke(Theme.red)).foregroundStyle(Theme.red)
        }.buttonStyle(.plain)
    }
}

private func duration(_ m: Meeting) -> String? {
    guard let end = m.ended else { return nil }
    let minutes = Int(end.timeIntervalSince(m.started) / 60)
    return minutes < 1 ? "under a minute" : minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
}
