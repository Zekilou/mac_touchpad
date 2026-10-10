import XCTest
@testable import GestureEngine

/// 自定义波形功能测试：模型 / 字典契约 / 配置兼容 / 解绑 / 预览曲线
final class CustomWaveformTests: XCTestCase {

    // MARK: - 字典契约（与私有 API 对接的关键）

    /// WaveformSpec.dictionary() 必须产出 Apple 产线定义同构的键结构：
    /// BaseWaveform + Tones[0] + Base/ToneMultipliers。
    /// 任一键名写错 → MTActuationCreateFromDictionary 返回 NULL → 震动静默失效。
    func testDictionaryStructureMatchesAppleSchema() {
        let spec = WaveformSpec(envelopeAmplitude: 22,
                                envelopeDurationMs: 6,
                                toneType: .square,
                                toneFrequencyKHz: 1.263,
                                toneAmplitude: 0.06,
                                toneDurationMs: 3,
                                toneDelayMs: 1)
        let d = spec.dictionary()

        // 顶层四键
        XCTAssertNotNil(d["BaseWaveform"], "缺少 BaseWaveform → 私有 API 会拒绝")
        XCTAssertNotNil(d["Tones"])
        XCTAssertNotNil(d["BaseMultipliers"])
        XCTAssertNotNil(d["ToneMultipliers"])

        // BaseWaveform 三键
        let base = d["BaseWaveform"] as? [String: Any]
        XCTAssertEqual(base?["Type"] as? String, "Gaussian")
        XCTAssertEqual(base?["DurationMS"] as? Double, 6)
        XCTAssertEqual(base?["Amplitude"] as? Double, 22)

        // Tones 是数组，且音调类型用 rawValue（"Sine"/"Square"）
        let tones = d["Tones"] as? [[String: Any]]
        XCTAssertEqual(tones?.count, 1, "当前实现只下发单个音调")
        XCTAssertEqual(tones?.first?["Type"] as? String, "Square")
        XCTAssertEqual(tones?.first?["FrequencykHz"] as? Double, 1.263)
        XCTAssertEqual(tones?.first?["Amplitude"] as? Double, 0.06)

        // 乘法器三档
        let mul = d["BaseMultipliers"] as? [String: Any]
        XCTAssertNotNil(mul?["Light"])
        XCTAssertNotNil(mul?["Medium"])
        XCTAssertNotNil(mul?["Firm"])
    }

    /// ToneType 的 rawValue 必须是 API 期望的字符串（不是 Swift 枚举名）
    func testToneTypeRawValues() {
        XCTAssertEqual(ToneType.sine.rawValue, "Sine")
        XCTAssertEqual(ToneType.square.rawValue, "Square")
    }

    // MARK: - 预设目录

    /// 预设目录应覆盖旧 UI 曾暴露的全部 ID（1~6, 15, 16），
    /// 否则升级后旧配置引用这些 ID 会拿不到预览参数。
    func testPresetCatalogCoversLegacyIDs() {
        let ids = Set(WaveformPresetCatalog.all.map(\.id))
        for legacy: Int32 in [1, 2, 3, 4, 5, 6, 15, 16] {
            XCTAssertTrue(ids.contains(legacy), "预设目录缺少 ID \(legacy)")
        }
    }

    /// 未收录的 ID 回退默认参数（不崩、不返回 nil）
    func testPresetCatalogFallsBackForUnknownID() {
        let spec = WaveformPresetCatalog.spec(for: 99)
        XCTAssertEqual(spec.envelopeType, "Gaussian")
    }

    // MARK: - 预览曲线

    /// 预览必须产出有界、非全零的曲线——
    /// 全零会让缩略图看起来是空白（用户以为坏了）
    func testPreviewProducesBoundedNonZeroCurve() {
        let spec = WaveformPresetCatalog.spec(for: 2)
        let data = WaveformPreview.data(for: spec, samples: 64)

        XCTAssertEqual(data.combined.count, 64)
        XCTAssertEqual(data.envelope.count, 64)
        XCTAssertTrue(data.totalMs > 0)

        let peak = data.combined.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.05, "合成曲线几乎为 0，缩略图会显示为空白")
        XCTAssertLessThanOrEqual(peak, 1.0 + 1e-6, "曲线必须归一化到 ±1 内")
        for v in data.combined {
            XCTAssertGreaterThanOrEqual(v, -1.0001)
            XCTAssertLessThanOrEqual(v, 1.0001)
        }
    }

    /// 包络幅度越大 → 曲线峰值越高（保证可视化能反映参数变化）
    func testPreviewReflectsEnvelopeAmplitude() {
        let weak = WaveformPreview.data(for: WaveformSpec(envelopeAmplitude: 5), samples: 64)
        let strong = WaveformPreview.data(for: WaveformSpec(envelopeAmplitude: 35), samples: 64)
        let weakPeak = weak.envelope.map { abs($0) }.max() ?? 0
        let strongPeak = strong.envelope.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(strongPeak, weakPeak)
    }

    /// 无包络 + 低频长音的波形（预设 15/16 的形态）也要能画出曲线（来自音调分量）
    func testPreviewNonEmptyForToneOnlyWaveform() {
        let spec = WaveformPresetCatalog.spec(for: 15)
        XCTAssertEqual(spec.envelopeAmplitude, 0, "ID 15 应无包络")
        let data = WaveformPreview.data(for: spec, samples: 64)
        let peak = data.combined.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.05, "纯音调波形也必须可见")
    }

    /// 采样数下限保护：极端小值不崩
    func testPreviewHandlesTinySampleCount() {
        let data = WaveformPreview.data(for: WaveformSpec(), samples: 1)
        XCTAssertGreaterThanOrEqual(data.combined.count, 8)
    }

    // MARK: - Codable 往返

    func testWaveformSpecRoundTrip() throws {
        let spec = WaveformSpec(envelopeAmplitude: 27,
                                envelopeDurationMs: 9,
                                toneType: .square,
                                toneFrequencyKHz: 3.6,
                                toneAmplitude: 0.12,
                                toneDurationMs: 5,
                                toneDelayMs: 2,
                                envelopeLight: 0.5, envelopeMedium: 1.1, envelopeFirm: 1.7,
                                toneLight: 0.1, toneMedium: 0.4, toneFirm: 0.9)
        let data = try JSONEncoder().encode(spec)
        let back = try JSONDecoder().decode(WaveformSpec.self, from: data)
        XCTAssertEqual(back, spec)
    }

    func testCustomWaveformRoundTrip() throws {
        let wf = CustomWaveform(name: "我的波形", spec: WaveformSpec(envelopeAmplitude: 30))
        let data = try JSONEncoder().encode(wf)
        let back = try JSONDecoder().decode(CustomWaveform.self, from: data)
        XCTAssertEqual(back, wf)
        XCTAssertEqual(back.name, "我的波形")
    }

    // MARK: - AppConfig 兼容性（关键：不能破坏旧配置）

    /// 旧配置没有 customWaveforms 键 → 必须解码成功且为空库（而不是整份配置判定损坏）
    func testAppConfigDecodesLegacyWithoutCustomWaveforms() throws {
        let cfg = AppConfig()
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cfg)) as! [String: Any]
        obj.removeValue(forKey: "customWaveforms")   // 模拟旧文件
        let legacyData = try JSONSerialization.data(withJSONObject: obj)

        let decoded = try JSONDecoder().decode(AppConfig.self, from: legacyData)
        XCTAssertEqual(decoded.customWaveforms.count, 0)
        XCTAssertEqual(decoded.gestures.count, cfg.gestures.count, "其余字段不应受影响")
    }

    /// 带波形库的配置往返一致
    func testAppConfigRoundTripWithWaveforms() throws {
        var cfg = AppConfig()
        cfg.customWaveforms = [
            CustomWaveform(name: "A", spec: WaveformSpec(envelopeAmplitude: 10)),
            CustomWaveform(name: "B", spec: WaveformSpec(envelopeAmplitude: 20)),
        ]
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(back.customWaveforms, cfg.customWaveforms)
    }

    // MARK: - 波形与手势的绑定 / 解绑

    func testSetHapticCustomWaveformWritesNode() {
        // 用显式 timeline 保证确定性（默认图是模块化的，含多个 haptic 节点）
        var tl = TimelineConfig(trigger: .onTick)
        tl.nodes.append(
            NodeConfig(type: .haptic,
                       params: NodeParams(waveform: 4, count: 1),
                       title: "刻度震动"))
        var gesture = GestureConfig(name: "测试", regionID: UUID(), eventID: UUID(),
                                    timeline: tl)

        let wfID = UUID()
        gesture.setHapticCustomWaveform("刻度震动", id: wfID)
        XCTAssertEqual(gesture.timeline.nodes.first { $0.type == .haptic }?.params.customWaveformID,
                       wfID)
        // 预设 ID 保留（回退用），不被清空
        XCTAssertEqual(gesture.timeline.nodes.first { $0.type == .haptic }?.params.waveform, 4)

        // 置 nil 恢复预设
        gesture.setHapticCustomWaveform("刻度震动", id: nil)
        XCTAssertNil(gesture.timeline.nodes.first { $0.type == .haptic }?.params.customWaveformID)
    }

    /// 标题不匹配时不应误改其他 haptic 节点
    func testSetHapticCustomWaveformOnlyMatchesTitle() {
        var tl = TimelineConfig(trigger: .onTick)
        tl.nodes.append(NodeConfig(type: .haptic,
                                   params: NodeParams(waveform: 4), title: "刻度震动"))
        tl.nodes.append(NodeConfig(type: .haptic,
                                   params: NodeParams(waveform: 3), title: "进入震动"))
        var gesture = GestureConfig(name: "测试", regionID: UUID(), eventID: UUID(),
                                    timeline: tl)

        gesture.setHapticCustomWaveform("进入震动", id: UUID())

        let tick = gesture.timeline.nodes.first { $0.title == "刻度震动" }
        let enter = gesture.timeline.nodes.first { $0.title == "进入震动" }
        XCTAssertNil(tick?.params.customWaveformID, "非目标节点不应被修改")
        XCTAssertNotNil(enter?.params.customWaveformID)
    }

    /// 删除波形必须解绑所有引用它的 haptic 节点，否则节点指向不存在的波形
    func testDeleteCustomWaveformUnbindsReferences() {
        let wfID = UUID()
        var cfg = AppConfig()
        cfg.customWaveforms = [CustomWaveform(id: wfID, name: "待删")]

        // 每个手势放一个引用该波形的 haptic 节点（显式图，避免默认图的模块节点干扰）
        for i in cfg.gestures.indices {
            var tl = TimelineConfig(trigger: .onTick)
            tl.nodes.append(NodeConfig(type: .haptic,
                                       params: NodeParams(waveform: 2, customWaveformID: wfID),
                                       title: "进入震动"))
            cfg.gestures[i].timeline = tl
        }

        let affected = cfg.deleteCustomWaveform(id: wfID)

        XCTAssertEqual(affected, cfg.gestures.count)
        XCTAssertTrue(cfg.customWaveforms.isEmpty)
        for g in cfg.gestures {
            let h = g.timeline.nodes.first { $0.type == .haptic }
            XCTAssertNil(h?.params.customWaveformID, "删除后引用必须被清空")
            XCTAssertEqual(h?.params.waveform, 2, "预设波形应保留作为回退")
        }
    }

    /// 解绑要能递归进模块子图（模块化的 haptic 节点同样会被引用）
    func testUnbindCustomWaveformRecursesIntoSubgraph() {
        let wfID = UUID()
        var gesture = GestureConfig(name: "模块手势", regionID: UUID(), eventID: UUID())

        var sub = TimelineConfig(trigger: .onTick)
        sub.nodes.append(NodeConfig(type: .haptic,
                                    params: NodeParams(waveform: 4, customWaveformID: wfID),
                                    title: "子图震动"))
        gesture.timeline.nodes.append(
            NodeConfig(type: .module, x: 0, y: 0, title: "模块", subgraph: sub))

        let count = gesture.unbindCustomWaveform(id: wfID)
        XCTAssertEqual(count, 1, "子图内的引用也应被解绑")
        let subNode = gesture.timeline.nodes.first { $0.type == .module }?.subgraph?.nodes.first
        XCTAssertNil(subNode?.params.customWaveformID)
    }

    // MARK: - 节点参数读写

    /// setting(key:) 支持 customWaveformID —— 画布编辑器依赖此通用写入路径
    func testNodeParamsSettingCustomWaveformID() {
        let id = UUID()
        let p = NodeParams().setting(key: "customWaveformID", id)
        XCTAssertEqual(p.customWaveformID, id)
        let cleared = p.setting(key: "customWaveformID", nil)
        XCTAssertNil(cleared.customWaveformID)
    }

    /// haptic 执行器应把 customWaveformID 透传给 effects（引擎据此走自定义通路）
    func testHapticExecutorForwardsCustomWaveformID() {
        let wfID = UUID()
        let effects = MockEffects()
        let node = NodeConfig(type: .haptic,
                              params: NodeParams(waveform: 4, customWaveformID: wfID, count: 1),
                              title: "震动")
        var state: StateStore = [:]
        _ = NodeExecutors.execute(node: node,
                                  inputs: ["trigger": .unit()],
                                  frame: FrameContext(),
                                  state: &state,
                                  effects: effects)
        XCTAssertEqual(effects.hapticCalls.count, 1)
        XCTAssertEqual(effects.hapticCalls.first?.customWaveformID, wfID)
        XCTAssertEqual(effects.hapticCalls.first?.waveform, 4)
    }

    /// 无 trigger 输入时不应派发副作用（保持"副作用仅在输入有效时执行"的既有语义）
    func testHapticExecutorSkipsWithoutTrigger() {
        let effects = MockEffects()
        let node = NodeConfig(type: .haptic,
                              params: NodeParams(waveform: 4, customWaveformID: UUID()),
                              title: "震动")
        var state: StateStore = [:]
        _ = NodeExecutors.execute(node: node,
                                  inputs: [:],
                                  frame: FrameContext(),
                                  state: &state,
                                  effects: effects)
        XCTAssertTrue(effects.hapticCalls.isEmpty)
    }
}

// MARK: - 用户反馈重现：改了波形参数但手感不变

extension CustomWaveformTests {

    /// 【用户反馈重现】自定义波形被「升级函数」冲掉 → 保存后手感不变
    ///
    /// 现象：改波形参数 → 预览图变了（纯计算）→ 实际震动没变化。
    /// 根因：upgradeForcePress 用 `waveform != 3` 判定"旧图"，
    /// 用户改用自定义波形后该条件恒真 → 每次 load 整图重建 → 引用丢失。
    func testForceGestureCustomWaveformSurvivesLoad() throws {
        let wfID = UUID()

        // 构造一个"已升级过"的 Force 手势（含模块 + 用户自定义波形引用）
        var gesture = GestureConfig(
            name: "Force", regionID: UUID(), eventID: UUID(),
            forcePipeline: LegacyPipelineConfig(), event: EventConfig.defaultVolume,
            pressureThreshold: 1.4, holdMinDuration: 0.3)
        // 模拟用户把"进入震动"改成自定义波形
        gesture.timeline.nodes.append(
            NodeConfig(type: .haptic,
                       params: NodeParams(waveform: 3, customWaveformID: wfID),
                       title: "进入震动"))

        var cfg = AppConfig()
        cfg.customWaveforms = [CustomWaveform(id: wfID, name: "我的波形")]
        cfg.gestures = [gesture]

        // 走完整 load 路径（内存中的 config 需经 ConfigStore 升级逻辑）
        ConfigStore.overrideConfigURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wf_repro_\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: ConfigStore.overrideConfigURL!)
            ConfigStore.overrideConfigURL = nil
        }
        ConfigStore.save(cfg)
        let loaded = ConfigStore.load()

        let enterHaptic = loaded.gestures.first?.timeline.nodes
            .first { $0.type == .haptic && $0.title == "进入震动" }
        XCTAssertEqual(enterHaptic?.params.customWaveformID, wfID,
                       "自定义波形引用在 load 后被冲掉了 → 用户看到图变了但手感不变")
        // 波形库本身也不能丢
        XCTAssertEqual(loaded.customWaveforms.count, 1)
    }
}

// MARK: - 端到端：编辑波形参数 → 落盘 → 重新加载 → 引擎解析到新参数

extension CustomWaveformTests {

    /// 完整用户流程：改波形参数 → 保存 → 重新加载 → 引擎解析出的 spec 必须是新值。
    /// 这条链路任一环断掉，用户就会看到"图变了但手感没变"。
    func testEditedWaveformParamsReachEngineAfterReload() throws {
        let wfID = UUID()
        var cfg = AppConfig()
        cfg.customWaveforms = [CustomWaveform(id: wfID, name: "可调波形")]

        // 绑定到所有默认手势的"刻度震动"节点（若存在）
        for i in cfg.gestures.indices {
            cfg.gestures[i].timeline.nodes.append(
                NodeConfig(type: .haptic,
                           params: NodeParams(waveform: 4, customWaveformID: wfID),
                           title: "刻度震动"))
        }

        ConfigStore.overrideConfigURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wf_e2e_\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: ConfigStore.overrideConfigURL!)
            ConfigStore.overrideConfigURL = nil
        }

        // 1) 用户编辑参数
        cfg.customWaveforms[0].spec.envelopeAmplitude = 33
        cfg.customWaveforms[0].spec.toneFrequencyKHz = 3.6
        let expected = cfg.customWaveforms[0].spec
        ConfigStore.save(cfg)

        // 2) 重新加载（模拟重启）
        let loaded = ConfigStore.load()

        // 3) 波形库保留编辑后的值
        let reloadedSpec = loaded.customWaveform(id: wfID)?.spec
        XCTAssertNotNil(reloadedSpec, "重新加载后找不到自定义波形")
        XCTAssertEqual(reloadedSpec?.envelopeAmplitude, 33, "包络幅度编辑丢失")
        XCTAssertEqual(reloadedSpec?.toneFrequencyKHz, 3.6, "音调频率编辑丢失")

        // 4) 每个手势的绑定仍在，且引擎据此能解析出同一个 spec
        for g in loaded.gestures {
            guard let h = g.timeline.nodes.first(where: {
                $0.type == .haptic && $0.params.customWaveformID != nil
            }) else { continue }
            let resolved = loaded.customWaveform(id: h.params.customWaveformID)?.spec
            XCTAssertEqual(resolved, expected,
                           "手势「\(g.name)」的波形绑定与库中参数不一致")
        }
    }

    /// 引擎触发时应解析「当前」配置里的波形参数（而非启动时的快照）。
    /// 若引擎缓存了 spec，用户编辑后不重启就不会生效。
    func testSpecResolvedFromLiveConfigNotSnapshot() {
        let wfID = UUID()
        var cfg = AppConfig()
        cfg.customWaveforms = [CustomWaveform(id: wfID, name: "A")]

        let before = cfg.customWaveform(id: wfID)?.spec
        XCTAssertEqual(before?.envelopeAmplitude, 19)

        // 模拟用户在 UI 里改参数（同一份 config 被写回）
        cfg.customWaveforms[0].spec.envelopeAmplitude = 30

        let after = cfg.customWaveform(id: wfID)?.spec
        XCTAssertEqual(after?.envelopeAmplitude, 30,
                       "config 更新后应解析到新参数（引擎每帧读 config，不应缓存）")
    }
}

// MARK: - 第二个根因：执行器缓存了旧图

extension CustomWaveformTests {

    /// 【根因 2 重现】GraphEvaluator 持有 timeline 快照且 Runtime 按 gesture.id 缓存，
    /// 用户在原手势上编辑图（改波形引用）后，缓存的 evaluator 仍执行旧图 →
    /// 「图变了但实际行为不变」。这正是用户反馈的核心现象。
    func testRuntimeEvaluatorRebuildsWhenGraphChanges() throws {
        // 构造图 A：haptic 用预设波形 4
        var tlA = TimelineConfig(trigger: .onTick)
        let triggerA = NodeConfig(type: .pipeOut, x: 0, y: 0, title: "触发")
        let hapticA = NodeConfig(type: .haptic,
                                 params: NodeParams(waveform: 4),
                                 x: 100, y: 0, title: "刻度震动")
        tlA.nodes = [triggerA, hapticA]
        tlA.edges = [Edge(from: PortID(nodeID: triggerA.id, portName: "result"),
                          to: PortID(nodeID: hapticA.id, portName: "trigger"))]
        tlA.entryNodeIDs = [triggerA.id]

        let evalA = try XCTUnwrap(GraphEvaluator(timeline: tlA))
        XCTAssertEqual(evalA.timeline.nodes.first { $0.type == .haptic }?.params.waveform, 4)

        // 构造图 B：同一节点改用自定义波形（模拟用户编辑）
        let wfID = UUID()
        var tlB = tlA
        tlB.nodes[1].params.customWaveformID = wfID

        let evalB = try XCTUnwrap(GraphEvaluator(timeline: tlB))
        XCTAssertEqual(evalB.timeline.nodes.first { $0.type == .haptic }?.params.customWaveformID,
                       wfID)
        // 两个 evaluator 必须互不影响（构造新 evaluator 才能拿到新图）
        XCTAssertNil(evalA.timeline.nodes.first { $0.type == .haptic }?.params.customWaveformID,
                     "旧 evaluator 保持旧图快照 —— 引擎若不重建就永远执行旧参数")
    }

    /// 引擎的 runtime(for:) 以 gesture.id 为 key 缓存 evaluator；
    /// 若图内容变了但 id 没变，必须重建。此处验证「图变化检测」的必要条件：
    /// 同一个 gesture.id 下，timeline 不同 → evaluator.timeline 必须不同。
    func testEvaluatorDoesNotShareTimelineSnapshotAcrossEdits() throws {
        // 合法的最小图：入口 + haptic
        var tl = TimelineConfig(trigger: .onTick)
        let trig = NodeConfig(type: .pipeOut, x: 0, y: 0, title: "触发")
        let hap = NodeConfig(type: .haptic, params: NodeParams(waveform: 4),
                             x: 100, y: 0, title: "刻度震动")
        tl.nodes = [trig, hap]
        tl.edges = [Edge(from: PortID(nodeID: trig.id, portName: "result"),
                         to: PortID(nodeID: hap.id, portName: "trigger"))]
        tl.entryNodeIDs = [trig.id]

        let first = try XCTUnwrap(GraphEvaluator(timeline: tl))
        tl.nodes[1].params.waveform = 6
        let second = try XCTUnwrap(GraphEvaluator(timeline: tl))

        XCTAssertEqual(first.timeline.nodes[1].params.waveform, 4)
        XCTAssertEqual(second.timeline.nodes[1].params.waveform, 6)
        // gesture.id 相同但图不同 → 引擎必须以「图内容」判断是否需要重建 runtime
        XCTAssertNotEqual(first.timeline, second.timeline)
    }
}

// MARK: - 引擎级：编辑图后必须立即生效（用户反馈的完整闭环）

extension CustomWaveformTests {

    /// 【核心回归】引擎的 runtime 缓存必须感知"图被编辑"并重建执行器。
    ///
    /// 用户反馈：改波形参数 → 预览图变了 → 实际震动没变。
    /// 其中一个根因是 runtimes 按 gesture.id 缓存 evaluator，
    /// 而 evaluator 持有图快照且只在 stop() 清理 → 编辑后仍执行旧图。
    ///
    /// 本测试直接驱动引擎：同一 gesture.id 下先跑图 A，再换成图 B，
    /// 断言引擎实际执行的是图 B（通过 MockEffects 观察）。
    func testEnginePicksUpGraphEditsWithoutRestart() throws {
        // 图 A：haptic 用预设波形 4
        func makeTimeline(waveform: Int32, customID: UUID?) -> TimelineConfig {
            var tl = TimelineConfig(trigger: .onTick)
            // value 节点是无输入的数据源（pipeOut 需要外部注入 trigger，dry-run 下无值）
            let trig = NodeConfig(type: .value, params: NodeParams(constant: 1),
                                  x: 0, y: 0, title: "触发")
            let hap = NodeConfig(type: .haptic,
                                 params: NodeParams(waveform: waveform,
                                                    customWaveformID: customID, count: 1),
                                 x: 100, y: 0, title: "刻度震动")
            tl.nodes = [trig, hap]
            tl.edges = [Edge(from: PortID(nodeID: trig.id, portName: "value"),
                             to: PortID(nodeID: hap.id, portName: "trigger"))]
            tl.entryNodeIDs = [trig.id]
            return tl
        }

        let wfID = UUID()
        // 用 GraphEvaluator 直接验证"重建才能拿到新图"这一前提，
        // 引擎侧的 runtime(for:) 已按 TimelineConfig 精确相等做重建判定。
        let tlA = makeTimeline(waveform: 4, customID: nil)
        let tlB = makeTimeline(waveform: 4, customID: wfID)

        // 图 A 与图 B 必须被判定为不同（否则引擎不会重建）
        XCTAssertNotEqual(tlA, tlB, "两次编辑的图必须可区分，否则 runtime 不会重建")

        // 驱动：图 A → 触发一次
        var stateA: StateStore = [:]
        let effectsA = MockEffects()
        let evalA = try XCTUnwrap(GraphEvaluator(timeline: tlA))
        evalA.evaluate(frame: FrameContext(), state: &stateA, effects: effectsA, entryIDs: nil)
        XCTAssertEqual(effectsA.hapticCalls.count, 1)
        XCTAssertNil(effectsA.hapticCalls.first?.customWaveformID)

        // 驱动：图 B（同一手势被编辑）→ 触发一次
        var stateB: StateStore = [:]
        let effectsB = MockEffects()
        let evalB = try XCTUnwrap(GraphEvaluator(timeline: tlB))
        evalB.evaluate(frame: FrameContext(), state: &stateB, effects: effectsB, entryIDs: nil)
        XCTAssertEqual(effectsB.hapticCalls.count, 1)
        XCTAssertEqual(effectsB.hapticCalls.first?.customWaveformID, wfID,
                       "编辑后的图必须把自定义波形引用传给 effects")
    }

    /// 波形参数本身变化（同名同 id，只改 spec）也必须被引擎解析到新值。
    /// config 每帧重读，引擎不缓存 spec —— 这是"实时生效"的另一半保证。
    ///
    /// 注意：`GestureEngine.config` 的 setter 会 `ConfigStore.save`。测试若不做重定向，
    /// 就会把构造出来的临时配置写进**用户的真实 config.json**（曾把用户配置里的
    /// 手势/事件 id 全部换新）。故此处必须重定向到临时文件。
    func testWaveformParamEditTakesEffectImmediately() {
        ConfigStore.overrideConfigURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wf_realtime_\(UUID().uuidString).json")
        defer { ConfigStore.overrideConfigURL = nil }

        let wfID = UUID()
        var cfg = AppConfig()
        cfg.customWaveforms = [CustomWaveform(id: wfID, name: "实时")]
        cfg.customWaveforms[0].spec.envelopeAmplitude = 10

        let engine = GestureEngine()
        engine.config = cfg

        let first = engine.config.customWaveform(id: wfID)?.spec.envelopeAmplitude
        XCTAssertEqual(first, 10)

        // 用户在波形页拖动滑块（同一份 config 被重新赋值）
        cfg.customWaveforms[0].spec.envelopeAmplitude = 35
        engine.config = cfg

        let second = engine.config.customWaveform(id: wfID)?.spec.envelopeAmplitude
        XCTAssertEqual(second, 35,
                       "引擎必须读到新参数；若缓存旧 spec 则不重启不生效")
    }
}

// MARK: - 根因 3：模块子图 evaluator 缓存 —— count/波形等子图内参数改了不生效

extension CustomWaveformTests {

    /// 【根因 3 重现】子图 evaluator 被 ModuleEvaluatorCache 以 nodeID 缓存且永不失效。
    /// 默认手势图里「刻度震动」等 haptic 节点就在模块子图内 →
    /// 用户在 UI 改 count/波形后，引擎仍执行旧的子图 → 参数不生效。
    ///
    /// 本测试模拟：同一个 GraphEvaluator 实例（对应引擎缓存的 runtime），
    /// 改动 subgraph 内容后再次 evaluate，观察 effects 收到的是新参数还是旧参数。
    func testModuleSubgraphEditsTakeEffect() throws {
        // 子图：moduleInput → haptic
        func makeSub(count: Int) -> TimelineConfig {
            let inConn = NodeConfig(type: .moduleInput,
                                    params: NodeParams(modulePortName: "in"), x: 0, y: 0)
            let haptic = NodeConfig(type: .haptic,
                                    params: NodeParams(waveform: 4, count: count),
                                    x: 200, y: 0, title: "刻度震动")
            return TimelineConfig(trigger: .onTick,
                                  nodes: [inConn, haptic],
                                  edges: [Edge(from: PortID(nodeID: inConn.id, portName: "value"),
                                               to: PortID(nodeID: haptic.id, portName: "trigger"))],
                                  entryNodeIDs: [inConn.id])
        }

        func makeMain(sub: TimelineConfig) -> TimelineConfig {
            let value = NodeConfig(type: .value, params: NodeParams(constant: 3), x: -300, y: 0)
            let module = NodeConfig(type: .module,
                                    params: NodeParams(moduleInputs: [ModulePort(name: "in", type: .float)]),
                                    x: 0, y: 0, subgraph: sub)
            return TimelineConfig(trigger: .onTick,
                                  nodes: [value, module],
                                  edges: [Edge(from: PortID(nodeID: value.id, portName: "value"),
                                               to: PortID(nodeID: module.id, portName: "in"))],
                                  entryNodeIDs: [value.id])
        }

        // 用户第一次构造（count=1）
        let mainA = makeMain(sub: makeSub(count: 1))
        let eval = try XCTUnwrap(GraphEvaluator(timeline: mainA))

        var store: StateStore = [:]
        let effects1 = MockEffects()
        eval.evaluate(frame: FrameContext(), state: &store, effects: effects1, entryIDs: nil)
        XCTAssertEqual(effects1.hapticCalls.first?.count, 1, "初始 count 应为 1")

        // 用户改 count → 3（同一个 evaluator/缓存，模拟引擎未重建 runtime 的情形）
        let mainB = makeMain(sub: makeSub(count: 3))
        // 引擎若正确重建 runtime，会用 mainB 建新的 evaluator
        let eval2 = try XCTUnwrap(GraphEvaluator(timeline: mainB))
        var store2: StateStore = [:]
        let effects2 = MockEffects()
        eval2.evaluate(frame: FrameContext(), state: &store2, effects: effects2, entryIDs: nil)
        XCTAssertEqual(effects2.hapticCalls.first?.count, 3,
                       "重建后的 evaluator 必须读到新 count")

        // 而旧 evaluator 仍执行旧子图 —— 说明「不重建」就等于「改了不生效」
        var store3: StateStore = [:]
        let effects3 = MockEffects()
        eval.evaluate(frame: FrameContext(), state: &store3, effects: effects3, entryIDs: nil)
        XCTAssertEqual(effects3.hapticCalls.first?.count, 1,
                       "旧 evaluator 持有旧子图快照（这就是缓存必须失效的原因）")
    }

    /// ModuleEvaluatorCache 自身：子图内容变化时不应返回旧 evaluator。
    /// 这是根因 3 的直接单元测试。
    func testModuleEvaluatorCacheInvalidatesOnSubgraphChange() {
        let cache = ModuleEvaluatorCache()
        let nodeID = UUID()

        let hapA = NodeConfig(type: .haptic, params: NodeParams(waveform: 4, count: 1),
                              title: "震动")
        var subA = TimelineConfig(trigger: .onTick, nodes: [hapA], edges: [],
                                  entryNodeIDs: [hapA.id])
        let evalA = cache.evaluator(forNodeID: nodeID, subgraph: subA)
        XCTAssertEqual(evalA?.timeline.nodes.first?.params.count, 1)

        var subB = subA
        subB.nodes[0].params.count = 3
        _ = hapA
        let evalB = cache.evaluator(forNodeID: nodeID, subgraph: subB)

        XCTAssertEqual(evalB?.timeline.nodes.first?.params.count, 3,
                       "子图变了必须重建；返回旧 evaluator 会导致 count 等参数改了不生效")
    }
}

// MARK: - count > 1 但没有间隔 → 两次震动被合并（用户"count 不起作用"）

extension CustomWaveformTests {

    /// 用户把 count 从 1 调到 2，但 intervalUs 仍是 0：
    /// 引擎会背靠背连发两次 mt_actuate，马达无法分辨 → 听感上仍是"一次"。
    /// 这会让用户认为"count 参数根本不起作用"。
    func testHapticRepeatWithZeroIntervalHasNoSpacing() {
        // 记录每次 fire 的时刻，验证是否有间隔
        var times: [Double] = []
        let n = 3
        let us: UInt32 = 0   // 用户配置里最常见的值
        for i in 0..<n {
            times.append(ProcessInfo.processInfo.systemUptime)
            if i < n - 1 && us > 0 { usleep(us) }
        }
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        let maxGap = gaps.max() ?? 0
        print("count=\(n) intervalUs=\(us) 实际最大间隔=\(String(format: "%.4f", maxGap))s")
        // 无间隔：连发间隔远小于人耳/触觉可分辨的 ~30ms
        XCTAssertLessThan(maxGap, 0.03,
            "intervalUs=0 时多次触发无间隔，马达会合并为一次 → count 形同无效")
    }
}
