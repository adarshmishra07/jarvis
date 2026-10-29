import SwiftUI
import UniformTypeIdentifiers
import PikachuCore

/// Bring in what other assistants know about you: copy a prompt, paste it there, and add the Markdown files they give.
struct ImportPanel: View {
    @ObservedObject var model: AppModel
    @State private var copied = false

    /// Asks another assistant for everything it knows, shaped so each line becomes a dated note with clear people,
    /// projects and places for the memory graph. The date asked for is when something happened, not when it was learned.
    static let exportPrompt = """
    Export all of my stored memories and any context you've learned about me from past conversations. Preserve my words verbatim where possible, especially for instructions and preferences.

    ## Categories (output in this order):

    1. **Instructions**: Rules I've explicitly asked you to follow going forward: tone, format, style, "always do X", "never do Y", and corrections to your behavior. Only include rules from stored memories, not from conversations.

    2. **Identity**: Name, age, location, education, family, relationships, languages, and personal interests.

    3. **Career**: Current and past roles, companies, and general skill areas. Name each company and give the dates of each role.

    4. **Projects**: Projects I meaningfully built or committed to. Ideally ONE entry per project. Include what it does, current status, key decisions, and the people and companies involved. Use the project name or a short descriptor as the first words of the entry.

    5. **People**: People who matter in my life or work. One entry per person: their full name, how they relate to me, and what we do together.

    6. **Places and organizations**: Cities, places, companies, schools and communities that matter to me, and why.

    7. **Events and timeline**: Things that happened: trips, launches, moves, milestones, decisions. One entry per event.

    8. **Preferences**: Opinions, tastes, and working-style preferences that apply broadly.

    ## Format:

    Use section headers for each category. Within each category, list one entry per line, sorted by oldest date first. Format each line as:

    [YYYY-MM-DD] - Entry content here.

    The date is when the thing actually happened or started, not when you learned it. Use [YYYY-MM] or [YYYY] when only that much is known, and [unknown] when no date is known.
    Write full names of people, projects, companies and places every time, never "he", "she" or "the project", so each line makes sense on its own.
    If something is no longer true (an old job, a changed opinion, a finished project), keep it and add (outdated) at the end of the line.

    ## Output:
    - Wrap the entire export in a single code block for easy copying.
    - After the code block, state whether this is the complete set or if more remain.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(1, "Copy this prompt and paste it into ChatGPT, Claude, Gemini or any other assistant.") {
                Button { copy() } label: { label(copied ? "COPIED" : "COPY PROMPT") }.buttonStyle(.plain)
            }
            step(2, "Save its answer as a .md file (or several: one per assistant).") { EmptyView() }
            step(3, "Add the files here. They are read into your memory one after another.") {
                Button { choose() } label: { label("CHOOSE FILES") }.buttonStyle(.plain).disabled(model.importProgress != nil)
            }
            Text(model.importProgress ?? model.notice ?? "Or drop .md files on this box.").font(Theme.sans(12)).foregroundStyle(Theme.dim)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .hud("IMPORT FROM OTHER AI")
        .dropDestination(for: URL.self) { urls, _ in Task { await model.importFiles(urls) }; return !urls.isEmpty }
    }

    private func step<Action: View>(_ n: Int, _ text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 12) {
            Text("\(n)").font(Theme.mono(12, .bold)).foregroundStyle(Theme.red).frame(width: 14)
            Text(text).font(Theme.sans(13))
            Spacer()
            action()
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Theme.mono(11, .bold)).tracking(Theme.track(11)).padding(.horizontal, 12).padding(.vertical, 6)
            .overlay(Rectangle().stroke(Theme.red)).foregroundStyle(Theme.red)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.exportPrompt, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(3)); copied = false }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await model.importFiles(urls) }
    }
}
