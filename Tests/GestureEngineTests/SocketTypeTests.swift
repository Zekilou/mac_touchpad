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

    /// 路由器：cond(bool) + value(generic) → out1/out2(generic)
    func testBranchRouterPorts() {
        let inputs = NodeTypeDef.inputSockets(of: .branch)
        XCTAssertEqual(inputs, [
            SocketDef(name: "cond", type: .bool),
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
}
