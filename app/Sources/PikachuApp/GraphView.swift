import SwiftUI
import PikachuCore

private let nodeColors: [String: Color] = ["person": Theme.red, "project": .white, "tool": Color(white: 0.6), "company": Color(red: 1, green: 0.48, blue: 0.43), "place": Color(white: 0.78), "topic": Theme.redDim]

struct GraphView: View {
    @ObservedObject var model: AppModel
    @State private var positions: [Int: GraphPoint] = [:]
    @State private var selected: Int?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var search = ""
    @GestureState private var drag: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1

    private static let labelZoom: CGFloat = 1.8
    private var visible: GraphData? { model.graph?.visible(spaces: model.spaces) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Theme.label("Memory graph")
                    Spacer()
                    ForEach(AppModel.allSpaces, id: \.self) { s in SpaceChip(name: s, on: model.spaces.contains(s)) { Task { await model.toggle(space: s) }; selected = nil } }
                }
                TextField("", text: $search, prompt: Text("FIND A PERSON, PROJECT OR TOOL").foregroundStyle(Theme.dim)).textFieldStyle(.plain).font(Theme.mono(13)).padding(10)
                    .overlay(Rectangle().stroke(Color.white.opacity(0.2))).onSubmit(find)
                GeometryReader { geo in
                    ZStack {
                        Canvas { ctx, size in draw(ctx, size) }
                            .contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { tap in select(at: tap.location, size: geo.size) })
                            .gesture(DragGesture().updating($drag) { v, s, _ in s = v.translation }.onEnded { offset = CGSize(width: offset.width + $0.translation.width, height: offset.height + $0.translation.height) })
                            .gesture(MagnifyGesture().updating($pinch) { v, s, _ in s = v.magnification }.onEnded { scale = min(6, max(0.3, scale * $0.magnification)) })
                        if visible?.nodes.isEmpty ?? true {
                            Text(model.graph == nil ? "Waiting for the companion" : "Nothing to show in these spaces").font(Theme.mono(13)).foregroundStyle(Theme.dim)
                        }
                    }
                }
                .hud("GRAPH // \(visible?.nodes.count ?? 0) NODES  \(visible?.edges.count ?? 0) LINKS")
            }
            .padding(24)
            DetailPanel(model: model, selected: selected)
                .frame(width: 300)
        }
        .task { await model.loadGraph() }
        .task(id: model.graph) {
            guard let g = model.graph else { return }
            positions = await Task.detached { GraphLayout.positions(for: g) }.value
        }
    }

    private func transform(size: CGSize) -> (GraphPoint) -> CGPoint {
        let s = scale * pinch
        let half = min(size.width, size.height) / 2 - 40
        let ox = offset.width + drag.width, oy = offset.height + drag.height
        return { p in CGPoint(x: size.width / 2 + ox + CGFloat(p.x) * half * s, y: size.height / 2 + oy + CGFloat(p.y) * half * s) }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let center = CGPoint(x: size.width / 2 + offset.width + drag.width, y: size.height / 2 + offset.height + drag.height)
        for r in stride(from: CGFloat(80), through: 560, by: 120) {
            ctx.stroke(Path(ellipseIn: CGRect(x: center.x - r * scale * pinch, y: center.y - r * scale * pinch, width: r * 2 * scale * pinch, height: r * 2 * scale * pinch)), with: .color(Theme.red.opacity(0.08)), lineWidth: 1)
        }
        guard let g = visible else { return }
        let at = transform(size: size)
        let connected = Set(g.edges.filter { $0.source == selected || $0.target == selected }.flatMap { [$0.source, $0.target] })
        for e in g.edges {
            guard let a = positions[e.source], let b = positions[e.target] else { continue }
            var path = Path(); path.move(to: at(a)); path.addLine(to: at(b))
            let hot = selected != nil && (e.source == selected || e.target == selected)
            ctx.stroke(path, with: .color(hot ? Theme.red : .white.opacity(selected == nil ? 0.28 : 0.1)), lineWidth: hot ? 1.8 : 1)
        }
        for n in g.nodes {
            guard let p = positions[n.id] else { continue }
            let pt = at(p)
            let r = 4 + CGFloat(min(n.mentions, 9)).squareRoot() * 2.5
            let color = nodeColors[n.type] ?? .gray
            let dimmed = selected != nil && n.id != selected && !connected.contains(n.id)
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r * 2.4, y: pt.y - r * 2.4, width: r * 4.8, height: r * 4.8)), with: .radialGradient(Gradient(colors: [color.opacity(dimmed ? 0.05 : 0.35), .clear]), center: pt, startRadius: 0, endRadius: r * 2.4))
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)), with: .color(color.opacity(dimmed ? 0.3 : 1)))
            if n.id == selected {
                ctx.stroke(Path(ellipseIn: CGRect(x: pt.x - r - 6, y: pt.y - r - 6, width: (r + 6) * 2, height: (r + 6) * 2)), with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            // Names only once zoomed in, or for the selected node and its neighbours: zoomed out they are clutter.
            if scale * pinch >= Self.labelZoom || n.id == selected || connected.contains(n.id) {
                ctx.draw(Text(n.name).font(Theme.mono(11)).foregroundStyle(dimmed ? Theme.dim.opacity(0.4) : Theme.white), at: CGPoint(x: pt.x, y: pt.y + r + 11))
            }
        }
    }

    private func select(at point: CGPoint, size: CGSize) {
        guard let g = visible else { return }
        let at = transform(size: size)
        let hit = g.nodes.compactMap { n -> (Int, CGFloat)? in
            guard let p = positions[n.id] else { return nil }
            let q = at(p); return (n.id, hypot(q.x - point.x, q.y - point.y))
        }.filter { $0.1 < 22 }.min { $0.1 < $1.1 }
        selected = hit?.0
    }

    private func find() {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, let g = visible, let hit = g.nodes.first(where: { $0.name.lowercased().contains(q) }), let p = positions[hit.id] else { return }
        selected = hit.id
        scale = 2.2
        offset = CGSize(width: -CGFloat(p.x) * 300 * 2.2, height: -CGFloat(p.y) * 300 * 2.2)
    }
}

struct DetailPanel: View {
    @ObservedObject var model: AppModel
    let selected: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let id = selected, let d = model.graph?.details[String(id)] {
                Text(d.name).font(Theme.sans(24, .light))
                Text("\(d.type.uppercased())  /  \(d.segments.count) NOTE\(d.segments.count == 1 ? "" : "S")").font(Theme.mono(10)).tracking(Theme.track(10)).foregroundStyle(Theme.red)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        let links = d.links.filter { model.spaces.contains($0.context) }
                        if !links.isEmpty { Theme.label("Connections")
                            ForEach(Array(links.enumerated()), id: \.offset) { _, l in
                                let rel = l.relation.replacingOccurrences(of: "_", with: " ")
                                Text(l.outgoing ? "this \(rel) \(l.other)" : "\(l.other) \(rel) this").font(Theme.sans(13)).foregroundStyle(Theme.white)
                            } }
                        let notes = d.segments.filter { model.spaces.contains($0.context) }
                        if !notes.isEmpty { Theme.label("Notes").padding(.top, 8)
                            ForEach(notes, id: \.id) { s in
                                VStack(alignment: .leading, spacing: 4) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        if !s.happened.isEmpty { Text(s.happened).font(Theme.mono(10)).foregroundStyle(Theme.red) }
                                        Text(s.summary).font(Theme.sans(13)).fixedSize(horizontal: false, vertical: true)
                                    }
                                    Button("Forget this note") { Task { await model.forget(segmentId: s.id) } }.buttonStyle(.plain).font(Theme.mono(10, .semibold)).foregroundStyle(Theme.red)
                                }.padding(.leading, 10).overlay(alignment: .leading) { Rectangle().fill(Theme.red).frame(width: 2) }
                            } }
                    }
                }
            } else {
                Text("Select a node to see its connections and notes.").font(Theme.sans(13)).foregroundStyle(Theme.dim)
                Spacer()
            }
        }
        .padding(18).frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel.opacity(0.6)).overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1) }
    }
}
