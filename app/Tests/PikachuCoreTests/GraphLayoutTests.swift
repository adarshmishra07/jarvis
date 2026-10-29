import XCTest
@testable import PikachuCore

final class GraphLayoutTests: XCTestCase {
    private func node(_ id: Int, _ name: String = "n", contexts: [String] = ["company"]) -> GraphData.Node {
        .init(id: id, name: name, type: "person", mentions: 1, contexts: contexts)
    }

    func testEmptyAndSingleNodeAreFine() {
        XCTAssertEqual(GraphLayout.positions(for: GraphData(nodes: [], edges: [], details: [:])).count, 0)
        let one = GraphLayout.positions(for: GraphData(nodes: [node(1)], edges: [], details: [:]))
        XCTAssertEqual(one.count, 1)
        XCTAssertTrue(one[1]!.x.isFinite && one[1]!.y.isFinite)
    }

    func testConnectedNodesEndUpCloserThanUnconnectedOnes() {
        // two triangles, no link between them
        let nodes = (1...6).map { node($0) }
        let e: (Int, Int) -> GraphData.Edge = { .init(source: $0, target: $1, relation: "r", context: "company") }
        let g = GraphData(nodes: nodes, edges: [e(1, 2), e(2, 3), e(1, 3), e(4, 5), e(5, 6), e(4, 6)], details: [:])
        let p = GraphLayout.positions(for: g)
        func d(_ a: Int, _ b: Int) -> Double { hypot(p[a]!.x - p[b]!.x, p[a]!.y - p[b]!.y) }
        XCTAssertLessThan(max(d(1, 2), d(2, 3), d(4, 5)), min(d(1, 4), d(2, 5), d(3, 6)))
    }

    func testDeterministicBoundedAndSelfLoopsIgnored() {
        let g = GraphData(nodes: (1...20).map { node($0) }, edges: (1...19).map { .init(source: $0, target: $0 + 1, relation: "r", context: "company") } + [.init(source: 3, target: 3, relation: "self", context: "company")], details: [:])
        let a = GraphLayout.positions(for: g), b = GraphLayout.positions(for: g)
        XCTAssertEqual(a.mapValues { $0.x }, b.mapValues { $0.x })
        for p in a.values { XCTAssertTrue(abs(p.x) <= 1.0001 && abs(p.y) <= 1.0001 && p.x.isFinite && p.y.isFinite) }
    }

    func testParsesCompanionJSONAndKeepsOnlyKnownSpaces() {
        let body: JSON = ["nodes": [["id": 1, "name": "Atlas", "type": "project", "mentions": 2, "contexts": ["company"]]],
                          "edges": [["source": 1, "target": 1, "relation": "x", "segment": 1, "context": "company"]],
                          "details": ["1": ["name": "Atlas", "type": "project", "segments": [["id": 7, "summary": "s", "context": "company"]], "links": []]]]
        let g = GraphData(body: body)
        XCTAssertEqual(g?.nodes.first?.name, "Atlas")
        XCTAssertEqual(g?.details["1"]?.segments.first?.id, 7)
    }

    func testVisibleFiltersNodesAndEdgesBySpace() {
        let g = GraphData(nodes: [node(1, contexts: ["company"]), node(2, contexts: ["personal"])], edges: [.init(source: 1, target: 2, relation: "r", context: "personal")], details: [:])
        let v = g.visible(spaces: ["company", "professional"])
        XCTAssertEqual(v.nodes.map(\.id), [1])
        XCTAssertTrue(v.edges.isEmpty)
    }
}
