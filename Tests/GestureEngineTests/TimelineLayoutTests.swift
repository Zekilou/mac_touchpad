import XCTest
@testable import GestureEngine

final class TimelineLayoutTests: XCTestCase {

    private func makePipeline() -> LegacyPipelineConfig { LegacyPipelineConfig() }
    private func makeEvent() -> EventConfig {
        EventConfig(name: "音量", actionType: .volume, step: 0.0125, boundaryThreshold: 0.001)
    }

    /// 迁移图布局后：同组内每条数据边从左到右（from.x < to.x）；写边（反馈）除外
    func testLayout_DataEdgesFlowLeftToRight() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        let nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let info = TimelineLayout.computeLayout(of: graph)
        let positions = info.positions

        var sameGroupEdges = 0
        for e in graph.edges where !TimelineGraphValidator.isWriteEdge(e, nodes: nodes) {
            guard let from = positions[e.from.nodeID], let to = positions[e.to.nodeID] else { continue }
            if info.groupOf[e.from.nodeID] == info.groupOf[e.to.nodeID] {
                XCTAssertLessThan(from.x, to.x,
                                  "同组数据边应从左到右: \(e.from.nodeID)→\(e.to.nodeID)")
                sameGroupEdges += 1
            }
        }
        XCTAssertGreaterThan(sameGroupEdges, 0, "布局应覆盖同组数据边")
    }

    /// 无数据入边的节点（数据源/变量/常量）在最左层（x = 0）
    func testLayout_SourcesAtLeftmostLayer() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        let positions = TimelineLayout.layoutPositions(of: graph)
        // touchData / now / value 常量 / varRef 都在层 0
        for node in graph.nodes where node.type == .touchData || node.type == .now || node.type == .value {
            XCTAssertEqual(positions[node.id]?.x, 0, "\(node.type) 数据源应在最左层")
        }
        for node in graph.nodes where node.type == .varRef {
            XCTAssertEqual(positions[node.id]?.x, 0, "varRef 无数据入边应最左")
        }
    }

    /// 同层节点垂直不重叠；所有普通节点都有坐标
    func testLayout_NoOverlapWithinLayer() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        let positions = TimelineLayout.layoutPositions(of: graph)
        XCTAssertEqual(Set(positions.keys), Set(graph.nodes.filter { $0.type != .group }.map(\.id)),
                       "所有普通节点都应有坐标")
        // 同 x（同层）的节点 y 互不相同
        let byX = Dictionary(grouping: positions, by: { $0.value.x })
        for (_, list) in byX {
            let ys = list.map(\.value.y)
            XCTAssertEqual(Set(ys).count, ys.count, "同层节点 y 不应重叠")
        }
    }

    /// group 不参与布局（apply 后 group 坐标不变）
    func testApply_KeepsGroupPosition() {
        var graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        let group = NodeConfig(type: .group, params: NodeParams(groupWidth: 300, groupHeight: 200),
                               x: 999, y: 777, title: "批注")
        graph.nodes.append(group)
        let positions = TimelineLayout.layoutPositions(of: graph)
        XCTAssertNil(positions[group.id], "group 不应参与布局")
        TimelineLayout.apply(positions, to: &graph)
        let after = graph.nodes.first { $0.id == group.id }!
        XCTAssertEqual(after.x, 999)
        XCTAssertEqual(after.y, 777)
    }

    /// 布局后图形状必须拓扑有效（忽略写边）
    func testLayout_GraphStillTopologicallyValid() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        _ = TimelineLayout.layoutPositions(of: graph)
        switch TimelineGraphValidator.topologicalOrder(of: graph, ignoreWriteEdges: true) {
        case .valid(let order):
            XCTAssertEqual(Set(order), Set(graph.nodes.map(\.id)))
        case let result:
            XCTFail("布局不应破坏拓扑: \(result)")
        }
    }
}
