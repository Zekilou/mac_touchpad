import XCTest
@testable import GestureEngine

final class TimelineGraphValidatorTests: XCTestCase {

    private func makeNode(_ type: NodeType) -> NodeConfig {
        NodeConfig(type: type, x: 0, y: 0)
    }

    private func edge(_ from: NodeConfig, _ to: NodeConfig, fromPort: String = "output", toPort: String = "input") -> Edge {
        Edge(from: PortID(nodeID: from.id, portName: fromPort),
             to: PortID(nodeID: to.id, portName: toPort))
    }

    // MARK: - valid

    func testValidLinearGraph() {
        let a = makeNode(.touchData)
        let b = makeNode(.transform)
        let c = makeNode(.quantize)
        let timeline = TimelineConfig(trigger: .onTick,
                                      nodes: [a, b, c],
                                      edges: [edge(a, b), edge(b, c)],
                                      entryNodeIDs: [a.id])
        let result = TimelineGraphValidator.topologicalOrder(of: timeline)
        guard case .valid(let order) = result else {
            return XCTFail("预期 valid，得到 \(result)")
        }
        XCTAssertEqual(order, [a.id, b.id, c.id])
    }

    func testValidDiamondGraph() {
        let a = makeNode(.split)
        let b = makeNode(.consume)
        let c = makeNode(.haptic)
        let d = makeNode(.merge)
        let timeline = TimelineConfig(trigger: .onTick,
                                      nodes: [a, b, c, d],
                                      edges: [edge(a, b), edge(a, c), edge(b, d), edge(c, d)],
                                      entryNodeIDs: [a.id])
        let result = TimelineGraphValidator.topologicalOrder(of: timeline)
        guard case .valid(let order) = result else {
            return XCTFail("预期 valid，得到 \(result)")
        }
        // a 必须排在 b/c 之前，b/c 在 d 之前
        XCTAssertEqual(order.first, a.id)
        XCTAssertEqual(order.last, d.id)
        XCTAssertTrue(order.firstIndex(of: b.id)! < order.firstIndex(of: d.id)!)
        XCTAssertTrue(order.firstIndex(of: c.id)! < order.firstIndex(of: d.id)!)
    }

    func testEmptyGraphIsValid() {
        let timeline = TimelineConfig(trigger: .onEnterHolding, nodes: [], edges: [], entryNodeIDs: [])
        let result = TimelineGraphValidator.topologicalOrder(of: timeline)
        XCTAssertEqual(result, .valid(order: []))
    }

    // MARK: - cycle

    func testCycleDetected() {
        let a = makeNode(.touchData)
        let b = makeNode(.state)
        let timeline = TimelineConfig(trigger: .onTick,
                                      nodes: [a, b],
                                      edges: [edge(a, b), edge(b, a)],
                                      entryNodeIDs: [a.id])
        let result = TimelineGraphValidator.topologicalOrder(of: timeline)
        guard case .cycle(let path) = result else {
            return XCTFail("预期 cycle，得到 \(result)")
        }
        XCTAssertFalse(path.isEmpty)
    }

    func testSelfLoopCycleDetected() {
        let a = makeNode(.state)
        let timeline = TimelineConfig(trigger: .onTick,
                                      nodes: [a],
                                      edges: [edge(a, a)],
                                      entryNodeIDs: [a.id])
        let result = TimelineGraphValidator.topologicalOrder(of: timeline)
        guard case .cycle = result else {
            return XCTFail("预期 cycle，得到 \(result)")
        }
    }

    // MARK: - danglingEdge

    func testDanglingEdgeDetected() {
        let a = makeNode(.touchData)
        let ghost = UUID()
        let badEdge = Edge(from: PortID(nodeID: a.id, portName: "output"),
                           to: PortID(nodeID: ghost, portName: "input"))
        let timeline = TimelineConfig(trigger: .onTick,
                                      nodes: [a],
                                      edges: [badEdge],
                                      entryNodeIDs: [a.id])
        let result = TimelineGraphValidator.topologicalOrder(of: timeline)
        guard case .danglingEdge(let edge) = result else {
            return XCTFail("预期 danglingEdge，得到 \(result)")
        }
        XCTAssertEqual(edge.to.nodeID, ghost)
    }

    // MARK: - noEntry

    func testNoEntryDetected() {
        let a = makeNode(.touchData)
        let b = makeNode(.transform)
        let timeline = TimelineConfig(trigger: .onTick,
                                      nodes: [a, b],
                                      edges: [edge(a, b)],
                                      entryNodeIDs: [])
        let result = TimelineGraphValidator.topologicalOrder(of: timeline)
        XCTAssertEqual(result, .noEntry)
    }

    func testEntryReferencingMissingNodeIsDangling() {
        let a = makeNode(.touchData)
        let ghost = UUID()
        let timeline = TimelineConfig(trigger: .onTick,
                                      nodes: [a],
                                      edges: [],
                                      entryNodeIDs: [ghost])
        let result = TimelineGraphValidator.topologicalOrder(of: timeline)
        guard case .danglingEdge = result else {
            return XCTFail("预期 danglingEdge，得到 \(result)")
        }
    }

    // MARK: - reachableNodes

    func testReachableNodes_CoversConnectedChain() {
        let a = makeNode(.touchData)
        let b = makeNode(.transform)
        let c = makeNode(.quantize)
        let timeline = TimelineConfig(trigger: .onTick,
                                      nodes: [a, b, c],
                                      edges: [edge(a, b), edge(b, c)],
                                      entryNodeIDs: [a.id])
        XCTAssertEqual(TimelineGraphValidator.reachableNodes(from: timeline),
                       Set([a.id, b.id, c.id]))
    }

    func testReachableNodes_ExcludesOrphanNode() {
        let a = makeNode(.touchData)
        let orphan = makeNode(.notify)
        let timeline = TimelineConfig(trigger: .onTick,
                                      nodes: [a, orphan],
                                      edges: [],
                                      entryNodeIDs: [a.id])
        XCTAssertEqual(TimelineGraphValidator.reachableNodes(from: timeline), Set([a.id]))
    }
}
