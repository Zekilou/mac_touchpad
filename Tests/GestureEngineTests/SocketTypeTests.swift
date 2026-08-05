import XCTest
@testable import GestureEngine

/// P1：Socket 类型系统 + 节点端口注册表
final class SocketTypeTests: XCTestCase {

    // MARK: - SocketType Codable

    func testSocketTypeCodableRoundTrip() throws {
        for type in SocketType.allCases {
            let data = try JSONEncoder().encode(type)
            let decoded = try JSONDecoder().decode(SocketType.self, from: data)
            XCTAssertEqual(decoded, type)
        }
    }

    // MARK: - 端口注册表完整性

    /// 每个 NodeType 都能查到输入/输出端口（switch 全覆盖由编译器保证，此处防 nil/空意外）
    func testAllNodeTypesHavePortDeclarations() {
        for type in NodeType.allCases {
            _ = NodeTypeDef.inputSockets(of: type)
            _ = NodeTypeDef.outputSockets(of: type)
        }
    }

    /// 同一侧端口名唯一（防重复声明导致数据覆盖）
    func testPortNamesUniquePerSide() {
        for type in NodeType.allCases {
            let inputs = NodeTypeDef.inputSockets(of: type).map(\.name)
            let outputs = NodeTypeDef.outputSockets(of: type).map(\.name)
            XCTAssertEqual(Set(inputs).count, inputs.count, "\(type) 输入端口名重复: \(inputs)")
            XCTAssertEqual(Set(outputs).count, outputs.count, "\(type) 输出端口名重复: \(outputs)")
        }
    }

    /// 纯参数节点（event/group）无任何端口；recognizer 有脉冲输出、pipeOut 有 trigger 输入、region 输出区域数据
    func testParameterNodesHaveNoPorts() {
        for type in [NodeType.event, .group] {
            XCTAssertTrue(NodeTypeDef.inputSockets(of: type).isEmpty, "\(type) 不应有输入端口")
            XCTAssertTrue(NodeTypeDef.outputSockets(of: type).isEmpty, "\(type) 不应有输出端口")
        }
        // recognizer：fingers+region 输入，5 个输出（4 脉冲 + isHolding）
        XCTAssertEqual(NodeTypeDef.inputSockets(of: .recognizer).map(\.type), [.fingers, .region])
        XCTAssertEqual(NodeTypeDef.outputSockets(of: .recognizer).map(\.type),
                       [.unit, .unit, .unit, .unit, .bool])
        // pipeOut：trigger 输入 → trigger 输出（透传）
        XCTAssertEqual(NodeTypeDef.inputSockets(of: .pipeOut), [SocketDef(name: "trigger", type: .unit)])
        XCTAssertEqual(NodeTypeDef.outputSockets(of: .pipeOut), [SocketDef(name: "trigger", type: .unit)])
        // region：输出 region 数据（给识别器）
        XCTAssertEqual(NodeTypeDef.outputSockets(of: .region), [SocketDef(name: "region", type: .region)])
    }

    /// 数据源纯输出：touchData 无输入，输出 6 信号 + fingers
    func testTouchDataIsPureOutput() {
        XCTAssertTrue(NodeTypeDef.inputSockets(of: .touchData).isEmpty, "触控板数据是数据源，不应有输入")
        let outputs = NodeTypeDef.outputSockets(of: .touchData).map(\.name)
        XCTAssertEqual(Set(outputs), Set(["normX", "normY", "size", "pressure", "velX", "velY", "fingers"]))
    }

    /// 变量操作节点：set(trigger+value → result)、toggle(trigger → result)
    func testSetTogglePorts() {
        XCTAssertEqual(NodeTypeDef.inputSockets(of: .set).map(\.type), [.unit, .generic])
        XCTAssertEqual(NodeTypeDef.outputSockets(of: .set), [SocketDef(name: "result", type: .unit)])
        XCTAssertEqual(NodeTypeDef.inputSockets(of: .toggle).map(\.type), [.unit])
        XCTAssertEqual(NodeTypeDef.outputSockets(of: .toggle), [SocketDef(name: "result", type: .unit)])
    }

    /// 副作用节点输入为 unit 事件脉冲（haptic/mouse/freeze/notify）
    func testSideEffectNodesTriggerOnUnit() {
        for type in [NodeType.haptic, .mouse, .freeze, .notify] {
            let inputs = NodeTypeDef.inputSockets(of: type)
            XCTAssertEqual(inputs.map(\.type), [.unit], "\(type) 输入应为 unit")
            let outputs = NodeTypeDef.outputSockets(of: type)
            XCTAssertEqual(outputs.map(\.type), [.unit], "\(type) 输出应为 unit")
        }
    }

    // MARK: - 连线类型匹配

    func testCanConnectSameType() {
        for type in SocketType.allCases where type != .generic {
            XCTAssertTrue(NodeTypeDef.canConnect(from: type, to: type), "\(type) 应能连自己")
        }
    }

    func testCanConnectRejectsMismatch() {
        XCTAssertFalse(NodeTypeDef.canConnect(from: .float, to: .bool))
        XCTAssertFalse(NodeTypeDef.canConnect(from: .output, to: .unit))
        XCTAssertFalse(NodeTypeDef.canConnect(from: .int, to: .float))
    }

    /// generic 与任何类型匹配（路由器/分流）
    func testCanConnectGenericMatchesAny() {
        for type in SocketType.allCases {
            XCTAssertTrue(NodeTypeDef.canConnect(from: .generic, to: type))
            XCTAssertTrue(NodeTypeDef.canConnect(from: type, to: .generic))
        }
    }

    // MARK: - 关键节点端口形状（Blender 风格：类型 → 形状 → 可连性）

    /// 路由器：cond(generic，bool 或 unit/output 脉冲) + value(generic) → out1/out2(generic)
    func testBranchRouterPorts() {
        let inputs = NodeTypeDef.inputSockets(of: .branch)
        XCTAssertEqual(inputs, [
            SocketDef(name: "cond", type: .generic),
            SocketDef(name: "value", type: .generic),
        ])
        let outputs = NodeTypeDef.outputSockets(of: .branch)
        XCTAssertEqual(outputs, [
            SocketDef(name: "out1", type: .generic),
            SocketDef(name: "out2", type: .generic),
        ])
    }

    /// consume：data(output) → result(unit)（消费数据，产出事件脉冲）
    func testConsumePorts() {
        XCTAssertEqual(NodeTypeDef.inputSockets(of: .consume), [SocketDef(name: "data", type: .output)])
        XCTAssertEqual(NodeTypeDef.outputSockets(of: .consume), [SocketDef(name: "result", type: .unit)])
    }

    /// quantize：value(float) → tick(output)
    func testQuantizePorts() {
        XCTAssertEqual(NodeTypeDef.inputSockets(of: .quantize), [SocketDef(name: "value", type: .float)])
        XCTAssertEqual(NodeTypeDef.outputSockets(of: .quantize), [SocketDef(name: "tick", type: .output)])
    }

    // MARK: - SocketValue（值 + valid）

    func testSocketValueFactories() {
        XCTAssertEqual(SocketValue.unit(), SocketValue(valid: true, value: .unit))
        XCTAssertEqual(SocketValue.invalid(), SocketValue(valid: false, value: .unit))
        XCTAssertEqual(SocketValue.float(1.5), SocketValue(valid: true, value: .float(1.5)))
        XCTAssertEqual(SocketValue.bool(true), SocketValue(valid: true, value: .bool(true)))
        XCTAssertEqual(SocketValue.output(.tick(direction: 1, count: 2)),
                       SocketValue(valid: true, value: .output(.tick(direction: 1, count: 2))))
        // valid 是独立于值的存在性标记
        XCTAssertNotEqual(SocketValue.float(0), SocketValue.invalid())
    }

    /// valid = 有没有数据（存在性），与值大小无关
    func testValidSemantics() {
        XCTAssertTrue(SocketValue.float(0).valid, "值为 0 也是有效数据（有数据）")
        XCTAssertTrue(SocketValue.float(-1).valid)
        XCTAssertTrue(SocketValue.bool(false).valid, "值为 false 也是有效数据")
        XCTAssertFalse(SocketValue.invalid().valid, "只有未产出才是 invalid")
    }

    // MARK: - 透传类型推导（generic 端口沿数据流确定实际类型）

    /// branch.value 输入连 float 源 → out1/out2 推导为 float（六边形内嵌圆●）
    func testResolvedPortTypeBranchPassthrough() {
        let src = NodeConfig(type: .value)   // 输出 value: float
        let br = NodeConfig(type: .branch)   // cond/value 输入（generic），out1/out2 输出（generic）
        let tl = TimelineConfig(trigger: .onTick, nodes: [src, br], edges: [
            Edge(from: PortID(nodeID: src.id, portName: "value"),
                 to: PortID(nodeID: br.id, portName: "value")),
        ])
        XCTAssertEqual(tl.resolvedPortType(of: br.id, port: "out1", isInput: false), .float)
        XCTAssertEqual(tl.resolvedPortType(of: br.id, port: "out2", isInput: false), .float)
        // 输入端口：看入边对端输出类型
        XCTAssertEqual(tl.resolvedPortType(of: br.id, port: "value", isInput: true), .float)
        // cond 无入边 → 推导不出 → nil（UI 显示纯空心六边形 any）
        XCTAssertNil(tl.resolvedPortType(of: br.id, port: "cond", isInput: true))
    }

    /// 递归链：value → branch → split，split 输出透传 float（对端是 generic 继续递归）
    func testResolvedPortTypeRecursiveChain() {
        let src = NodeConfig(type: .value)
        let br = NodeConfig(type: .branch)
        let sp = NodeConfig(type: .split)
        let tl = TimelineConfig(trigger: .onTick, nodes: [src, br, sp], edges: [
            Edge(from: PortID(nodeID: src.id, portName: "value"),
                 to: PortID(nodeID: br.id, portName: "value")),
            Edge(from: PortID(nodeID: br.id, portName: "out1"),
                 to: PortID(nodeID: sp.id, portName: "value")),
        ])
        XCTAssertEqual(tl.resolvedPortType(of: sp.id, port: "out1", isInput: false), .float)
        XCTAssertEqual(tl.resolvedPortType(of: sp.id, port: "out2", isInput: false), .float)
    }

    /// 非 generic 端口返回自身声明类型（不需要推导）
    func testResolvedPortTypeNonGenericReturnsDeclared() {
        let q = NodeConfig(type: .quantize)
        let tl = TimelineConfig(trigger: .onTick, nodes: [q])
        XCTAssertEqual(tl.resolvedPortType(of: q.id, port: "tick", isInput: false), .output)
        XCTAssertEqual(tl.resolvedPortType(of: q.id, port: "value", isInput: true), .float)
    }

    /// 无入边 / 环 → 推导不出 → nil
    func testResolvedPortTypeUnresolvedAndCycle() {
        // 孤立 branch：无入边 → out1 推导不出
        let br = NodeConfig(type: .branch)
        let tl1 = TimelineConfig(trigger: .onTick, nodes: [br])
        XCTAssertNil(tl1.resolvedPortType(of: br.id, port: "out1", isInput: false))
        // 自环（out1 → value）：递归遇环 → 深度上限 → nil（不死循环）
        let tl2 = TimelineConfig(trigger: .onTick, nodes: [br], edges: [
            Edge(from: PortID(nodeID: br.id, portName: "out1"),
                 to: PortID(nodeID: br.id, portName: "value")),
        ])
        XCTAssertNil(tl2.resolvedPortType(of: br.id, port: "out1", isInput: false))
    }

    // MARK: - 多选 / 复制粘贴 / 框选（纯逻辑）

    /// 复制：只取选中节点 + 两端都在选中集内的边（连到集外的边不复制）
    func testClipSelectionKeepsInternalEdgesOnly() {
        let a = NodeConfig(type: .value)
        let b = NodeConfig(type: .transform)
        let c = NodeConfig(type: .value)
        let tl = TimelineConfig(trigger: .onTick, nodes: [a, b, c], edges: [
            Edge(from: PortID(nodeID: a.id, portName: "value"),
                 to: PortID(nodeID: b.id, portName: "value")),   // 内部边：保留
            Edge(from: PortID(nodeID: b.id, portName: "result"),
                 to: PortID(nodeID: c.id, portName: "value")),   // 连到集外：不复制
        ])
        let clip = tl.clipSelection([a.id, b.id])
        XCTAssertEqual(clip.nodes.count, 2)
        XCTAssertEqual(clip.edges.count, 1)
        XCTAssertEqual(clip.edges[0].to.nodeID, b.id)
    }

    /// 粘贴：新 UUID + 边重映射 + 整体偏移
    func testPasteClipRemapsIDsAndOffsets() {
        let a = NodeConfig(type: .value, x: 10, y: 20)
        let b = NodeConfig(type: .transform, x: 200, y: 20)
        let tl = TimelineConfig(trigger: .onTick, nodes: [a, b], edges: [
            Edge(from: PortID(nodeID: a.id, portName: "value"),
                 to: PortID(nodeID: b.id, portName: "value")),
        ])
        let (newNodes, newEdges) = tl.pasteClip([a, b], tl.edges, dx: 24, dy: 24)
        XCTAssertEqual(newNodes.count, 2)
        XCTAssertEqual(newEdges.count, 1)
        let oldIDs = Set([a.id, b.id])
        let newIDs = Set(newNodes.map(\.id))
        XCTAssertTrue(newIDs.intersection(oldIDs).isEmpty, "粘贴节点必须生成新 UUID")
        XCTAssertEqual(newIDs.count, 2)
        XCTAssertEqual(newNodes[0].x, 34)
        XCTAssertEqual(newNodes[0].y, 44)
        XCTAssertTrue(newIDs.contains(newEdges[0].from.nodeID), "边起点重映射到新 id")
        XCTAssertTrue(newIDs.contains(newEdges[0].to.nodeID), "边终点重映射到新 id")
    }

    /// 框选命中：rect 与节点矩形相交（节点卡片 + 组框都算）
    func testNodesInRect() {
        let a = NodeConfig(type: .value, x: 0, y: 0)
        let b = NodeConfig(type: .transform, x: 200, y: 0)
        let g = NodeConfig(type: .group, x: 0, y: 300)  // group 默认 300×200
        let tl = TimelineConfig(trigger: .onTick, nodes: [a, b, g])
        XCTAssertEqual(tl.nodes(in: CGRect(x: -10, y: -10, width: 150, height: 150), nodeWidth: 170), [a.id])
        XCTAssertEqual(tl.nodes(in: CGRect(x: -10, y: 290, width: 100, height: 130), nodeWidth: 170), [g.id])
        XCTAssertTrue(tl.nodes(in: CGRect(x: 500, y: 500, width: 10, height: 10), nodeWidth: 170).isEmpty)
        // 零尺寸矩形不命中
        XCTAssertTrue(tl.nodes(in: CGRect(x: 0, y: 0, width: 0, height: 0), nodeWidth: 170).isEmpty)
    }
}
