import XCTest
@testable import GestureEngine

final class ConfigMigrationTests: XCTestCase {
    /// 构造一个 v1 格式 JSON（扁平结构，无 version/regions/gestures/events 键）
    private func makeV1JSON() throws -> Data {
        let json = """
        {"frameRateLimit":0,"touchSizeMax":1.0,"touchSizeMin":0.1,
         "edgeRightThreshold":0.85,"edgeLeftThreshold":0.15,
         "tapMaxDuration":0.2,"tapMaxDrift":0.05,"tapMaxGap":0.3,
         "holdMinDuration":0.2,"hapticEnter":2,
         "volumeStepNorm":0.025,"volumeStep":0.02,
         "brightnessStepNorm":0.018,"brightnessStep":0.015,
         "hapticTick":4,"boundaryThreshold":0.002,
         "hapticBoundary":2,"boundaryHapticInterval":60000,
         "disassociateMouse":true}
        """
        return json.data(using: .utf8)!
    }

    func testV1Migration_producesV3Structure() throws {
        let v1Data = try makeV1JSON()
        let v1 = try JSONDecoder().decode(ConfigStore.V1Config.self, from: v1Data)
        let v3 = ConfigStore.migrate(v1: v1)

        XCTAssertEqual(v3.version, 3)
        XCTAssertEqual(v3.regions.count, 2)
        XCTAssertEqual(v3.gestures.count, 2)
        XCTAssertEqual(v3.events.count, 2)
        // 每个手势都迁移出了单张图，含 4 个 Trigger 入口
        for gesture in v3.gestures {
            let triggers = gesture.timeline.nodes
                .filter { $0.type == .trigger }
                .compactMap { $0.params.trigger }
            XCTAssertEqual(Set(triggers),
                           Set([.onFirstTap, .onEnterHolding, .onTick, .onExitHolding]))
        }
    }

    func testV1Migration_edgeThresholdsBecameRegions() throws {
        let v1Data = try makeV1JSON()
        let v1 = try JSONDecoder().decode(ConfigStore.V1Config.self, from: v1Data)
        let v2 = ConfigStore.migrate(v1: v1)

        let left = v2.regions[0]
        XCTAssertEqual(left.xMin, 0)
        XCTAssertEqual(left.xMax, 0.15)

        let right = v2.regions[1]
        XCTAssertEqual(right.xMin, 0.85)
        XCTAssertEqual(right.xMax, 1)
    }

    func testV1Migration_stepsBecameEvents() throws {
        let v1Data = try makeV1JSON()
        let v1 = try JSONDecoder().decode(ConfigStore.V1Config.self, from: v1Data)
        let v2 = ConfigStore.migrate(v1: v1)

        let volume = v2.events.first { $0.actionType == .volume }!
        XCTAssertEqual(volume.step, 0.02)

        let brightness = v2.events.first { $0.actionType == .brightness }!
        XCTAssertEqual(brightness.step, 0.015)
    }

    func testV1Migration_stepNormLandsInTickQuantizeNode() throws {
        let v1Data = try makeV1JSON()
        let v1 = try JSONDecoder().decode(ConfigStore.V1Config.self, from: v1Data)
        let v3 = ConfigStore.migrate(v1: v1)

        // stepNorm 迁移到图的 quantize 节点
        let rightGesture = v3.gestures.first { $0.name == "右侧" }!
        let rightQuantize = rightGesture.timeline.firstNode(of: .quantize)
        XCTAssertEqual(rightQuantize?.params.stepNorm, 0.025)

        let leftGesture = v3.gestures.first { $0.name == "左侧" }!
        let leftQuantize = leftGesture.timeline.firstNode(of: .quantize)
        XCTAssertEqual(leftQuantize?.params.stepNorm, 0.018)
    }

    func testV1Migration_tapParamsLandsInRecognizeNode() throws {
        let v1Data = try makeV1JSON()
        let v1 = try JSONDecoder().decode(ConfigStore.V1Config.self, from: v1Data)
        let v3 = ConfigStore.migrate(v1: v1)

        let rightGesture = v3.gestures.first { $0.name == "右侧" }!
        let recognize = rightGesture.timeline.firstNode(of: .recognize)
        XCTAssertEqual(recognize?.params.tapMaxDuration, 0.2)
        XCTAssertEqual(recognize?.params.tapMaxGap, 0.3)
        XCTAssertEqual(recognize?.params.holdMinDuration, 0.2)
        // 手势识别参数属性从图读取
        XCTAssertEqual(rightGesture.tapMaxDuration, 0.2)
    }

    func testV1Migration_bindingsLandsInRefNodes() throws {
        let v1Data = try makeV1JSON()
        let v1 = try JSONDecoder().decode(ConfigStore.V1Config.self, from: v1Data)
        let v3 = ConfigStore.migrate(v1: v1)

        let leftGesture = v3.gestures.first { $0.name == "左侧" }!
        let leftRegion = v3.regions[0]
        let brightness = v3.events.first { $0.actionType == .brightness }!
        // 绑定写入图的 ref 节点（图权威）
        XCTAssertEqual(leftGesture.timeline.firstNode(of: .region)?.params.regionID, leftRegion.id)
        XCTAssertEqual(leftGesture.timeline.firstNode(of: .event)?.params.eventID, brightness.id)
        // bound 属性从图读取
        XCTAssertEqual(leftGesture.boundRegionID, leftRegion.id)
        XCTAssertEqual(leftGesture.boundEventID, brightness.id)

        let rightGesture = v3.gestures.first { $0.name == "右侧" }!
        let volume = v3.events.first { $0.actionType == .volume }!
        XCTAssertEqual(rightGesture.boundEventID, volume.id)
        XCTAssertEqual(rightGesture.boundRegionID, v3.regions[1].id)
    }

    func testV2CodableRoundTrip() throws {
        let original = AppConfig()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    /// 旧 v3 文件（顶层有绑定、图上无 ref 节点）→ ensureBindingsInGraph 补入图并清空顶层
    func testEnsureBindingsInGraph_BackfillsLegacyTopLevel() throws {
        // 构造旧 v3 手势：顶层绑定 + 图上仅 recognize
        let regionID = UUID()
        let eventID = UUID()
        var gesture = GestureConfig(name: "旧", regionID: regionID, eventID: eventID,
                                    timeline: TimelineConfig(
                                        trigger: .onFirstTap,
                                        nodes: [NodeConfig(type: .recognize,
                                                           params: NodeParams(tapMaxDuration: 0.2))],
                                        entryNodeIDs: [])
                                    )
        // 顶层绑定字段仍回退可用
        XCTAssertEqual(gesture.boundRegionID, regionID)
        XCTAssertEqual(gesture.boundEventID, eventID)

        gesture.ensureBindingsInGraph()
        XCTAssertEqual(gesture.timeline.firstNode(of: .region)?.params.regionID, regionID)
        XCTAssertEqual(gesture.timeline.firstNode(of: .event)?.params.eventID, eventID)
        // 顶层字段已清空，图成为唯一来源
        XCTAssertNil(gesture.regionID)
        XCTAssertNil(gesture.eventID)
        XCTAssertEqual(gesture.boundRegionID, regionID)
        XCTAssertEqual(gesture.boundEventID, eventID)
        // 幂等：再跑一次不重复加节点
        gesture.ensureBindingsInGraph()
        XCTAssertEqual(gesture.timeline.nodes.filter { $0.type == .region }.count, 1)
        XCTAssertEqual(gesture.timeline.nodes.filter { $0.type == .event }.count, 1)
    }

    /// v3 旧 JSON（timelines 数组）→ 自动合并为单图（每个阶段补 Trigger 入口）
    func testV3LegacyTimelinesArray_MergesIntoSingleGraph() throws {
        // 构造 v3 旧格式 JSON（timelines 数组 + 顶层绑定）
        struct V3Legacy: Codable {
            let id: UUID
            let name: String
            let regionID: UUID
            let eventID: UUID
            let timelines: [TimelineConfig]
        }
        // v3 旧格式：4 条独立 timeline（最小结构）
        let v3Timelines = [
            TimelineConfig(trigger: .onFirstTap,
                           nodes: [NodeConfig(type: .recognize,
                                              params: NodeParams(tapMaxDuration: 0.2))],
                           entryNodeIDs: []),
            TimelineConfig(trigger: .onEnterHolding,
                           nodes: [NodeConfig(type: .baseline,
                                              params: NodeParams(key: "startRaw"))],
                           entryNodeIDs: []),
            TimelineConfig(trigger: .onTick,
                           nodes: [NodeConfig(type: .signal,
                                              params: NodeParams(source: .normY))],
                           entryNodeIDs: []),
            TimelineConfig(trigger: .onExitHolding,
                           nodes: [NodeConfig(type: .mouse,
                                              params: NodeParams(mouseMode: .unlockPosition))],
                           entryNodeIDs: []),
        ]
        let legacy = V3Legacy(id: UUID(), name: "旧",
                              regionID: UUID(), eventID: UUID(),
                              timelines: v3Timelines)
        let legacyData = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(GestureConfig.self, from: legacyData)
        // 合并为单图：4 个 Trigger 入口 + 拓扑有效
        let triggers = decoded.timeline.nodes.filter { $0.type == .trigger }
        XCTAssertEqual(Set(triggers.compactMap { $0.params.trigger }),
                       Set([.onFirstTap, .onEnterHolding, .onTick, .onExitHolding]))
        switch TimelineGraphValidator.topologicalOrder(of: decoded.timeline) {
        case .valid: break
        case let result: XCTFail("合并图拓扑失败: \(result)")
        }
    }
}
