import SwiftUI
import PikachuCore

/// Safety: what Jarvis never does, what it spends, how private this Mac is, and notes held back from memory.
struct SafetyView: View {
    @ObservedObject var model: AppModel
    @State private var budget = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("Never", "Jarvis never deletes, pays or buys, or sends, posts or uploads anything. These are refused in code, with no Approve button. It gets the step ready and you press the last button.") { EmptyView() }

            section("Spending", "What Jarvis has spent on Claude. Scheduled tasks and watches stop for the day at the budget; your own questions never do.") {
                if let s = model.spend {
                    HStack(spacing: 28) {
                        stat("TODAY", s.today); stat("THIS MONTH", s.month)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("DAILY BUDGET (USD)").font(Theme.mono(10, .bold)).tracking(Theme.track(10)).foregroundStyle(Theme.dim)
                            TextField(String(format: "%.0f", s.budget), text: $budget).textFieldStyle(.roundedBorder).frame(width: 90)
                                .onSubmit { if let v = Double(budget), v >= 0 { Task { await model.setBudget(v); budget = "" } } }
                        }
                    }
                } else { Text("Loading...").foregroundStyle(Theme.dim) }
            }

            section("This Mac", "Checks that the Mac keeps Jarvis's data private. Nothing is changed.") {
                Button { Task { await model.runPrivacyCheck() } } label: {
                    Text(model.privacy.isEmpty ? "RUN CHECK" : "CHECK AGAIN").font(Theme.mono(11, .bold)).tracking(Theme.track(11))
                        .padding(.horizontal, 14).padding(.vertical, 7).background(Theme.red).foregroundStyle(.white)
                }.buttonStyle(.plain)
                ForEach(model.privacy) { c in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: c.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(c.ok ? Color.green : Theme.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).font(Theme.sans(14, .semibold))
                            Text(c.detail).font(Theme.sans(12)).foregroundStyle(Theme.dim)
                        }
                    }
                }
            }

            section("Held back from memory", "Voice notes or imports that read like instructions to Jarvis (\"ignore your rules\", \"Jarvis must send...\"). They are not learned unless you keep them, and go away after 30 days.") {
                if model.held.isEmpty { Text("Nothing held back.").foregroundStyle(Theme.dim) }
                ForEach(model.held) { n in
                    HStack(alignment: .top, spacing: 12) {
                        Text(n.text).font(Theme.sans(13)).lineLimit(4)
                        Spacer()
                        Button("Keep") { Task { await model.loadHeld(keep: n.id) } }
                        Button("Drop") { Task { await model.loadHeld(drop: n.id) } }
                    }
                }
            }
        }
        .task { await model.loadSafety() }
    }

    private func stat(_ label: String, _ usd: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.mono(10, .bold)).tracking(Theme.track(10)).foregroundStyle(Theme.dim)
            Text(String(format: "$%.2f", usd)).font(Theme.sans(22, .semibold))
        }
    }

    private func section<C: View>(_ title: String, _ about: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.sans(20, .semibold))
            Text(about).font(Theme.sans(13)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            content()
        }
    }
}
