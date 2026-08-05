import XCTest
@testable import GestureEngine

final class ModuleTests: XCTestCase {

    /// 构造 module 子图：输入连接器 → scale(×2) → 输出连接器
    private func makeModule(multiplier: Float = 2) -> (main: TimelineConfig, moduleID: UUID, storeKey: String) {
        let inConn = NodeConfig(type: .moduleInput, params: NodeParams(modulePortName: "in"), x: 0, y: 0, title: "in")
        let scale = NodeConfig(type: .scale, params: NodeParams(multiplier: multiplier), x: 200, y: 0, title: "×2")
        let outConn = NodeConfig(type: .moduleOutput, params: NodeParams(modulePortName: "out"), x: 400, y: 0, title: "out")
        let sub = TimelineConfig(trigger: .onTick,
                                 nodes: [inConn, scale, outConn],
                                 edges: [Edge(from: PortID(nodeID: inConn.id, portName: "value"),
                                              to: PortID(nodeID: scale.id, portName: "value")),
                                         Edge(from: PortID(nodeID: scale.id, portName: "result"),
                                              to: PortID(nodeID: outConn.id, portName: "value"))],
                                 entryNodeIDs: [inConn.id])
        let module = NodeConfig(type: .module,
                                params: NodeParams(moduleInputs: [ModulePort(name: "in", type: .float)],
                                                   moduleOutputs: [ModulePort(name: "out", type: .float)]),
                                x: 0, y: 0, title: "×2模块", subgraph: sub)
        let value = NodeConfig(type: .value, params: NodeParams(constant: 3), x: -300, y: 0, title: "3")
        let store = NodeConfig(type: .state, params: NodeParams(key: "out"), x: 300, y: 0, title: "结果")
        let main = TimelineConfig(trigger: .onTick,
                                  nodes: [value, module, store],
                                  edges: [Edge(from: PortID(nodeID: value.id, portName: "value"),
                                               to: PortID(nodeID: module.id, portName: "in")),
                                          Edge(from: PortID(nodeID: module.id, portName: "out"),
                                               to: PortID(nodeID: store.id, portName: "value"))],
                                  entryNodeIDs: [value.id])
        return (main, module.id, "out")
    }

    /// 主图拓扑应有效（module 作为普通节点，端口由声明动态提供）
    func testModule_MainGraphTopologyValid() {
        let (main, _, _) = makeModule()
        switch TimelineGraphValidator.topologicalOrder(of: main, ignoreWriteEdges: true) {
        case .valid(let order):
            XCTAssertEqual(Set(order), Set(main.nodes.map(\.id)))
        case let result:
            XCTFail("主图拓扑失败: \(result)")
        }
    }

    /// 子图执行链路：外部 value(3) → module.in → 内部 scale(×2) → module.out → state = 6
    func testModule_SubgraphExecutesEndToEnd() {
        let (main, _, _) = makeModule()
        guard let evaluator = GraphEvaluator(timeline: main) else { XCTFail("图非法"); return }
        var store: StateStore = [:]
        let effects = MockEffects()
        evaluator.evaluate(frame: FrameContext(), state: &store, effects: effects, entryIDs: nil)
        XCTAssertEqual(store["out"]?.floatValue, 6, "子图应执行：3 × 2 = 6")
    }

    /// 组输入未连线（invalid）→ 组输出 invalid → 下游不写
    func testModule_MissingInputPropagatesInvalid() {
        // 只有 module + state，不连输入
        let inConn = NodeConfig(type: .moduleInput, params: NodeParams(modulePortName: "in"), x: 0, y: 0)
        let scale = NodeConfig(type: .scale, params: NodeParams(multiplier: 2), x: 200, y: 0)
        let outConn = NodeConfig(type: .moduleOutput, params: NodeParams(modulePortName: "out"), x: 400, y: 0)
        let sub = TimelineConfig(trigger: .onTick,
                                 nodes: [inConn, scale, outConn],
                                 edges: [Edge(from: PortID(nodeID: inConn.id, portName: "value"),
                                              to: PortID(nodeID: scale.id, portName: "value")),
                                         Edge(from: PortID(nodeID: scale.id, portName: "result"),
                                              to: PortID(nodeID: outConn.id, portName: "value"))],
                                 entryNodeIDs: [inConn.id])
        let module = NodeConfig(type: .module,
                                params: NodeParams(moduleInputs: [ModulePort(name: "in", type: .float)],
                                                   moduleOutputs: [ModulePort(name: "out", type: .float)]),
                                x: 0, y: 0, subgraph: sub)
        let store = NodeConfig(type: .state, params: NodeParams(key: "out"), x: 300, y: 0)
        let main = TimelineConfig(trigger: .onTick,
                                  nodes: [module, store],
                                  edges: [Edge(from: PortID(nodeID: module.id, portName: "out"),
                                               to: PortID(nodeID: store.id, portName: "value"))],
                                  entryNodeIDs: [module.id])
        guard let evaluator = GraphEvaluator(timeline: main) else { XCTFail("图非法"); return }
        var storeV: StateStore = [:]
        evaluator.evaluate(frame: FrameContext(), state: &storeV, effects: MockEffects(), entryIDs: nil)
        XCTAssertNil(storeV["out"], "组输入缺失 → 输出 invalid → 下游不写")
    }

    /// 子图内副作用（haptic）经 effects 派发
    func testModule_SubgraphSideEffectsDispatch() {
        let inConn = NodeConfig(type: .moduleInput, params: NodeParams(modulePortName: "in"), x: 0, y: 0)
        let haptic = NodeConfig(type: .haptic, params: NodeParams(waveform: 4, count: 1, intervalUs: 0, async: true),
                                x: 200, y: 0, title: "震动")
        let outConn = NodeConfig(type: .moduleOutput, params: NodeParams(modulePortName: "out"), x: 400, y: 0)
        let sub = TimelineConfig(trigger: .onTick,
                                 nodes: [inConn, haptic, outConn],
                                 edges: [Edge(from: PortID(nodeID: inConn.id, portName: "value"),
                                              to: PortID(nodeID: haptic.id, portName: "trigger")),
                                         Edge(from: PortID(nodeID: haptic.id, portName: "result"),
                                              to: PortID(nodeID: outConn.id, portName: "value"))],
                                 entryNodeIDs: [inConn.id])
        let module = NodeConfig(type: .module,
                                params: NodeParams(moduleInputs: [ModulePort(name: "in", type: .float)],
                                                   moduleOutputs: [ModulePort(name: "out", type: .unit)]),
                                x: 0, y: 0, subgraph: sub)
        let value = NodeConfig(type: .value, params: NodeParams(constant: 3), x: -300, y: 0, title: "3")
        let main = TimelineConfig(trigger: .onTick,
                                  nodes: [value, module],
                                  edges: [Edge(from: PortID(nodeID: value.id, portName: "value"),
                                               to: PortID(nodeID: module.id, portName: "in"))],
                                  entryNodeIDs: [value.id])
        guard let evaluator = GraphEvaluator(timeline: main) else { XCTFail("图非法"); return }
        var storeV: StateStore = [:]
        let effects = MockEffects()
        evaluator.evaluate(frame: FrameContext(), state: &storeV, effects: effects, entryIDs: nil)
        XCTAssertEqual(effects.hapticCalls.count, 1, "子图内 haptic 应触发")
        XCTAssertEqual(effects.hapticCalls.first?.waveform, 4)
    }

    // MARK: - 端口注册表

    func testModule_DynamicPortsFromDeclaration() {
        let module = NodeConfig(type: .module,
                                params: NodeParams(moduleInputs: [ModulePort(name: "a", type: .float),
                                                                  ModulePort(name: "b", type: .unit)],
                                                   moduleOutputs: [ModulePort(name: "x", type: .bool)]))
        XCTAssertEqual(NodeTypeDef.inputSockets(of: module).map(\.name), ["a", "b"])
        XCTAssertEqual(NodeTypeDef.inputSockets(of: module).map(\.type), [.float, .unit])
        XCTAssertEqual(NodeTypeDef.outputSockets(of: module).map(\.name), ["x"])
        XCTAssertEqual(NodeTypeDef.outputSockets(of: module).first?.type, .bool)
        // 连接器：moduleInput 输出 value(generic)；moduleOutput 输入 value(generic)
        let input = NodeConfig(type: .moduleInput)
        XCTAssertEqual(NodeTypeDef.outputSockets(of: input).map(\.name), ["value"])
        let output = NodeConfig(type: .moduleOutput)
        XCTAssertEqual(NodeTypeDef.inputSockets(of: output).map(\.name), ["value"])
    }
}
