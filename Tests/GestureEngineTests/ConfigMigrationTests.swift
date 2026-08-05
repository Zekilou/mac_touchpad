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
        // 每个手势都迁移出了单张图（v8 状态机展开：无 pipeOut，有 varRef 变量 + finger 物理层）
        for gesture in v3.gestures {
            let tl = gesture.timeline
            XCTAssertTrue(tl.nodes.filter { $0.type == .pipeOut }.isEmpty)
            XCTAssertNil(tl.firstNode(of: .recognizer))
            XCTAssertNotNil(tl.firstNode(of: .finger))
            XCTAssertNotNil(tl.firstNode(of: .varRef))
            XCTAssertNotNil(tl.firstNode(of: .touchData))
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

    func testV1Migration_tapParamsLandsInGraphThresholds() throws {
        let v1Data = try makeV1JSON()
        let v1 = try JSONDecoder().decode(ConfigStore.V1Config.self, from: v1Data)
        let v3 = ConfigStore.migrate(v1: v1)

        let rightGesture = v3.gestures.first { $0.name == "右侧" }!
        // v8：识别参数固化为图上 compare threshold（按下超时 0.2 / 保持 0.2 / 间隔 0.3；阈值节点在模块子图内）
        let thresholds = rightGesture.timeline.allNodes.compactMap { $0.params.threshold }
        XCTAssertTrue(thresholds.contains(Float(0.2)), "按下超时/保持时长阈值应在图上")
        XCTAssertTrue(thresholds.contains(Float(0.3)), "间隔阈值应在图上")
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
        // 构造旧 v3 手势：顶层绑定 + 图上仅 recognizer
        let regionID = UUID()
        let eventID = UUID()
        var gesture = GestureConfig(name: "旧", regionID: regionID, eventID: eventID,
                                    timeline: TimelineConfig(
                                        trigger: .onFirstTap,
                                        nodes: [NodeConfig(type: .recognizer,
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
                           nodes: [NodeConfig(type: .recognizer,
                                              params: NodeParams(tapMaxDuration: 0.2))],
                           entryNodeIDs: []),
            TimelineConfig(trigger: .onEnterHolding,
                           nodes: [NodeConfig(type: .baseline,
                                              params: NodeParams(key: "startRaw"))],
                           entryNodeIDs: []),
            TimelineConfig(trigger: .onTick,
                           nodes: [NodeConfig(type: .touchData)],
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
        // 合并为单图：4 个管道出口入口 + 拓扑有效
        let triggers = decoded.timeline.nodes.filter { $0.type == .pipeOut }
        XCTAssertEqual(Set(triggers.compactMap { $0.params.trigger }),
                       Set([.onFirstTap, .onEnterHolding, .onTick, .onExitHolding]))
        switch TimelineGraphValidator.topologicalOrder(of: decoded.timeline) {
        case .valid: break
        case let result: XCTFail("合并图拓扑失败: \(result)")
        }
    }

    // MARK: - signal → touchData 兼容（P2）

    /// 旧 JSON 里 "type":"signal"（单选信号源）解码映射为 touchData（唯一多输出数据源）
    func testLegacySignalTypeDecodesToTouchData() throws {
        let json = """
        {"type":"signal","params":{"source":"normY"},"x":0,"y":0,"id":"00000000-0000-0000-0000-000000000001"}
        """
        let node = try JSONDecoder().decode(NodeConfig.self, from: Data(json.utf8))
        XCTAssertEqual(node.type, .touchData)
    }

    /// normalize：旧 signal 节点的输出连线 "value" → source 对应字段端口（normY），并清掉单选 source 参数
    func testNormalizeLegacySignalEdgePort() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000010","name":"g",
         "timeline":{"id":"00000000-0000-0000-0000-000000000011","trigger":"onTick",
          "nodes":[
            {"id":"00000000-0000-0000-0000-0000000000A1","type":"trigger","params":{"trigger":"onTick"},"x":0,"y":0},
            {"id":"00000000-0000-0000-0000-0000000000A2","type":"signal","params":{"source":"normY"},"x":0,"y":0},
            {"id":"00000000-0000-0000-0000-0000000000A3","type":"transform","params":{},"x":150,"y":0},
            {"id":"00000000-0000-0000-0000-0000000000A4","type":"quantize","params":{},"x":300,"y":0}
          ],
          "edges":[
            {"from":{"nodeID":"00000000-0000-0000-0000-0000000000A1","portName":"output"},
             "to":{"nodeID":"00000000-0000-0000-0000-0000000000A2","portName":"input"}},
            {"from":{"nodeID":"00000000-0000-0000-0000-0000000000A2","portName":"value"},
             "to":{"nodeID":"00000000-0000-0000-0000-0000000000A3","portName":"input"}},
            {"from":{"nodeID":"00000000-0000-0000-0000-0000000000A3","portName":"output"},
             "to":{"nodeID":"00000000-0000-0000-0000-0000000000A4","portName":"input"}}
          ],
          "entryNodeIDs":["00000000-0000-0000-0000-0000000000A1"]}}
        """
        let config = try JSONDecoder().decode(GestureConfig.self, from: Data(json.utf8))
        let touchData = config.timeline.firstNode(of: .touchData)
        let transformID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!
        let quantizeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")!
        XCTAssertNotNil(touchData)
        // 单选 source 参数已清理（touchData 是多输出）
        XCTAssertNil(touchData?.params.source)
        // 下游连线端口 "value" → "normY"
        XCTAssertTrue(config.timeline.edges.contains {
            $0.from == PortID(nodeID: touchData!.id, portName: "normY")
                && $0.to == PortID(nodeID: transformID, portName: "value")
        })
        // 旧端口名迁移：trigger.output→touchData（注入）、transform.output→quantize.input
        let triggerID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        XCTAssertTrue(config.timeline.edges.contains {
            $0.from == PortID(nodeID: triggerID, portName: "trigger")
                && $0.to == PortID(nodeID: touchData!.id, portName: "trigger")
        })
        XCTAssertTrue(config.timeline.edges.contains {
            $0.from == PortID(nodeID: transformID, portName: "result")
                && $0.to == PortID(nodeID: quantizeID, portName: "value")
        })
        // 旧的 "value"/"output"/"input" 端口连线已全部替换
        XCTAssertFalse(config.timeline.edges.contains { $0.from.portName == "value" || $0.from.portName == "output" })
        XCTAssertFalse(config.timeline.edges.contains { $0.to.portName == "input" })
    }

    // MARK: - GlobalSettings 向后兼容（v10.21 新增 palmFilter）

    /// 旧 config.json 的 global 缺 palmFilter → decode 不失败，回退默认 true（否则用户配置全丢）
    func testGlobalSettingsMissingPalmFilterDecodesWithDefault() throws {
        let json = """
        {"frameRateLimit":0,"touchSizeMin":0.1,"touchSizeMax":1.35}
        """
        let data = json.data(using: .utf8)!
        let g = try JSONDecoder().decode(GlobalSettings.self, from: data)
        XCTAssertEqual(g.touchSizeMax, 1.35)
        XCTAssertEqual(g.palmFilter, true, "旧配置缺 palmFilter 应回退默认 true（手掌过滤开）")
    }

    func testGlobalSettingsPalmFilterRoundTrip() throws {
        var g = GlobalSettings()
        g.palmFilter = false
        g.touchSizeMax = 1.5
        let data = try JSONEncoder().encode(g)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)
        XCTAssertEqual(decoded.palmFilter, false)
        XCTAssertEqual(decoded.touchSizeMax, 1.5)
    }

    /// syncingFingerSizes 同步 palmFilter 到 finger 节点（含递归子图）
    func testSyncingFingerSizesSyncsPalmFilter() {
        let finger = NodeConfig(type: .finger, x: 0, y: 0)
        let tl = TimelineConfig(trigger: .onFirstTap, nodes: [finger], entryNodeIDs: [finger.id])
        let synced = ConfigStore.syncingFingerSizes(tl, sizeMin: 0.1, sizeMax: 1.35, palmFilter: false)
        XCTAssertEqual(synced.nodes.first?.params.palmFilter, false)
        XCTAssertEqual(synced.nodes.first?.params.touchSizeMax, 1.35)
    }
}
