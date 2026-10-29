import Foundation

public struct GraphData: Equatable {
    public struct Node: Equatable, Identifiable {
        public let id: Int
        public let name: String, type: String
        public let mentions: Int
        public let contexts: [String]
        public init(id: Int, name: String, type: String, mentions: Int, contexts: [String]) { self.id = id; self.name = name; self.type = type; self.mentions = mentions; self.contexts = contexts }
    }
    public struct Edge: Equatable {
        public let source: Int, target: Int
        public let relation: String, context: String
        public init(source: Int, target: Int, relation: String, context: String) { self.source = source; self.target = target; self.relation = relation; self.context = context }
    }
    public struct Detail: Equatable {
        public struct Segment: Equatable { public let id: Int; public let summary: String; public let context: String; public var happened = "" }
        public struct Link: Equatable { public let relation: String; public let outgoing: Bool; public let other: String; public let context: String }
        public let name: String, type: String
        public let segments: [Segment]
        public let links: [Link]
    }

    public let nodes: [Node]
    public let edges: [Edge]
    public let details: [String: Detail]

    public init(nodes: [Node], edges: [Edge], details: [String: Detail]) { self.nodes = nodes; self.edges = edges; self.details = details }

    public init?(body: JSON) {
        guard let rawNodes = body["nodes"] as? [[String: Any]], let rawEdges = body["edges"] as? [[String: Any]] else { return nil }
        nodes = rawNodes.compactMap { n in
            guard let id = n["id"] as? Int, let name = n["name"] as? String else { return nil }
            return Node(id: id, name: name, type: n["type"] as? String ?? "topic", mentions: n["mentions"] as? Int ?? 1, contexts: n["contexts"] as? [String] ?? [])
        }
        edges = rawEdges.compactMap { e in
            guard let s = e["source"] as? Int, let t = e["target"] as? Int else { return nil }
            return Edge(source: s, target: t, relation: e["relation"] as? String ?? "", context: e["context"] as? String ?? "")
        }
        var out: [String: Detail] = [:]
        for (key, value) in (body["details"] as? [String: Any]) ?? [:] {
            guard let d = value as? [String: Any], let name = d["name"] as? String else { continue }
            let segments = (d["segments"] as? [[String: Any]] ?? []).compactMap { s -> Detail.Segment? in
                guard let id = s["id"] as? Int else { return nil }
                return .init(id: id, summary: s["summary"] as? String ?? "", context: s["context"] as? String ?? "", happened: s["happened"] as? String ?? "")
            }
            let links = (d["links"] as? [[String: Any]] ?? []).map {
                Detail.Link(relation: $0["relation"] as? String ?? "", outgoing: ($0["dir"] as? String) == "out", other: $0["other"] as? String ?? "", context: $0["context"] as? String ?? "")
            }
            out[key] = Detail(name: name, type: d["type"] as? String ?? "topic", segments: segments, links: links)
        }
        details = out
    }

    /// Only the nodes and edges that belong to the switched-on memory spaces.
    public func visible(spaces: Set<String>) -> GraphData {
        let keep = Set(nodes.filter { $0.contexts.contains(where: spaces.contains) }.map(\.id))
        return GraphData(nodes: nodes.filter { keep.contains($0.id) },
                         edges: edges.filter { spaces.contains($0.context) && keep.contains($0.source) && keep.contains($0.target) && $0.source != $0.target },
                         details: details)
    }
}

public struct GraphPoint: Equatable { public var x: Double; public var y: Double }

/// Force-directed layout (Fruchterman-Reingold). Deterministic: the start positions come from a fixed seed.
public enum GraphLayout {
    public static func positions(for graph: GraphData) -> [Int: GraphPoint] {
        let n = graph.nodes.count
        if n == 0 { return [:] }
        var index: [Int: Int] = [:]
        for (i, node) in graph.nodes.enumerated() { index[node.id] = i }
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        var p = (0..<n).map { _ in GraphPoint(x: next() - 0.5, y: next() - 0.5) }
        if n == 1 { return [graph.nodes[0].id: GraphPoint(x: 0, y: 0)] }
        let links: [(Int, Int)] = graph.edges.compactMap { e in
            guard let a = index[e.source], let b = index[e.target], a != b else { return nil }
            return (a, b)
        }
        let k = 1.0 / Double(n).squareRoot()
        let iterations = max(60, min(300, 4_000_000 / (n * n)))
        var temperature = 0.1
        for _ in 0..<iterations {
            var dx = [Double](repeating: 0, count: n), dy = [Double](repeating: 0, count: n)
            for i in 0..<n { for j in (i + 1)..<n {
                var ex = p[i].x - p[j].x, ey = p[i].y - p[j].y
                var d = (ex * ex + ey * ey).squareRoot()
                if d < 1e-6 { ex = next() - 0.5; ey = next() - 0.5; d = 1e-3 }
                let f = k * k / d
                dx[i] += ex / d * f; dy[i] += ey / d * f; dx[j] -= ex / d * f; dy[j] -= ey / d * f
            } }
            for (a, b) in links {
                let ex = p[a].x - p[b].x, ey = p[a].y - p[b].y
                let d = max((ex * ex + ey * ey).squareRoot(), 1e-6)
                let f = d * d / k
                dx[a] -= ex / d * f; dy[a] -= ey / d * f; dx[b] += ex / d * f; dy[b] += ey / d * f
            }
            for i in 0..<n {
                dx[i] -= p[i].x * 0.5; dy[i] -= p[i].y * 0.5 // gentle gravity keeps separate islands on screen
                let d = max((dx[i] * dx[i] + dy[i] * dy[i]).squareRoot(), 1e-9)
                let step = min(d, temperature)
                p[i].x += dx[i] / d * step; p[i].y += dy[i] / d * step
            }
            temperature *= 0.97
        }
        let extent = max(p.map { abs($0.x) }.max() ?? 1, p.map { abs($0.y) }.max() ?? 1, 1e-9)
        var out: [Int: GraphPoint] = [:]
        for (i, node) in graph.nodes.enumerated() { out[node.id] = GraphPoint(x: p[i].x / extent, y: p[i].y / extent) }
        return out
    }
}
