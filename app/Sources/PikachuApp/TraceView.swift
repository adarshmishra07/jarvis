import SwiftUI
import PikachuCore

/// Live view of how an answer is made: the memory graph lights up node by node as notes are found, a beam goes out to
/// the web or to general knowledge when memory is not enough, then comes back for the answer.
struct TraceView: View {
    @ObservedObject var model: AppModel
    @State private var positions: [Int: GraphPoint] = [:]
    /// True once the answer is in and the walk has finished: the picture holds still instead of animating forever.
    @State private var settled = true

    private static let hop = 0.28 // seconds per node in the walk
    private static let maxWalk = 14
    private static let maxLabels = 8
    private var graph: GraphData? { model.graph?.visible(spaces: model.spaces) }

    var body: some View {
        VStack(spacing: 10) {
            ToolActivity(model: model)
            TimelineView(.animation(minimumInterval: nil, paused: settled)) { t in
                Canvas { ctx, size in draw(ctx, size, now: t.date) }
            }
            steps
        }
        .task(id: model.chat.count) { await model.loadGraph() }
        .task(id: model.trace) {
            let t = model.trace
            guard !t.stages.isEmpty, t.done else { settled = t.stages.isEmpty; return }
            // Let the walk play out before holding still.
            let walkEnds = (t.times["memory"] ?? Date()).addingTimeInterval(Double(min(t.nodes.count, Self.maxWalk)) * Self.hop + 0.7)
            try? await Task.sleep(for: .seconds(max(0, walkEnds.timeIntervalSinceNow)))
            if !Task.isCancelled { settled = true }
        }
        .task(id: model.graph) {
            guard let g = model.graph else { return }
            positions = await Task.detached { GraphLayout.positions(for: g) }.value
        }
    }

    // MARK: Step strip

    private var steps: some View {
        let t = model.trace
        let items: [(String, String, Bool)] = [
            ("MEMORY", t.stages.contains("memory") ? "\(t.nodes.count) NODES" : "", t.stages.contains("memory")),
            (t.stages.contains("knowledge") ? "KNOWLEDGE" : "WEB", t.stages.contains("web") ? "\(t.sources.count) SOURCES" : t.stages.contains("knowledge") ? "GENERAL" : "", t.stages.contains("web") || t.stages.contains("knowledge")),
            ("ANSWER", t.model, t.stages.contains("answer")),
        ]
        return HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                if i > 0 { Rectangle().fill(item.2 ? Theme.red : Color.white.opacity(0.15)).frame(height: 1) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0).font(Theme.mono(10, .bold)).tracking(Theme.track(10)).foregroundStyle(item.2 ? Theme.white : Theme.dim)
                    Text(item.1.isEmpty ? "-" : item.1).font(Theme.mono(9)).foregroundStyle(item.2 ? Theme.red : Theme.dim).lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .overlay(Rectangle().stroke(item.2 ? Theme.red : Color.white.opacity(0.15)))
            }
        }
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, now: Date) {
        let graphRect = CGRect(x: 18, y: 18, width: size.width - 36, height: size.height - 90)
        let half = min(graphRect.width, graphRect.height) / 2
        let center = CGPoint(x: graphRect.midX, y: graphRect.midY)
        let at = { (p: GraphPoint) in CGPoint(x: center.x + CGFloat(p.x) * half, y: center.y + CGFloat(p.y) * half) }
        let web = CGPoint(x: size.width - 46, y: size.height - 40)
        let mind = CGPoint(x: 46, y: size.height - 40)
        let clock = now.timeIntervalSinceReferenceDate

        // Radar sweep while working; gone once settled.
        if !settled {
        let sweep = Angle.radians(clock.truncatingRemainder(dividingBy: 8) / 8 * 2 * .pi)
        var wedge = Path(); wedge.move(to: center)
        wedge.addArc(center: center, radius: half * 1.05, startAngle: sweep - .degrees(18), endAngle: sweep, clockwise: false); wedge.closeSubpath()
        ctx.fill(wedge, with: .linearGradient(Gradient(colors: [.clear, Theme.red.opacity(0.08)]), startPoint: center, endPoint: CGPoint(x: center.x + cos(sweep.radians) * half, y: center.y + sin(sweep.radians) * half)))
        }
        for r in [0.35, 0.7, 1.05] { ctx.stroke(Path(ellipseIn: CGRect(x: center.x - half * r, y: center.y - half * r, width: half * r * 2, height: half * r * 2)), with: .color(Theme.red.opacity(0.07)), lineWidth: 1) }

        guard let g = graph else { return }
        for e in g.edges {
            guard let a = positions[e.source], let b = positions[e.target] else { continue }
            var p = Path(); p.move(to: at(a)); p.addLine(to: at(b))
            ctx.stroke(p, with: .color(.white.opacity(0.07)), lineWidth: 0.6)
        }
        for n in g.nodes { if let p = positions[n.id] { dot(ctx, at(p), 1.6, .white.opacity(0.25)) } }

        // The walk: each found node lights up in turn, with a pulse travelling along the path.
        let trace = model.trace
        let walk = Array(trace.nodes.filter { positions[$0] != nil }.prefix(Self.maxWalk))
        let start = trace.times["memory"].map { now.timeIntervalSince($0) } ?? -1
        let names = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, $0.name) })
        var lit: [CGPoint] = []
        if start >= 0, !walk.isEmpty {
            let reached = min(Double(walk.count - 1), start / Self.hop)
            for k in 0...Int(reached) {
                let p = at(positions[walk[k]]!)
                if let last = lit.last { line(ctx, last, p, Theme.red.opacity(0.8), 1.4) }
                lit.append(p)
            }
            if Int(reached) < walk.count - 1 {
                let f = reached - floor(reached)
                let a = lit.last!, b = at(positions[walk[Int(reached) + 1]]!)
                let head = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                line(ctx, a, head, Theme.red, 1.6); dot(ctx, head, 3, .white)
            }
            var placed: [CGRect] = []
            for (k, p) in lit.enumerated() {
                let age = start - Double(k) * Self.hop
                let ring = CGFloat(min(age, 0.6) / 0.6)
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 14 * ring, y: p.y - 14 * ring, width: 28 * ring, height: 28 * ring)), with: .color(Theme.red.opacity(Double(1 - ring) * 0.9)), lineWidth: 1.5)
                glow(ctx, p, 6)
                // Label the first few, skipping any that would overlap one already drawn.
                let name = names[walk[k]] ?? ""
                let box = CGRect(x: p.x - CGFloat(name.count) * 3, y: p.y - 19, width: CGFloat(name.count) * 6, height: 12)
                if placed.count < Self.maxLabels, !placed.contains(where: { $0.insetBy(dx: -4, dy: -2).intersects(box) }) {
                    placed.append(box)
                    ctx.draw(Text(name).font(Theme.mono(9, .semibold)).foregroundStyle(Theme.white), at: CGPoint(x: p.x, y: p.y - 13))
                }
            }
        }

        // Out to the web or general knowledge, then back for the answer.
        let usedWeb = trace.stages.contains("web"), usedMind = trace.stages.contains("knowledge")
        satellite(ctx, web, "WEB", active: usedWeb, clock: clock)
        satellite(ctx, mind, "KNOWLEDGE", active: usedMind, clock: clock)
        let from = lit.last ?? center
        if let target = usedWeb ? web : usedMind ? mind : nil {
            beam(ctx, from, target, clock: clock, back: false)
            if usedWeb { for (i, host) in trace.sources.prefix(4).enumerated() {
                ctx.draw(Text(host).font(Theme.mono(8)).foregroundStyle(Theme.dim), at: CGPoint(x: size.width - 6, y: web.y - 34 - CGFloat(i) * 11), anchor: .trailing)
            } }
            if trace.stages.contains("answer") { beam(ctx, target, center, clock: clock, back: true) }
        }
        if trace.stages.contains("answer") {
            let pulse = CGFloat((clock * 1.4).truncatingRemainder(dividingBy: 1))
            let r = 10 + pulse * 26
            ctx.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)), with: .color(Theme.red.opacity(trace.done ? 0 : Double(1 - pulse))), lineWidth: 1.5)
            glow(ctx, center, trace.done ? 5 : 8)
        }
    }

    private func dot(_ ctx: GraphicsContext, _ p: CGPoint, _ r: CGFloat, _ c: Color) {
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(c))
    }

    private func glow(_ ctx: GraphicsContext, _ p: CGPoint, _ r: CGFloat) {
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r * 3, y: p.y - r * 3, width: r * 6, height: r * 6)), with: .radialGradient(Gradient(colors: [Theme.red.opacity(0.55), .clear]), center: p, startRadius: 0, endRadius: r * 3))
        dot(ctx, p, r * 0.6, Theme.red)
    }

    private func line(_ ctx: GraphicsContext, _ a: CGPoint, _ b: CGPoint, _ c: Color, _ w: CGFloat) {
        var p = Path(); p.move(to: a); p.addLine(to: b); ctx.stroke(p, with: .color(c), lineWidth: w)
    }

    /// A dashed link with packets moving along it.
    private func beam(_ ctx: GraphicsContext, _ a: CGPoint, _ b: CGPoint, clock: Double, back: Bool) {
        var p = Path(); p.move(to: a); p.addLine(to: b)
        ctx.stroke(p, with: .color(Theme.red.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 5], dashPhase: settled ? 0 : CGFloat(-clock * 30)))
        guard !settled else { return } // packets only while data is moving
        for i in 0..<3 {
            let f = CGFloat((clock * 0.7 + Double(i) / 3).truncatingRemainder(dividingBy: 1))
            dot(ctx, CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), 2.2, back ? .white : Theme.red)
        }
    }

    private func satellite(_ ctx: GraphicsContext, _ p: CGPoint, _ label: String, active: Bool, clock: Double) {
        let spin = Angle.radians(clock * (active ? 2.4 : 0.4))
        var arc = Path(); arc.addArc(center: p, radius: 16, startAngle: spin, endAngle: spin + .degrees(250), clockwise: false)
        ctx.stroke(arc, with: .color(active ? Theme.red : .white.opacity(0.2)), lineWidth: 1.5)
        if active { glow(ctx, p, 5) } else { dot(ctx, p, 3, .white.opacity(0.25)) }
        ctx.draw(Text(label).font(Theme.mono(8, .bold)).foregroundStyle(active ? Theme.white : Theme.dim), at: CGPoint(x: p.x, y: p.y + 26))
    }
}
