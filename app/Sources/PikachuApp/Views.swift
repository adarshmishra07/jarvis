import UniformTypeIdentifiers
import SwiftUI
import MarkdownUI
import PikachuCore

enum Section: String, CaseIterable, Identifiable {
    case ask = "Ask", meetings = "Meetings", memory = "Memory", graph = "Graph", ledger = "Ledger", settings = "Settings"
    var id: String { rawValue }
    var number: String { String(format: "%02d", (Section.allCases.firstIndex(of: self) ?? 0) + 1) }
}

struct MissionControl: View {
    @ObservedObject var model: AppModel
    @State private var section: Section = Section(rawValue: UserDefaults.standard.string(forKey: "snapshot") ?? "") ?? .ask

    var body: some View {
        ZStack {
            HUDBackground()
            VStack(spacing: 0) {
                TopBar(model: model)
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Theme.label("Modules").padding(.bottom, 10)
                        ForEach(Section.allCases) { s in
                            Button { section = s } label: {
                                HStack(spacing: 10) {
                                    Text(s.number).font(Theme.mono(10)).foregroundStyle(section == s ? .white : Theme.red)
                                    Text(s.rawValue.uppercased()).font(Theme.mono(13, .semibold)).tracking(Theme.track(13))
                                    Spacer()
                                }
                                .padding(.vertical, 10).padding(.horizontal, 12)
                                .foregroundStyle(section == s ? Color.white : Theme.dim)
                                .background(section == s ? Theme.red.opacity(0.85) : Color.clear)
                                .overlay(Rectangle().stroke(section == s ? Theme.red : Color.white.opacity(0.08)))
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("LOCAL ONLY").font(Theme.mono(10, .semibold)).tracking(Theme.track(10)).foregroundStyle(Theme.red)
                            Text("Notes stay on this Mac.").font(Theme.sans(11)).foregroundStyle(Theme.dim)
                        }
                    }
                    .padding(16).frame(width: 200)
                    Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                    Group {
                        switch section {
                        case .ask: AskView(model: model)
                        case .meetings: MeetingsView(model: model)
                        case .memory: MemoryView(model: model)
                        case .graph: GraphView(model: model)
                        case .ledger: LedgerView(model: model)
                        case .settings: SettingsView(model: model)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .foregroundStyle(Theme.white).preferredColorScheme(.dark)
        .overlay(alignment: .bottomTrailing) { BrowserWindow(model: model) } // Jarvis's browser, over every screen
        .environmentObject(model) // answer images load through the model

    }
}

struct TopBar: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                Text("AGENT").font(Theme.mono(14, .bold)).tracking(Theme.track(14))
                Text("JARVIS").font(Theme.mono(14, .bold)).tracking(Theme.track(14)).foregroundStyle(Theme.red)
            }
            Rectangle().fill(Theme.red).frame(width: 1, height: 16)
            Text("MISSION CONTROL").font(Theme.mono(10)).tracking(Theme.track(10)).foregroundStyle(Theme.dim)
            Spacer()
            if model.pauseCloud { Text("CLOUD PAUSED").font(Theme.mono(10, .bold)).tracking(Theme.track(10)).foregroundStyle(.black).padding(.horizontal, 8).padding(.vertical, 3).background(Theme.red) }
            HStack(spacing: 7) {
                Circle().fill(model.connected ? Theme.red : Theme.dim).frame(width: 7, height: 7).shadow(color: model.connected ? Theme.red : .clear, radius: 5)
                Text(model.connected ? "COMPANION ONLINE" : "COMPANION OFFLINE").font(Theme.mono(10)).tracking(Theme.track(10))
            }
            TimelineView(.periodic(from: .now, by: 1)) { t in
                Text(t.date, format: .dateTime.hour().minute().second()).font(Theme.mono(12, .semibold)).foregroundStyle(Theme.dim)
            }
        }
        .padding(.leading, 84).padding(.trailing, 20).padding(.vertical, 14) // leading room for the window buttons
        .background(Theme.panel.opacity(0.7))
        .background(WindowDragArea())
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.red.opacity(0.6)).frame(height: 1) }
    }
}

struct AskView: View {
    @ObservedObject var model: AppModel

    /// True for the first dated message of the page and wherever the calendar day changes.
    private func isNewDay(_ turn: ChatTurn, in turns: ArraySlice<ChatTurn>) -> Bool {
        guard let i = turns.firstIndex(where: { $0.id == turn.id }) else { return false }
        guard let previous = turns[turns.startIndex..<i].last(where: { $0.at > .distantPast }) else { return true }
        return !Calendar.current.isDate(previous.at, inSameDayAs: turn.at)
    }
    @FocusState private var focused: Bool
    @State private var rounds = 10
    @State private var width: CGFloat = 1200
    /// The right column grows with the window, so the chat does not take all the room.
    private var sideWidth: CGFloat { min(560, max(360, width * 0.4)) }

    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await model.attach(urls); focused = true }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 18) {
                ArcOrb(active: model.asking || model.voiceStatus != nil).frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 6) {
                    Theme.label(model.voiceStatus ?? (model.asking ? "Processing" : "Standing by"))
                    Text(model.voiceStatus == "Hearing you" ? "Go on" : model.voiceStatus == "Listening" ? "I'm listening" : model.voiceStatus == "Recording note" ? "Taking your note" : model.voiceStatus == "Taking notes" ? "Taking notes" : model.asking ? "Thinking" : "How can I help?")
                        .font(Theme.sans(28)).tracking(-0.3)
                    HStack(spacing: 8) {
                        Text("MEMORY").font(Theme.mono(10)).tracking(Theme.track(10)).foregroundStyle(Theme.dim)
                        ForEach(AppModel.allSpaces, id: \.self) { s in SpaceChip(name: s, on: model.spaces.contains(s)) { Task { await model.toggle(space: s) } } }
                    }
                }
                Spacer()
                VoiceButtons(model: model)
            }

            StatsBar(model: model)

            HStack(spacing: 14) {
            VStack(spacing: 10) {
            if let session = model.noteSession { NoteSessionBanner(session: session) }
            TaskStrip(model: model)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if model.chat.isEmpty {
                            Text("Ask about your work, your notes, or anything else. I use your memory, the web and what I know.")
                                .font(Theme.sans(14)).foregroundStyle(Theme.dim).padding(.top, 4)
                        }
                        let page = AppModel.recent(model.chat, rounds: rounds)
                        if page.hiddenRounds > 0 {
                            Button { rounds += 10 } label: {
                                Text("SHOW EARLIER  /  \(page.hiddenRounds) MORE").font(Theme.mono(10, .bold)).tracking(Theme.track(10)).foregroundStyle(Theme.red)
                                    .padding(.horizontal, 10).padding(.vertical, 5).overlay(Rectangle().stroke(Theme.red.opacity(0.6)))
                            }.buttonStyle(.plain).frame(maxWidth: .infinity)
                        }
                        ForEach(page.turns) { turn in
                            if turn.role == "user", turn.at > .distantPast, isNewDay(turn, in: page.turns) { DayLine(date: turn.at) }
                            TurnView(turn: turn, streaming: model.asking && turn.id == model.chat.last?.id) { up in Task { await model.rate(turn.id, up: up) } }.id(turn.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 6)
                }
                .onChange(of: model.chat.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.chat.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .hud("CHAT")
            .dropDestination(for: URL.self) { urls, _ in Task { await model.attach(urls) }; return !urls.isEmpty }

            ApprovalCard(model: model)
            if model.waitingForYou {
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.bubble.fill").foregroundStyle(.black)
                    VStack(alignment: .leading, spacing: 2) {
                        // The site it is for, so a page cannot pass off its own request as Jarvis's.
                        Text("JARVIS NEEDS, FOR \(URL(string: model.browser.url)?.host?.uppercased() ?? "A PAGE")").font(Theme.mono(10, .bold)).tracking(Theme.track(10))
                        Text(model.browser.reason.isEmpty ? "Something from you to carry on." : model.browser.reason).font(Theme.sans(14, .medium))
                        Text("Reply below, only if you trust this site. It goes to Jarvis and is not saved in the chat.").font(Theme.sans(11)).opacity(0.75)
                    }
                    Spacer()
                    Button { Task { await model.browserResume("The user chose not to give this. Stop the task and tell them where you stopped.") } } label: {
                        Text("SKIP").font(Theme.mono(11, .bold)).tracking(Theme.track(11)).padding(.horizontal, 12).padding(.vertical, 6).overlay(Rectangle().stroke(.black))
                    }.buttonStyle(.plain)
                }.foregroundStyle(.black).padding(10).background(Theme.amber)
            }
            if !model.attached.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.attached) { file in
                            HStack(spacing: 6) {
                                Image(systemName: file.transcript ? "waveform" : "doc")
                                Text(file.name).lineLimit(1)
                                Button { model.attached.removeAll { $0.id == file.id } } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                            }.font(Theme.mono(11)).padding(.horizontal, 10).padding(.vertical, 5).overlay(Rectangle().stroke(Theme.red.opacity(0.6)))
                        }
                    }
                }
            }
            HStack(spacing: 0) {
                Button { attachFiles() } label: { Image(systemName: "paperclip").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.red).padding(.leading, 14) }
                    .buttonStyle(.plain).help("Attach files: pictures, PDFs, documents, sheets, slides, audio, video")
                Text(">").font(Theme.mono(20, .bold)).foregroundStyle(Theme.red).padding(.horizontal, 10)
                ZStack(alignment: .topLeading) {
                    // The hidden copy sizes the box to the text, up to six lines.
                    Text(model.question.isEmpty ? " " : model.question + " ").font(Theme.mono(16)).lineLimit(1...6).opacity(0).padding(.vertical, 14)
                    if model.question.isEmpty {
                        Text(model.waitingForYou ? "Reply to Jarvis" : model.chat.isEmpty ? "Ask me anything" : "Reply, or ask a follow-up  (shift + enter for a new line)")
                            .font(Theme.mono(16)).foregroundStyle(Theme.dim).padding(.vertical, 14).allowsHitTesting(false)
                    }
                    TextEditor(text: $model.question).font(Theme.mono(16)).scrollContentBackground(.hidden).scrollIndicators(.never)
                        .padding(.vertical, 14).padding(.leading, -5)
                        .focused($focused)
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.shift) { return .ignored } // native new line
                            Task { await model.ask() }; return .handled
                        }
                }
                Button { Task { await model.ask() } } label: {
                    Text(model.asking && !model.waitingForYou ? "WAIT" : "SEND").font(Theme.mono(12, .bold)).tracking(Theme.track(12)).padding(.horizontal, 22).frame(maxHeight: .infinity)
                        .background(model.waitingForYou ? Theme.amber : Theme.red).foregroundStyle(model.waitingForYou ? .black : .white)
                }.buttonStyle(.plain).disabled(model.asking && !model.waitingForYou)
            }
            .frame(minHeight: 50).fixedSize(horizontal: false, vertical: true).background(Color.black.opacity(0.5))
            .overlay(Rectangle().stroke(focused ? Theme.red : Color.white.opacity(0.18), lineWidth: focused ? 1.5 : 1))
            .shadow(color: focused ? Theme.red.opacity(0.35) : .clear, radius: 12)
            Text(model.notice?.uppercased() ?? (model.live ? "HANDS-FREE ON  /  JUST TALK, PAUSE TO SEND, SPEAK TO INTERRUPT" : "HOLD OPTION + SPACE TO ASK  /  OPTION + SHIFT + SPACE FOR A QUICK NOTE"))
                .font(Theme.mono(10)).tracking(Theme.track(10)).foregroundStyle(model.notice == nil ? Theme.dim : Theme.red).lineLimit(1)
            }
            VStack(spacing: 14) {
                TraceView(model: model).frame(maxHeight: .infinity).hud("NEURAL TRACE")
                TodoPanel(model: model).frame(height: 230).hud("TO-DO // \(model.openTodos) OPEN")
            }.frame(width: sideWidth)
            }
        }.padding(24)
        .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { width = $1 } })
        .task { try? await Task.sleep(for: .milliseconds(300)); focused = true } // the editor is not ready for focus on first frame
    }
}

/// "13:42" for a message; nothing for messages saved before times were kept.
struct TurnTime: View {
    let at: Date
    var body: some View {
        if at > .distantPast { Text(at, format: .dateTime.hour().minute()).font(Theme.mono(10)).foregroundStyle(Theme.dim) }
    }
}

/// A date line where a chat starts and wherever the day changes.
struct DayLine: View {
    let date: Date
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
            Text(date, format: .dateTime.weekday(.wide).day().month(.wide).year()).font(Theme.mono(10, .bold)).tracking(Theme.track(10)).foregroundStyle(Theme.dim).fixedSize()
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
        }
    }
}

struct TurnView: View {
    let turn: ChatTurn
    let streaming: Bool
    let rate: (Bool) -> Void
    var body: some View {
        if turn.role == "user" {
            HStack {
                Spacer(minLength: 120)
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(turn.attachments, id: \.self) { name in
                        Label(name, systemImage: "paperclip").font(Theme.mono(11)).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                    Text(turn.text).font(Theme.sans(15)).textSelection(.enabled).padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.red.opacity(0.14)).overlay(Rectangle().stroke(Theme.red.opacity(0.7)))
                    TurnTime(at: turn.at)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(turn.failed ? Theme.dim : Theme.red).frame(width: 2)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("JARVIS").font(Theme.mono(10, .bold)).tracking(Theme.track(10)).foregroundStyle(Theme.red)
                        TurnTime(at: turn.at)
                    }
                    if turn.text.isEmpty && streaming {
                        Text("...").font(Theme.mono(16)).foregroundStyle(Theme.dim)
                    } else {
                        Markdown(turn.text + (streaming ? " \u{258C}" : "")).markdownTheme(.jarvis).safeAnswer()
                            .foregroundStyle(turn.failed ? Theme.dim : Theme.white).textSelection(.enabled)
                        // Pictures a connected app returned (for example, an image a connector generated).
                        ForEach(Array(turn.images.enumerated()), id: \.offset) { _, data in
                            if let image = NSImage(data: data) {
                                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 520, maxHeight: 420)
                                    .overlay(Rectangle().stroke(Color.white.opacity(0.12)))
                            }
                        }
                    }
                    if !turn.citations.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(turn.citations.enumerated()), id: \.offset) { _, c in
                                Text(c).font(Theme.mono(11)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    if let learned = turn.learned {
                        Label(learned.uppercased(), systemImage: "brain.head.profile").font(Theme.mono(10, .bold)).tracking(Theme.track(10))
                            .foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 4).background(Theme.red.opacity(0.85))
                    }
                    HStack(spacing: 12) {
                        if !turn.meta.isEmpty { Text(turn.meta).font(Theme.mono(10)).tracking(Theme.track(10)).foregroundStyle(Theme.red.opacity(0.8)) }
                        if !streaming && !turn.failed && !turn.text.isEmpty {
                            ForEach([true, false], id: \.self) { up in
                                let chosen = turn.rating == (up ? "up" : "down")
                                Button { rate(up) } label: {
                                    Image(systemName: up ? (chosen ? "hand.thumbsup.fill" : "hand.thumbsup") : (chosen ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
                                        .font(Theme.sans(11)).foregroundStyle(chosen ? Theme.red : Theme.dim)
                                }.buttonStyle(.plain).help(up ? "Good answer" : "Bad answer: saved as a test case")
                            }
                        }
                    }
                }
                Spacer(minLength: 60)
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MemoryView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Theme.label("Memory core")
            HStack(spacing: 22) {
                stat(model.counts.segments, "NOTES STORED")
                stat(model.counts.entities, "PEOPLE, PROJECTS, THINGS")
            }
            Text("Notes are stored only on this Mac. Only text goes to Claude, and only when you ask a question or a note is saved. Audio never leaves.")
                .font(Theme.sans(14)).foregroundStyle(Theme.dim).frame(maxWidth: 520, alignment: .leading)
            Text(model.lastCleanup ?? "Every night between 2 and 5 am, duplicate notes and names are tidied up. Nothing is deleted, and a backup is taken first.")
                .font(Theme.sans(12)).foregroundStyle(Theme.dim)
            ImportPanel(model: model)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if model.notes.isEmpty { Text("No notes in the open spaces.").foregroundStyle(Theme.dim) }
                    ForEach(model.notes) { n in
                        HStack(alignment: .top, spacing: 12) {
                            // When it happened if the note says; otherwise when it was saved, marked as such.
                            Text(n.happened.isEmpty ? "saved \(n.createdAt.prefix(10))" : n.happened).font(Theme.mono(10))
                                .foregroundStyle(n.happened.isEmpty ? Theme.dim.opacity(0.6) : Theme.white).frame(width: 120, alignment: .leading)
                            Text(n.context.uppercased()).font(Theme.mono(10, .bold)).tracking(Theme.track(10)).foregroundStyle(Theme.red).frame(width: 100, alignment: .leading)
                            Text(n.summary).font(Theme.sans(14)).foregroundStyle(n.replaced ? Theme.dim : Theme.white).strikethrough(n.replaced)
                            if n.replaced { Text("REPLACED").font(Theme.mono(10)).foregroundStyle(Theme.dim) }
                            Spacer()
                            if n.replaced { Button("RESTORE") { Task { await model.restore(segmentId: n.id) } }.buttonStyle(.plain).font(Theme.mono(10, .bold)).foregroundStyle(Theme.white) }
                            Button("FORGET") { Task { await model.forget(segmentId: n.id) } }.buttonStyle(.plain).font(Theme.mono(10, .bold)).foregroundStyle(Theme.red)
                        }.padding(.vertical, 4)
                    }
                }.padding(14)
            }.hud("NOTES // \(model.notes.count)")
        }.padding(28)
        .task(id: model.spaces) { await model.loadNotes() }
    }
    private func stat(_ n: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(n)").font(Theme.mono(56, .light))
            Text(label).font(Theme.mono(10)).tracking(Theme.track(10)).foregroundStyle(Theme.red)
        }.frame(width: 260, alignment: .leading).hud("COUNT")
    }
}

struct LedgerView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Theme.label("Egress ledger"); Spacer(); Button("REFRESH") { Task { await model.loadLedger() } }.buttonStyle(.plain).font(Theme.mono(11, .bold)).tracking(Theme.track(11)).foregroundStyle(Theme.red) }
            Text("Every call that left this Mac: host, path and size. Never keys, never note text.").foregroundStyle(Theme.dim).font(Theme.sans(13))
            if model.ledger.isEmpty { Text("NOTHING HAS LEFT THIS MAC YET").font(Theme.mono(12)).tracking(Theme.track(12)).padding(.top, 8) }
            List(model.ledger) { r in
                HStack {
                    Text(r.ts.prefix(19).replacingOccurrences(of: "T", with: " ")).frame(width: 150, alignment: .leading)
                    Text(r.host).frame(width: 190, alignment: .leading)
                    Text(r.path).frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(r.bytes) B").frame(width: 70, alignment: .trailing)
                    Text("\(r.status)").frame(width: 40, alignment: .trailing)
                }.font(Theme.mono(11)).listRowBackground(Color.clear)
            }.scrollContentBackground(.hidden)
        }.padding(28).task { await model.loadLedger() }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    enum Tab: String, CaseIterable { case general = "GENERAL", connectors = "CONNECTORS", custom = "CUSTOM CONNECTORS", skills = "SKILLS" }
    @State private var tab: Tab = Tab(rawValue: UserDefaults.standard.string(forKey: "snapshotTab") ?? "") ?? .general // debug snapshots pick a tab

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Theme.label("Settings")
                Spacer().frame(width: 18)
                ForEach(Tab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        Text(t.rawValue).font(Theme.mono(11, .bold)).tracking(Theme.track(11)).padding(.horizontal, 14).padding(.vertical, 7)
                            .background(tab == t ? Theme.red : .clear).foregroundStyle(tab == t ? .white : Theme.dim)
                            .overlay(Rectangle().stroke(tab == t ? Theme.red : Color.white.opacity(0.18)))
                    }.buttonStyle(.plain)
                }
            }
            ScrollView {
                switch tab {
                case .general: general
                case .connectors: ConnectorsList(model: model).padding(.trailing, 6)
                case .custom: ConnectorSettings(model: model).padding(18).hud("CUSTOM CONNECTORS")
                case .skills: SkillsList(model: model).padding(.trailing, 6)
                }
            }
        }.padding(28)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 20) {
            SetupPanel(model: model).padding(18).hud("SETUP")
            Toggle(isOn: Binding(get: { model.pauseCloud }, set: { v in Task { await model.setPause(v) } })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pause cloud processing").font(Theme.sans(17, .semibold))
                    Text("Nothing is sent to Claude while this is on. Questions and new notes are refused.").foregroundStyle(Theme.dim).font(Theme.sans(13))
                }
            }.toggleStyle(.switch).tint(Theme.red).padding(18).hud("PRIVACY")
            VoiceSettings(model: model).padding(18).hud("VOICE")
            UpdatePanel(model: model).padding(18).hud("UPDATES")
            VStack(alignment: .leading, spacing: 8) {
                Text("How you asked me to reply").font(Theme.sans(17, .semibold))
                if model.instructions.isEmpty {
                    Text("Nothing yet. Say something like \"always keep it short\" and I will remember it.").foregroundStyle(Theme.dim).font(Theme.sans(13))
                }
                ForEach(model.instructions, id: \.self) { text in
                    HStack {
                        Text(text).font(Theme.sans(14))
                        Spacer()
                        Button("Remove") { Task { await model.removeInstruction(text) } }.buttonStyle(.plain).font(Theme.mono(10, .bold)).foregroundStyle(Theme.red)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18).hud("LEARNED")
        }
    }
}

/// Your own MCP servers: what is connected, and adding or removing a server.
struct ConnectorSettings: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var url = ""
    @State private var header = "Authorization"
    @State private var value = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.connectors.isEmpty { Text("No MCP servers yet. Add one with its address and, if it needs one, an auth header.").foregroundStyle(Theme.dim).font(Theme.sans(13)) }
            ForEach(model.connectors, id: \.name) { c in
                HStack {
                    Text(c.name).font(Theme.mono(13, .bold))
                    if c.needsSignIn {
                        Button { Task { await model.signIn(server: c.name) } } label: {
                            Text("SIGN IN").font(Theme.mono(10, .bold)).tracking(Theme.track(10)).padding(.horizontal, 10).padding(.vertical, 4).background(Theme.red).foregroundStyle(.white)
                        }.buttonStyle(.plain)
                    } else {
                        Text("\(c.tools) TOOLS").font(Theme.mono(10)).foregroundStyle(c.tools > 0 ? Theme.red : Theme.dim)
                    }
                    Text(c.url).font(Theme.mono(10)).foregroundStyle(Theme.dim).lineLimit(1)
                    Spacer()
                    if c.name != "composio" { Button("REMOVE") { Task { await model.removeServer(c.name) } }.buttonStyle(.plain).font(Theme.mono(10, .bold)).foregroundStyle(Theme.red) }
                }
            }
            HStack(spacing: 8) {
                TextField("Name", text: $name).frame(width: 110)
                TextField("https://server/mcp", text: $url)
                TextField("Header", text: $header).frame(width: 120)
                SecureField("Header value (kept in Keychain)", text: $value).frame(width: 220)
                Button("ADD") { Task { if await model.addServer(name: name, url: url, headerName: header, headerValue: value) { name = ""; url = ""; value = "" } } }
                    .buttonStyle(.plain).font(Theme.mono(11, .bold)).foregroundStyle(Theme.red).disabled(name.isEmpty || url.isEmpty)
            }.textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await model.loadConnectors() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await model.loadConnectors() } }
    }
}

struct VoiceSettings: View {
    @ObservedObject var model: AppModel
    @AppStorage("voice") private var voice = KokoroVoice.defaultVoice
    @AppStorage("voiceSpeed") private var speed = KokoroVoice.defaultSpeed
    private static let names = ["am_michael": "Michael (US)", "am_fenrir": "Fenrir (US)", "am_puck": "Puck (US)", "bm_george": "George (UK)",
                                "bm_fable": "Fable (UK)", "bm_lewis": "Lewis (UK)", "bm_daniel": "Daniel (UK)", "af_heart": "Heart (US, female)",
                                "af_bella": "Bella (US, female)", "bf_emma": "Emma (UK, female)"]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Voice", selection: $voice) {
                    ForEach(KokoroVoice.choices, id: \.self) { Text(Self.names[$0] ?? $0).tag($0) }
                    ForEach(AppleVoice.choices(), id: \.id) { Text($0.name).tag($0.id) }
                }.frame(maxWidth: 320)
                Button { model.onPreviewVoice?() } label: {
                    Text("PREVIEW").font(Theme.mono(11, .bold)).tracking(Theme.track(11)).padding(.horizontal, 12).padding(.vertical, 6).overlay(Rectangle().stroke(Theme.red)).foregroundStyle(Theme.red)
                }.buttonStyle(.plain)
            }
            HStack {
                Text("Speed").frame(width: 60, alignment: .leading)
                Slider(value: $speed, in: 0.9...1.6, step: 0.05).tint(Theme.red).frame(maxWidth: 260)
                Text(String(format: "%.2fx", speed)).font(Theme.mono(12)).foregroundStyle(Theme.dim)
            }
            Text("Hindi sentences always use a Hindi voice. For a clearer English voice, download one in System Settings > Accessibility > Spoken Content > System voice > Manage Voices (Premium or Enhanced); it then shows up here.").foregroundStyle(Theme.dim).font(Theme.sans(12)).fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Theme.line)
            WakeTraining(model: model)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Teach "Hey Jarvis" your voice: say it five times, see what was heard for each.
struct WakeTraining: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Theme.label("Train Hey Jarvis")
            if let heard = model.training {
                Text("Say \"Hey Jarvis\" the way you normally do, pausing after each. \(min(heard.count + 1, 5)) of 5.")
                    .font(Theme.sans(13)).foregroundStyle(Theme.white)
                ForEach(Array(heard.enumerated()), id: \.offset) { i, text in
                    HStack(spacing: 8) {
                        Text("\(i + 1)").font(Theme.mono(11)).foregroundStyle(Theme.dim)
                        Text(text).font(Theme.mono(12)).foregroundStyle(Theme.white)
                    }
                }
            } else {
                Text("If Jarvis misses you, say it five times here. It learns how your voice comes out and wakes for it from then on.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.dim)
                HStack(spacing: 12) {
                    Button { model.onTrainWake?() } label: {
                        Text("TRAIN").font(Theme.mono(11, .bold)).tracking(Theme.track(11)).padding(.horizontal, 12).padding(.vertical, 6)
                            .overlay(Rectangle().stroke(Theme.red)).foregroundStyle(Theme.red)
                    }.buttonStyle(.plain).disabled(model.noteSession != nil || model.live)
                    if !model.wakeLearned.isEmpty {
                        Text("\(model.wakeLearned.count) learned").font(Theme.mono(11)).foregroundStyle(Theme.dim)
                        Button("Forget") { model.wakeLearned = [] }.buttonStyle(.plain).font(Theme.mono(11)).foregroundStyle(Theme.dim)
                    }
                }
            }
        }
    }
}

/// Lets the custom top bar move the window, since the system title bar is hidden.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView { override var mouseDownCanMoveWindow: Bool { true } }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The installed version, and a staged new one with what changed and a button to install it.
struct UpdatePanel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let u = model.update, u.ready {
                HStack {
                    Text("An update is ready (\(u.notes.count) change\(u.notes.count == 1 ? "" : "s"))").font(Theme.sans(17, .semibold))
                    Spacer()
                    Button { Task { await model.installUpdate() } } label: {
                        Text("UPDATE NOW").font(Theme.mono(11, .bold)).tracking(Theme.track(11)).padding(.horizontal, 14).padding(.vertical, 7).background(Theme.red).foregroundStyle(.white)
                    }.buttonStyle(.plain)
                }
                ForEach(u.notes, id: \.self) { Text("- \($0)").font(Theme.sans(13)).foregroundStyle(Theme.dim) }
                Text("Jarvis closes and reopens on the new version. Your chat, memory and settings stay.").font(Theme.sans(12)).foregroundStyle(Theme.dim)
            } else {
                Text("Up to date").font(Theme.sans(17, .semibold))
                Text("Version \(model.update?.installed ?? "unknown"). New versions show up here when they are ready.").font(Theme.sans(13)).foregroundStyle(Theme.dim)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Background tasks that are running: what each is doing, and a way to stop it.
struct TaskStrip: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let running = model.tasks.filter { $0.status == "running" }
        if !running.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(running) { task in
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("BACKGROUND").font(Theme.mono(10, .bold)).tracking(Theme.track(10)).foregroundStyle(Theme.red)
                        Text(task.goal).font(Theme.sans(13)).lineLimit(1)
                        Spacer()
                        Text("\(task.steps) STEPS").font(Theme.mono(10)).foregroundStyle(Theme.dim)
                        Button { Task { await model.cancelTask(task.id) } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Stop this task")
                    }
                }
            }.padding(10).overlay(Rectangle().stroke(Theme.red.opacity(0.5)))
        }
    }
}
