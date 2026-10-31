import SwiftUI
import PikachuCore

/// Skills: instructions from GitHub that teach Jarvis a job using programs on this Mac. Each command asks first,
/// unless you turn on "run without asking" for that skill.
struct SkillsList: View {
    @ObservedObject var model: AppModel
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Skills").font(Theme.sans(24, .semibold))
                Text("Jobs Jarvis learns from a SKILL.md on GitHub. Their commands run on this Mac and ask you first.").font(Theme.sans(13)).foregroundStyle(Theme.dim)
            }.padding(.bottom, 14)
            HStack(spacing: 8) {
                TextField("https://github.com/owner/repo", text: $link).textFieldStyle(.roundedBorder)
                Button { Task { if await model.installSkill(from: link) { link = "" } } } label: {
                    Text(model.installingSkill ? "INSTALLING..." : "INSTALL").font(Theme.mono(11, .bold)).tracking(Theme.track(11))
                        .padding(.horizontal, 14).padding(.vertical, 7).background(Theme.red).foregroundStyle(.white)
                }.buttonStyle(.plain).disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || model.installingSkill)
            }.padding(.bottom, 14)
            Rectangle().fill(Color.white.opacity(0.25)).frame(height: 1)
            switch model.skills {
            case nil: Text("Loading...").foregroundStyle(Theme.dim).padding(.vertical, 16)
            case let skills? where skills.isEmpty: Text("No skills yet. Paste a GitHub link above.").foregroundStyle(Theme.dim).padding(.vertical, 16)
            case let skills?: ForEach(skills) { row($0) }
            }
        }
        .task { await model.loadSkills() }
    }

    private func row(_ skill: SkillRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "wand.and.stars").font(.system(size: 20)).frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name).font(Theme.sans(15, .semibold))
                    Text(skill.description).font(Theme.sans(13)).foregroundStyle(Theme.dim).lineLimit(3)
                    if !skill.programs.isEmpty {
                        Text("RUNS  " + skill.programs.joined(separator: "  ")).font(Theme.mono(10)).foregroundStyle(Theme.dim)
                    }
                    if !skill.source.isEmpty { Text(skill.source).font(Theme.mono(10)).foregroundStyle(Theme.dim).lineLimit(1) }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { skill.enabled }, set: { v in Task { await model.setSkill(skill.name, enabled: v) } }))
                    .toggleStyle(.switch).tint(Theme.red).labelsHidden()
                Menu {
                    Button(skill.autoRun ? "Ask before each command" : "Let web fetches run without asking") { Task { await model.setSkill(skill.name, autoRun: !skill.autoRun) } }
                    Button("Update from GitHub") { Task { _ = await model.installSkill(from: skill.source) } }.disabled(skill.source.isEmpty)
                    Button("Remove", role: .destructive) { Task { await model.removeSkill(skill.name) } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }
            if skill.autoRun {
                Text("WEB FETCHES RUN WITHOUT ASKING (curl, yt-dlp, xreach; everything else still asks)").font(Theme.mono(10, .bold)).tracking(Theme.track(10))
                    .foregroundStyle(Theme.red).padding(.leading, 50)
            }
        }.padding(.vertical, 12).overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }
}
