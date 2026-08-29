import XCTest
@testable import GestureEngine

/// H2 回归：module 节点嵌套子图的解析/写回/补全。
/// 根因：addNode 创建的 module subgraph 为 nil，openModule 无 guard，updatingTimeline path.count==1
/// 无条件写 subgraph=newValue → 把父内容塞进子图（自引用/数据损坏）。这些逻辑是纯数据操作，可在模型层测。
final class TimelineSubgraphNavigationTests: XCTestCase {

    private func makeRoot(subgraph: TimelineConfig? = nil) -> (root: TimelineConfig, moduleID: UUID) {
        let module = NodeConfig(type: .module, x: 0, y: 0, subgraph: subgraph)
        let value = NodeConfig(type: .value, params: NodeParams(constant: 1), x: -200, y: 0)
        let root = TimelineConfig(trigger: .onTick,
                                 nodes: [value, module],
                                 edges: [Edge(from: PortID(nodeID: value.id, portName: "value"),
                                              to: PortID(nodeID: module.id, portName: "in"))],
                                 entryNodeIDs: [value.id])
        return (root, module.id)
    }

    func testSubgraphAt_EmptyPath_ReturnsRoot() {
        let (root, _) = makeRoot()
        XCTAssertEqual(root.subgraph(at: [])?.id, root.id)
    }

    func testSubgraphAt_ValidModule_ReturnsSub() {
        let sub = TimelineConfig(trigger: .onTick)
        let (root, mid) = makeRoot(subgraph: sub)
        XCTAssertEqual(root.subgraph(at: [mid])?.id, sub.id)
    }

    func testSubgraphAt_ModuleWithoutSubgraph_ReturnsNil() {
        let (root, mid) = makeRoot(subgraph: nil)
        XCTAssertNil(root.subgraph(at: [mid]), "无子图的 module 应解析为 nil，绝不能回退成根图")
    }

    func testSubgraphAt_UnknownNode_ReturnsNil() {
        let (root, _) = makeRoot()
        XCTAssertNil(root.subgraph(at: [UUID()]), "路径上的节点缺失应返回 nil")
    }

    func testUpdatingSubgraph_WritesIntoExistingModuleSubgraph() {
        let sub = TimelineConfig(trigger: .onTick)
        let (root, mid) = makeRoot(subgraph: sub)
        var edited = sub
        edited.nodes.append(NodeConfig(type: .value, params: NodeParams(constant: 9), x: 0, y: 0))
        let newRoot = root.updatingSubgraph(at: [mid], to: edited)
        XCTAssertEqual(newRoot.nodes.first(where: { $0.id == mid })?.subgraph?.id, edited.id)
    }

    func testUpdatingSubgraph_EmptyPath_ReturnsNewValue() {
        let (root, _) = makeRoot()
        let edited = TimelineConfig(trigger: .onTick)
        XCTAssertEqual(root.updatingSubgraph(at: [], to: edited).id, edited.id)
    }

    func testUpdatingSubgraph_ModuleWithoutSubgraph_DoesNotSelfReference() {
        let (root, mid) = makeRoot(subgraph: nil)
        let edited = root
        let newRoot = root.updatingSubgraph(at: [mid], to: edited)
        let node = newRoot.nodes.first(where: { $0.id == mid })
        XCTAssertNil(node?.subgraph, "无子图的 module 不应被塞入父内容（防自引用），应保持 nil")
    }

    func testEnsuringModuleSubgraphs_FillsMissingSubgraph() {
        let (root, mid) = makeRoot(subgraph: nil)
        let fixed = root.ensuringModuleSubgraphs()
        XCTAssertNotNil(fixed.nodes.first(where: { $0.id == mid })?.subgraph, "应补上空子图")
        XCTAssertNotNil(fixed.subgraph(at: [mid]), "补全后应能正常进入 module")
        XCTAssertNil(root.nodes.first(where: { $0.id == mid })?.subgraph, "原对象不改（值语义）")
    }

    func testEnsuringModuleSubgraphs_LeavesExistingSubgraph() {
        let sub = TimelineConfig(trigger: .onTick, nodes: [NodeConfig(type: .value, params: NodeParams(constant: 1), x: 0, y: 0)])
        let (root, mid) = makeRoot(subgraph: sub)
        let fixed = root.ensuringModuleSubgraphs()
        XCTAssertEqual(fixed.nodes.first(where: { $0.id == mid })?.subgraph?.nodes.count, 1)
    }
}
