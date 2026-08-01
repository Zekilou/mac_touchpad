import XCTest
// 显式导入：消除与 Foundation.Predicate(macOS 14+) 的同名歧义
import enum GestureEngine.Predicate
@testable import GestureEngine

final class TimelineTests: XCTestCase {

    // MARK: - NodeParams

    func testNodeParamsDefaultAllNil() {
        let params = NodeParams()
        XCTAssertNil(params.source)
        XCTAssertNil(params.key)
        XCTAssertNil(params.waveform)
    }

    func testNodeParamsConvenientInit() {
        let params = NodeParams(source: .normX, key: "startRaw", delayMs: 50)
        XCTAssertEqual(params.source, .normX)
        XCTAssertEqual(params.key, "startRaw")
        XCTAssertEqual(params.delayMs, 50)
    }

    // MARK: - NodeConfig / Edge / TimelineConfig

    func testTimelineConfigRoundTrip() throws {
        let node = NodeConfig(
            type: .quantize,
            params: NodeParams(stepNorm: 0.02, sensitivity: 1.0),
            x: 100, y: 200,
            title: "量化"
        )
        let timeline = TimelineConfig(
            trigger: .onTick,
            nodes: [node],
            edges: [],
            entryNodeIDs: [node.id]
        )
        let data = try JSONEncoder().encode(timeline)
        let decoded = try JSONDecoder().decode(TimelineConfig.self, from: data)
        XCTAssertEqual(decoded, timeline)
        XCTAssertEqual(decoded.firstNode(of: .quantize)?.params.stepNorm, 0.02)
    }

    func testEdgeRoundTrip() throws {
        let edge = Edge(from: PortID(nodeID: UUID(), portName: "output"),
                        to: PortID(nodeID: UUID(), portName: "input"))
        let data = try JSONEncoder().encode(edge)
        let decoded = try JSONDecoder().decode(Edge.self, from: data)
        XCTAssertEqual(decoded, edge)
    }

    func testTimelineConfigEdgeQueries() {
        let a = NodeConfig(type: .touchData, params: NodeParams(), x: 0, y: 0)
        let b = NodeConfig(type: .transform, params: NodeParams(transform: .delta), x: 200, y: 0)
        let edge = Edge(from: PortID(nodeID: a.id, portName: "output"),
                        to: PortID(nodeID: b.id, portName: "input"))
        let timeline = TimelineConfig(trigger: .onTick, nodes: [a, b], edges: [edge], entryNodeIDs: [a.id])

        XCTAssertEqual(timeline.outgoingEdges(from: a.id).count, 1)
        XCTAssertEqual(timeline.incomingEdges(to: b.id).count, 1)
        XCTAssertEqual(timeline.outgoingEdges(from: b.id).count, 0)
    }

    // MARK: - Predicate Codable（含递归）

    func testPredicateSimpleRoundTrip() throws {
        let cases: [Predicate] = [.atBoundary, .notAtBoundary, .firstTime, .positive, .negative]
        for predicate in cases {
            let data = try JSONEncoder().encode(predicate)
            let decoded = try JSONDecoder().decode(Predicate.self, from: data)
            XCTAssertEqual(decoded, predicate, "round-trip failed for \(predicate)")
        }
    }

    func testPredicateCompareRoundTrip() throws {
        let p: Predicate = .compare(.gte, 0.5)
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Predicate.self, from: data)
        XCTAssertEqual(decoded, Predicate.compare(.gte, 0.5))
    }

    func testPredicateRecursiveRoundTrip() throws {
        let notPositive: Predicate = .not(.positive)
        let orFirstTime: Predicate = .or(.firstTime, notPositive)
        let p: Predicate = .and(.notAtBoundary, orFirstTime)
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Predicate.self, from: data)
        XCTAssertEqual(decoded, p)
    }

    func testPredicateUnknownKindDefaultsToAtBoundary() throws {
        let json = #"{"kind":"unknown_xyz"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Predicate.self, from: json)
        let expected: Predicate = .atBoundary
        XCTAssertEqual(decoded, expected)
    }

    // MARK: - NodeType

    func testNodeTypeAllCasesUniqueRawValues() {
        let rawValues = NodeType.allCases.map(\.rawValue)
        XCTAssertEqual(rawValues.count, Set(rawValues).count, "NodeType rawValue 重复")
        // switch 关键字必须可解码
        XCTAssertTrue(NodeType.allCases.contains(.`switch`))
    }

    func testNodeTypeRoundTrip() throws {
        let data = try JSONEncoder().encode(NodeType.`switch`)
        let decoded = try JSONDecoder().decode(NodeType.self, from: data)
        XCTAssertEqual(decoded, .`switch`)
    }
}
