import SwiftUI
import PikachuCore

/// Connect apps through Composio: one row per app (Google apps grouped), each account listed under it.
struct ConnectorsList: View {
    @ObservedObject var model: AppModel
    @State private var renaming: (app: String, account: String)?
    @State private var newLabel = ""

    private static let icons = ["gmail": "envelope", "googlecalendar": "calendar", "googledrive": "folder", "googledocs": "doc.text",
                                "googlesheets": "tablecells", "slack": "number", "linear": "line.3.horizontal.decrease", "notion": "n.square",
                                "github": "chevron.left.forwardslash.chevron.right", "jira": "checklist", "outlook": "envelope.badge",
                                "discord": "bubble.left.and.bubble.right", "hubspot": "person.2", "figma": "pencil.and.ruler", "zoom": "video",
                                "calendly": "calendar.badge.clock"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connectors").font(Theme.sans(24, .semibold))
                Text("Apps Jarvis can use. It reads on its own; sending, creating or deleting always asks you first.").font(Theme.sans(13)).foregroundStyle(Theme.dim)
            }.padding(.bottom, 14)
            Rectangle().fill(Color.white.opacity(0.25)).frame(height: 1)
            switch model.apps {
            case nil: Text("Loading...").foregroundStyle(Theme.dim).padding(.vertical, 16)
            case let apps? where apps.isEmpty: Text("Add your Composio key to connect apps.").foregroundStyle(Theme.dim).padding(.vertical, 16)
            case let apps?:
                let google = apps.filter { $0.group == "Google Workspace" }
                if !google.isEmpty {
                    groupHeader("Google Workspace", "Gmail, Calendar, Drive, Docs and Sheets", icon: "g.circle")
                    ForEach(google) { row($0, indent: true) }
                }
                ForEach(apps.filter { $0.group.isEmpty }) { row($0, indent: false) }
            }
        }
        .task { await model.loadApps() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await model.loadApps() } } // back from signing in
        .alert("Label this account", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("work, personal...", text: $newLabel)
            Button("Save") { if let r = renaming { Task { await model.rename(app: r.app, account: r.account, to: newLabel) } }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func groupHeader(_ name: String, _ about: String, icon: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 22)).frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(Theme.sans(15, .semibold))
                Text(about).font(Theme.sans(13)).foregroundStyle(Theme.dim)
            }
            Spacer()
        }.padding(.vertical, 14)
    }

    private func row(_ app: AppRow, indent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: Self.icons[app.slug] ?? "app").font(.system(size: indent ? 16 : 22)).frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.system(size: indent ? 14 : 15, weight: .semibold))
                    Text(app.about).font(Theme.sans(13)).foregroundStyle(Theme.dim)
                }
                Spacer()
                button(app)
            }.padding(.vertical, 12).padding(.leading, indent ? 34 : 0)
            ForEach(app.accounts) { acct in
                HStack {
                    Text(acct.label.isEmpty ? "Account" : acct.label).font(Theme.sans(13))
                    if acct.status != "ACTIVE" {
                        Text(acct.status == "FAILED" ? "SIGN-IN FAILED" : "SIGN-IN NOT FINISHED").font(Theme.mono(10, .bold)).tracking(Theme.track(10)).foregroundStyle(Theme.dim)
                    }
                    Spacer()
                    Menu {
                        Button("Label...") { newLabel = acct.alias; renaming = (app.slug, acct.id) }
                        Button("Remove", role: .destructive) { Task { await model.remove(app: app.slug, account: acct.id) } }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                }.padding(.vertical, 8).padding(.leading, (indent ? 34 : 0) + 50)
            }
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    private func button(_ app: AppRow) -> some View {
        Button { Task { await model.connect(app: app.slug) } } label: {
            Text(app.connected ? "Add account" : "Connect").font(Theme.sans(13, .medium)).padding(.horizontal, 16).padding(.vertical, 7)
                .background(app.connected ? Color.clear : Theme.red).foregroundStyle(app.connected ? Theme.white : .white)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(app.connected ? Color.white.opacity(0.3) : Theme.red))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
    }
}
