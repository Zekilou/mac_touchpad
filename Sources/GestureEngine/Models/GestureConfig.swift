import Foundation

/// 手势 = 一张完全自由的节点图（v8 状态机展开）
///
/// 不存在「四个阶段」——整张图就是一个可自由连线的节点画布：
///   - 状态机完全展开：11 个 varRef 变量（phase/pathIndex/startTime/...）+ 10 条转移链（compare/arith/finger 组合）
///   - finger 节点：物理层（面积/区域过滤 → 按下/抬起边沿 + 手指信号 + 身份）
///   - 执行链：enterHolding（锁光标+进入震动）/ tick（信号→变换→量化→边界分支→消费+震动+冻结）/ exitHolding / 解冻
///   - Group 节点：批注组框，纯视觉分组，不参与执行
///   - RegionRef / EventRef：手势绑定的区域/事件（也是图节点）
/// 旧 v3 配置（4 条独立 timeline）解码时自动合并为单图（每个阶段补管道出口入口）。
/// 旧 v2 识别器（recognizer 黑盒）解码后保留节点但不执行——需重新迁移（v8 状态机在图上）。
public struct GestureConfig: Codable, Identifiable, Equatable, Hashable {
    // MARK: - 稳定 ID（不随版本变）

    public let id: UUID
    /// 手势名 = 图的名字（UI 顶部 tab 显示）
    public var name: String

    /// 旧 v3 顶层绑定（v4 迁移后置 nil；仅作解码回退，权威在图节点）
    public var regionID: UUID?
    public var eventID: UUID?

    /// 单张节点图（v5；旧文件里的 timelines 数组解码时合并进来）
    public var timeline: TimelineConfig

    /// 手势启用开关（图的全局设置；false 时引擎跳过此手势，UI 画布可切换）
    public var enabled: Bool

    // MARK: - Init

    public init(id: UUID = UUID(),
                name: String,
                regionID: UUID,
                eventID: UUID,
                timeline: TimelineConfig,
                enabled: Bool = true) {
        self.id = id
        self.name = name
        self.regionID = regionID
        self.eventID = eventID
        self.timeline = timeline
        self.enabled = enabled
    }

    /// 便捷：用默认管线 + 指定事件/区域生成单图（含 Trigger 入口 + 绑定 ref 节点）
    public init(id: UUID = UUID(),
                name: String,
                regionID: UUID,
                eventID: UUID,
                pipeline: LegacyPipelineConfig = LegacyPipelineConfig(),
                event: EventConfig = .defaultVolume,
                enabled: Bool = true) {
        self.id = id
        self.name = name
        self.regionID = regionID
        self.eventID = eventID
        self.timeline = TimelineMigrator.migrate(pipeline: pipeline, event: event,
                                                 regionID: regionID, eventID: eventID)
        self.enabled = enabled
    }

    /// 便捷：Force 按压保持手势（压力 >= 阈值持续 holdMinDuration 进入 holding；压力/手指离开退出）
    public init(id: UUID = UUID(),
                name: String,
                regionID: UUID,
                eventID: UUID,
                forcePipeline: LegacyPipelineConfig,
                event: EventConfig,
                pressureThreshold: Float,
                holdMinDuration: Double,
                enabled: Bool = true) {
        self.id = id
        self.name = name
        self.regionID = regionID
        self.eventID = eventID
        self.timeline = TimelineMigrator.migrate(pipeline: forcePipeline, event: event,
                                                 regionID: regionID, eventID: eventID,
                                                 touchSizeMin: 0.1, touchSizeMax: 1.35,
                                                 useForcePress: (pressureThreshold, holdMinDuration))
        self.enabled = enabled
    }

    // MARK: - Codable（v3 timelines 数组 → 单图合并）

    private enum CodingKeys: String, CodingKey { case id, name, regionID, eventID, timeline, timelines, enabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        regionID = try c.decodeIfPresent(UUID.self, forKey: .regionID)
        eventID = try c.decodeIfPresent(UUID.self, forKey: .eventID)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        if let tl = try c.decodeIfPresent(TimelineConfig.self, forKey: .timeline) {
            timeline = tl
        } else if let tls = try c.decodeIfPresent([TimelineConfig].self, forKey: .timelines) {
            timeline = Self.mergeTimelines(tls)
        } else {
            timeline = TimelineConfig(trigger: .onFirstTap)
        }
        // 旧图兼容：signal → touchData 后修正输出连线端口（"value" → source 字段名）
        Self.normalizeLegacyNodes(&timeline)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(regionID, forKey: .regionID)
        try c.encodeIfPresent(eventID, forKey: .eventID)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(timeline, forKey: .timeline)
    }

    /// v3 多 timeline → 单图：每阶段生成 Trigger 入口节点，阶段垂直堆叠，入口连到 Trigger。
    static func mergeTimelines(_ timelines: [TimelineConfig]) -> TimelineConfig {
        var nodes: [NodeConfig] = []
        var edges: [Edge] = []
        var entries: [UUID] = []
        let yOffsets: [TriggerEvent: Double] = [
            .onFirstTap: 0, .onEnterHolding: 260, .onSecondTap: 260,
            .onTick: 520, .onBoundaryHit: 520, .onExitHolding: 780,
        ]
        for tl in timelines {
            let dy = yOffsets[tl.trigger] ?? 0
            // 管道出口节点（原 v3 的 Trigger 入口，合并后作链入口）
            let pipe = NodeConfig(type: .pipeOut,
                                  params: NodeParams(trigger: tl.trigger),
                                  x: -200, y: dy + 20,
                                  title: tl.trigger.displayName)
            nodes.append(pipe)
            entries.append(pipe.id)
            // 阶段节点垂直堆叠
            for node in tl.nodes {
                var n = node
                n.y += dy
                nodes.append(n)
            }
            edges.append(contentsOf: tl.edges)
            // 入口节点连到管道出口
            for entryID in tl.entryNodeIDs where tl.nodes.contains(where: { $0.id == entryID }) {
                edges.append(Edge(from: PortID(nodeID: pipe.id, portName: "trigger"),
                                  to: PortID(nodeID: entryID, portName: "trigger")))
            }
        }
        return TimelineConfig(trigger: .onFirstTap, nodes: nodes, edges: edges, entryNodeIDs: entries)
    }

    /// 旧图兼容修正（decode 后调用）：
    /// 1) 旧 signal 节点经 NodeType 自定义 decode 已变为 touchData，输出连线端口 "value" → source 字段端口，清 source 参数
    /// 2) 旧端口名（input/output/true/false/output1/output2）→ 注册表端口名（value/result/tick/out1/out2/data/trigger）
    static func normalizeLegacyNodes(_ timeline: inout TimelineConfig) {
        // 1) touchData 单选 source → 字段端口
        for i in timeline.nodes.indices where timeline.nodes[i].type == .touchData {
            guard let field = timeline.nodes[i].params.source else { continue }
            let targetPort = field.rawValue
            for j in timeline.edges.indices
            where timeline.edges[j].from.nodeID == timeline.nodes[i].id
                && timeline.edges[j].from.portName == "value" {
                timeline.edges[j].from.portName = targetPort
            }
            // touchData 是多输出节点，不再需要单选 source 参数
            timeline.nodes[i].params.source = nil
        }
        // 2) 旧端口名迁移（按节点类型映射到注册表端口名）
        let typesByID = Dictionary(uniqueKeysWithValues: timeline.nodes.map { ($0.id, $0.type) })
        for j in timeline.edges.indices {
            let edge = timeline.edges[j]
            if let fromType = typesByID[edge.from.nodeID] {
                timeline.edges[j].from.portName = migratedFromPort(fromType, edge.from.portName)
            }
            if let toType = typesByID[edge.to.nodeID] {
                timeline.edges[j].to.portName = migratedToPort(toType, edge.to.portName)
            }
        }
    }

    /// 来源端口旧名 → 注册表输出端口名
    private static func migratedFromPort(_ type: NodeType, _ old: String) -> String {
        switch old {
        case "true":      return "out1"
        case "false":     return "out2"
        case "output1":   return "out1"
        case "output2":   return "out2"
        case "output":    return NodeTypeDef.outputSockets(of: type).first?.name ?? old
        default:          return old
        }
    }

    /// 目标端口旧名 → 注册表输入端口名（旧 "input" 是该节点第一个输入；branch 特例 → value）
    private static func migratedToPort(_ type: NodeType, _ old: String) -> String {
        switch old {
        case "input":
            if type == .branch { return "value" }
            return NodeTypeDef.inputSockets(of: type).first?.name ?? "trigger"
        default:
            return old
        }
    }

    // MARK: - 绑定（图节点权威，存储字段回退）

    private func refNode(of type: NodeType) -> NodeConfig? {
        timeline.nodes.first { $0.type == type }
    }

    /// 绑定的区域（图 RegionRef 优先，旧 v3 顶层字段回退）
    public var boundRegionID: UUID? {
        refNode(of: .region)?.params.regionID ?? regionID
    }

    /// 绑定的事件（图 EventRef 优先，旧 v3 顶层字段回退）
    public var boundEventID: UUID? {
        refNode(of: .event)?.params.eventID ?? eventID
    }

    /// 旧 v3 文件迁移：把顶层 regionID/eventID 补入图的 ref 节点（缺失时），并清空顶层字段。
    /// 之后图是唯一事实来源，保存的 JSON 不再含顶层绑定。
    public mutating func ensureBindingsInGraph() {
        var tl = timeline
        var didChange = false
        if let regionID, tl.firstNode(of: .region) == nil {
            tl.nodes.append(NodeConfig(type: .region, params: NodeParams(regionID: regionID),
                                       x: 0, y: 0, title: "触发区域"))
            didChange = true
        }
        if let eventID, tl.firstNode(of: .event) == nil {
            tl.nodes.append(NodeConfig(type: .event, params: NodeParams(eventID: eventID),
                                       x: 200, y: 0, title: "绑定事件"))
            didChange = true
        }
        if didChange {
            timeline = tl
            regionID = nil
            eventID = nil
        }
    }

    /// 从当前图提取 v2 管线参数（信号源/变换/量化/震动/识别时序/鼠标）——迁移器重建图用
    var legacyPipelineValue: LegacyPipelineConfig {
        let tl = timeline
        var signalSource = tickSignalSourcePort ?? .normY
        let transform = tl.firstNode(of: .transform)?.params.transform ?? .delta
        let q = tl.firstNode(of: .quantize)?.params
        func threshold(_ title: String) -> Float? {
            tl.nodes.first { $0.type == .compare && $0.title == title }?.params.threshold
        }
        func haptic(_ title: String) -> HapticEvent {
            guard let h = tl.nodes.first(where: { $0.type == .haptic && $0.title == title })?.params else {
                return HapticEvent(enabled: false, waveform: 4, count: 1, intervalUs: 0)
            }
            return HapticEvent(enabled: true, waveform: h.waveform ?? 0,
                               count: h.count ?? 1, intervalUs: h.intervalUs ?? 0)
        }
        return LegacyPipelineConfig(
            signalSource: signalSource,
            transformMode: transform,
            triggerMode: q?.triggerMode ?? .discrete,
            stepNorm: q?.stepNorm ?? 0.02,
            sensitivity: q?.sensitivity ?? 1.0,
            hapticEnter: haptic("进入震动"),
            hapticTick: haptic("刻度震动"),
            hapticBoundary: haptic("边界震动"),
            hapticExit: haptic("退出震动"),
            disassociateMouse: tl.nodes.contains { $0.type == .set && $0.params.key == "cursorLocked" }
                || tl.nodes.contains { $0.type == .varRef && $0.params.key == "cursorLocked" },
            tapMaxDuration: Double(threshold("按下超时?") ?? 0.20),
            tapMaxDrift: threshold("漂移过大?") ?? 0.05,
            tapMaxGap: Double(threshold("间隔内?") ?? threshold("间隔超时?") ?? 0.30),
            holdMinDuration: Double(threshold("保持够久?") ?? 0.20))
    }

    /// **v8 升级**：图含 recognizer（状态机黑盒，v7 及更早）→ 从旧图提取参数重新迁移为状态机展开图。
    /// 提取源：recognizer 节点参数（识别时序）、touchData 出边（信号源）、transform/quantize 节点、
    /// 按标题匹配的 haptic 节点、set(cursorLocked) 存在性（鼠标脱钩）。
    /// 用户配置不丢；旧黑盒节点不再执行（v8 状态机在图上）。
    public mutating func upgradeStateMachineGraph(events: [EventConfig]) {
        guard timeline.firstNode(of: .recognizer) != nil else { return }
        let tl = timeline
        let rec = tl.firstNode(of: .recognizer)?.params
        // 信号源：touchData 出边第一个 SignalSource 字段端口（v8 前无则回退卡片 source）
        var signalSource = rec?.source ?? .normY
        if let td = tl.firstNode(of: .touchData) {
            for e in tl.outgoingEdges(from: td.id) where SignalSource(rawValue: e.from.portName) != nil {
                signalSource = SignalSource(rawValue: e.from.portName)!
                break
            }
        }
        let transform = tl.firstNode(of: .transform)?.params.transform ?? .delta
        let q = tl.firstNode(of: .quantize)?.params
        // 震动按标题匹配（v8 迁移器固定标题）
        func haptic(_ title: String) -> HapticEvent {
            guard let h = tl.nodes.first(where: { $0.type == .haptic && $0.title == title })?.params else {
                return HapticEvent(enabled: false, waveform: 4, count: 1, intervalUs: 0)
            }
            return HapticEvent(enabled: true, waveform: h.waveform ?? 0,
                               count: h.count ?? 1, intervalUs: h.intervalUs ?? 0)
        }
        let disassociate = tl.nodes.contains { $0.type == .set && $0.params.key == "cursorLocked" }
        let pipeline = LegacyPipelineConfig(
            signalSource: signalSource,
            transformMode: transform,
            triggerMode: q?.triggerMode ?? .discrete,
            stepNorm: q?.stepNorm ?? 0.02,
            sensitivity: q?.sensitivity ?? 1.0,
            hapticEnter: haptic("进入震动"),
            hapticTick: haptic("刻度震动"),
            hapticBoundary: haptic("边界震动"),
            hapticExit: haptic("退出震动"),
            disassociateMouse: disassociate,
            tapMaxDuration: rec?.tapMaxDuration ?? 0.20,
            tapMaxDrift: rec?.tapMaxDrift ?? 0.05,
            tapMaxGap: rec?.tapMaxGap ?? 0.30,
            holdMinDuration: rec?.holdMinDuration ?? 0.20)
        let event = events.first { $0.id == boundEventID } ?? EventConfig.defaultVolume
        timeline = TimelineMigrator.migrate(pipeline: pipeline, event: event,
                                            regionID: boundRegionID, eventID: boundEventID)
    }

    /// **v9 升级**：v8 扁平展开图（varRef 在根图、无 module 组）→ 重新迁移为模块化图
    /// （识别状态机/冻结管理封装成可折叠组）。参数从旧图提取：compare 标题匹配识别阈值、
    /// touchData 出边推断信号源、transform/quantize 节点、haptic 标题匹配、cursorLocked 变量存在性。
    /// 用户配置不丢；旧扁平节点由迁移重建。
    public mutating func upgradeModularGraph(events: [EventConfig]) {
        let tl = timeline
        guard tl.firstNode(of: .module) == nil, tl.firstNode(of: .varRef) != nil else { return }
        // 信号源：touchData 出边第一个 SignalSource 字段端口
        var signalSource: SignalSource = .normY
        if let td = tl.firstNode(of: .touchData) {
            for e in tl.outgoingEdges(from: td.id) where SignalSource(rawValue: e.from.portName) != nil {
                signalSource = SignalSource(rawValue: e.from.portName)!
                break
            }
        }
        let transform = tl.firstNode(of: .transform)?.params.transform ?? .delta
        let q = tl.firstNode(of: .quantize)?.params
        // 识别阈值按标题匹配（v8 迁移器固定标题）
        func threshold(_ title: String) -> Float? {
            tl.nodes.first { $0.type == .compare && $0.title == title }?.params.threshold
        }
        // 震动按标题匹配（v8 迁移器固定标题）
        func haptic(_ title: String) -> HapticEvent {
            guard let h = tl.nodes.first(where: { $0.type == .haptic && $0.title == title })?.params else {
                return HapticEvent(enabled: false, waveform: 4, count: 1, intervalUs: 0)
            }
            return HapticEvent(enabled: true, waveform: h.waveform ?? 0,
                               count: h.count ?? 1, intervalUs: h.intervalUs ?? 0)
        }
        let pipeline = LegacyPipelineConfig(
            signalSource: signalSource,
            transformMode: transform,
            triggerMode: q?.triggerMode ?? .discrete,
            stepNorm: q?.stepNorm ?? 0.02,
            sensitivity: q?.sensitivity ?? 1.0,
            hapticEnter: haptic("进入震动"),
            hapticTick: haptic("刻度震动"),
            hapticBoundary: haptic("边界震动"),
            hapticExit: haptic("退出震动"),
            disassociateMouse: tl.nodes.contains { $0.type == .varRef && $0.params.key == "cursorLocked" },
            tapMaxDuration: Double(threshold("按下超时?") ?? 0.20),
            tapMaxDrift: threshold("漂移过大?") ?? 0.05,
            tapMaxGap: Double(threshold("间隔内?") ?? threshold("间隔超时?") ?? 0.30),
            holdMinDuration: Double(threshold("保持够久?") ?? 0.20))
        let event = events.first { $0.id == boundEventID } ?? EventConfig.defaultVolume
        timeline = TimelineMigrator.migrate(pipeline: pipeline, event: event,
                                            regionID: boundRegionID, eventID: boundEventID)
    }

    /// **v10.17 升级**：旧边界分流结构 → 无分流（quantize.tick → consume 直接）。
    /// 原因：boundaryState 依赖 mediaKey trackedValue 数学推进，与系统真实值漂移 → 反复反向滑动后
    /// trackedValue 虚高误判"朝外"→ 只震不调 → 值卡中间（用户"必然卡住"）；系统自身 clamp 处理边界。
    /// 检测：图存在 boundaryState 节点（v10 起所有方向感知分流结构都含它）。
    /// 参数从旧图递归提取（v9 模块化后 compare/haptic 在模块子图内）→ 重新迁移，用户配置不丢。
    public mutating func upgradeBoundarySense(events: [EventConfig]) {
        let tl = timeline
        // Force 手势由 upgradeForcePress 专用升级（保留压力阈值/进入震动/buzz）——边界分流由迁移器一并移除
        if tl.nodes.contains(where: { $0.type == .module && $0.title == "Force按压识别" }) { return }
        guard tl.firstNode(of: .boundaryState) != nil else { return }
        let all = tl.allNodes
        // 信号源：touchData 出边第一个 SignalSource 字段端口
        var signalSource: SignalSource = .normY
        if let td = tl.firstNode(of: .touchData) {
            for e in tl.outgoingEdges(from: td.id) where SignalSource(rawValue: e.from.portName) != nil {
                signalSource = SignalSource(rawValue: e.from.portName)!
                break
            }
        }
        let transform = all.first { $0.type == .transform }?.params.transform ?? .delta
        let q = all.first { $0.type == .quantize }?.params
        // 识别阈值按标题匹配（模块化后 compare 在模块子图内，用递归 allNodes）
        func threshold(_ title: String) -> Float? {
            all.first { $0.type == .compare && $0.title == title }?.params.threshold
        }
        // 震动按标题匹配（v8/v9 迁移器固定标题）
        func haptic(_ title: String) -> HapticEvent {
            guard let h = all.first(where: { $0.type == .haptic && $0.title == title })?.params else {
                return HapticEvent(enabled: false, waveform: 4, count: 1, intervalUs: 0)
            }
            return HapticEvent(enabled: true, waveform: h.waveform ?? 0,
                               count: h.count ?? 1, intervalUs: h.intervalUs ?? 0)
        }
        let pipeline = LegacyPipelineConfig(
            signalSource: signalSource,
            transformMode: transform,
            triggerMode: q?.triggerMode ?? .discrete,
            stepNorm: q?.stepNorm ?? 0.02,
            sensitivity: q?.sensitivity ?? 1.0,
            hapticEnter: haptic("进入震动"),
            hapticTick: haptic("刻度震动"),
            hapticBoundary: haptic("边界震动"),
            hapticExit: haptic("退出震动"),
            disassociateMouse: all.contains { $0.type == .varRef && $0.params.key == "cursorLocked" },
            tapMaxDuration: Double(threshold("按下超时?") ?? 0.20),
            tapMaxDrift: threshold("漂移过大?") ?? 0.05,
            tapMaxGap: Double(threshold("间隔内?") ?? threshold("间隔超时?") ?? 0.30),
            holdMinDuration: Double(threshold("保持够久?") ?? 0.20))
        let event = events.first { $0.id == boundEventID } ?? EventConfig.defaultVolume
        timeline = TimelineMigrator.migrate(pipeline: pipeline, event: event,
                                            regionID: boundRegionID, eventID: boundEventID)
    }

    /// **v10.16 升级**：旧 Force 图 → 新结构（pressure 来自 touchData 原始 zP + T5 滑出区域退出 + T4 滞回退出）。
    /// 历史结构：v10.14（pressure 来自 touchData、无 touching 条件）→ v10.15（pressure 来自 finger、无 T5）
    /// → v10.16a（T5 有、T4 无滞回）。
    /// 检测：子图缺 "lastTouchTime"（无 T5）/ pressure 边来自 finger / 缺 "压力不足?" 滞回阈值 / tick 信号源非 normY。
    /// 参数保留：从子图 compare 标题匹配提取压力阈值/保持时长（用户可能已在画布调整）。
    public mutating func upgradeForcePress(events: [EventConfig]) {
        let tl = timeline
        guard let moduleNode = tl.nodes.first(where: { $0.type == .module && $0.title == "Force按压识别" }),
              let sub = moduleNode.subgraph else { return }
        let hasLastTouch = sub.nodes.contains { $0.type == .varRef && $0.params.key == "lastTouchTime" }
        let hasRelease = sub.nodes.contains { $0.type == .compare && $0.title == "压力不足?" }
        // pressure 必须来自 finger（区域内用户手指）——touchData.pressure = touches.first 可能是手掌（zP 虚高 → 手掌轻放就触发）
        let pressureFromTouchData = tl.edges.contains { edge in
            edge.to.nodeID == moduleNode.id && edge.to.portName == "pressure"
                && tl.nodes.first(where: { $0.id == edge.from.nodeID })?.type == .touchData
        }
        // tick 链信号源：gate(保持中?) 的 value 输入来自 touchData 的端口（压力被误当滑动信号 → 按住抖动乱调）
        let gateValueSource = tl.edges.first { edge in
            edge.to.portName == "value"
                && tl.nodes.first(where: { $0.id == edge.to.nodeID })?.type == .branch
                && tl.nodes.first(where: { $0.id == edge.from.nodeID })?.type == .touchData
        }?.from.portName
        let wrongTickSource = gateValueSource != nil && gateValueSource != "normY"
        // Force 进入震动必须用 buzz（波形3）——与系统触控板点击（click 1/2）区分（用户反馈）
        let oldEnterWave = tl.nodes.first { $0.type == .haptic && $0.title == "进入震动" }?.params.waveform != 3
        // 边界分流整体移除（trackedValue 漂移误判"朝外"→ 值卡中间；系统自身 clamp 处理边界）
        let hasBoundaryState = tl.firstNode(of: .boundaryState) != nil
        guard !hasLastTouch || pressureFromTouchData || !hasRelease || wrongTickSource
            || oldEnterWave || hasBoundaryState else { return }
        // 参数保留（用户可能已调阈值）：子图 compare 标题匹配
        let threshold = sub.nodes.first { $0.type == .compare && $0.title == "压力足够?" }?.params.threshold ?? 1.4
        let hold = Double(sub.nodes.first { $0.type == .compare && $0.title == "按够久?" }?.params.threshold ?? 0.3)
        let event = events.first { $0.id == boundEventID } ?? events.first ?? EventConfig.defaultVolume
        // Force 滑动调节信号恒为 normY（压力只做进入/退出判定）——误提取成 pressure 会导致按住抖动乱调；
        // 进入震动恒为 buzz（区分系统点击）
        var pipeline = legacyPipelineValue
        pipeline.signalSource = .normY
        pipeline.hapticEnter = HapticEvent(enabled: true, waveform: 3, count: 1, intervalUs: 0)
        timeline = TimelineMigrator.migrate(pipeline: pipeline, event: event,
                                            regionID: boundRegionID, eventID: boundEventID,
                                            touchSizeMin: 0.1, touchSizeMax: 1.35,
                                            useForcePress: (threshold, hold))
    }

    // MARK: - 信号源/步长（引擎从单图读取）

    /// tick 链信号源：touchData 出边中第一个连到**非 module** 节点的 SignalSource 端口。
    /// 必须跳过模块输入连线（如 Force 的 touchData.pressure → module）——否则压力被当成滑动信号，
    /// 用户按住不动时 zP 抖动 → 每帧 tick → 音量乱调 + 不停震动（v10.16 教训）。
    private var tickSignalSourcePort: SignalSource? {
        guard let td = timeline.firstNode(of: .touchData) else { return nil }
        let moduleIDs = Set(timeline.nodes.filter { $0.type == .module }.map(\.id))
        for e in timeline.outgoingEdges(from: td.id)
        where !moduleIDs.contains(e.to.nodeID) {
            if let src = SignalSource(rawValue: e.from.portName) {
                return src
            }
        }
        return nil
    }

    /// onTick 链的信号源（touchData 出边中第一个连到非模块节点的 SignalSource 字段端口）
    public var tickSignalSource: SignalSource {
        tickSignalSourcePort ?? .normY
    }

    /// onTick 链的量化步长（图中唯一 quantize 节点）
    public var tickStepNorm: Float {
        timeline.firstNode(of: .quantize)?.params.stepNorm ?? 0.02
    }

    /// 图中全部 haptic 节点的（标题, 参数）—— 波形用途标注用
    public var hapticNodes: [(label: String, params: NodeParams)] {
        timeline.nodes
            .filter { $0.type == .haptic }
            .map { ($0.title ?? $0.type.displayName, $0.params) }
    }

    // MARK: - 类型校验

    /// 校验并清理非法类型边（递归所有子图）：只保留"同类型或含 generic"的边
    /// （用户规则：只能同类型的连同类型的；generic 泛型匹配任意）
    /// 悬空边（端点节点不存在）删除；端口名找不到的边保留（特殊入口注入兼容）。
    /// 返回被删除的边（供日志）。
    @discardableResult
    public mutating func validateEdgeTypes() -> [Edge] {
        var removed: [Edge] = []
        validateEdges(in: &timeline, removed: &removed)
        return removed
    }

    private func validateEdges(in tl: inout TimelineConfig, removed: inout [Edge]) {
        // 先收集非法边（避免 removeAll 闭包内访问 inout tl 的独占访问冲突）
        let invalid = tl.edges.filter { !isValidEdge($0, in: tl) }
        removed.append(contentsOf: invalid)
        tl.edges.removeAll { invalid.contains($0) }
        // 递归子图（module 内部）
        for i in tl.nodes.indices where tl.nodes[i].subgraph != nil {
            if var sub = tl.nodes[i].subgraph {
                validateEdges(in: &sub, removed: &removed)
                tl.nodes[i].subgraph = sub
            }
        }
    }

    private func isValidEdge(_ edge: Edge, in tl: TimelineConfig) -> Bool {
        guard let from = tl.nodes.first(where: { $0.id == edge.from.nodeID }),
              let to = tl.nodes.first(where: { $0.id == edge.to.nodeID }) else {
            return false  // 悬空边：坏数据，删除
        }
        guard let fromType = NodeTypeDef.outputSockets(of: from)
                .first(where: { $0.name == edge.from.portName })?.type,
              let toType = NodeTypeDef.inputSockets(of: to)
                .first(where: { $0.name == edge.to.portName })?.type else {
            return true  // 端口名找不到：特殊入口注入边，保留
        }
        return NodeTypeDef.canConnect(from: fromType, to: toType)
    }

    // MARK: - 基础设置（图上参数的高层快捷读写——降低节点图学习成本，v10.19）

    /// 识别参数集合（双击手势：识别状态机模块内的 compare 阈值；Force 手势：压力阈值/保持时长）
    public struct BasicRecognizeParams {
        public var tapMaxDuration: Double?
        public var tapMaxDrift: Float?
        public var tapMaxGap: Double?
        public var holdMinDuration: Double?
        public var pressureThreshold: Float?
        public var forceHold: Double?
    }

    /// 是否 Force 手势（Force按压识别 模块）
    public var isForceGesture: Bool {
        timeline.nodes.contains { $0.type == .module && $0.title == "Force按压识别" }
    }

    /// 识别参数（从 compare 节点读，含递归子图）
    public var recognizeParams: BasicRecognizeParams {
        let all = timeline.allNodes
        func thr(_ title: String) -> Float? {
            all.first { $0.type == .compare && $0.title == title }?.params.threshold
        }
        return BasicRecognizeParams(
            tapMaxDuration: thr("按下超时?").map(Double.init),
            tapMaxDrift: thr("漂移过大?"),
            tapMaxGap: (thr("间隔内?") ?? thr("间隔超时?")).map(Double.init),
            holdMinDuration: thr("保持够久?").map(Double.init),
            pressureThreshold: thr("压力足够?"),
            forceHold: thr("按够久?").map(Double.init))
    }

    /// 递归更新节点参数（含模块子图）：类型 + 标题匹配 → mutate
    public mutating func updateNodeParams(_ type: NodeType, title: String,
                                          _ mutate: (inout NodeParams) -> Void) {
        var tl = timeline
        updateParams(in: &tl, type: type, title: title, mutate: mutate)
        timeline = tl
    }

    private func updateParams(in tl: inout TimelineConfig, type: NodeType, title: String,
                              mutate: (inout NodeParams) -> Void) {
        for i in tl.nodes.indices {
            if tl.nodes[i].type == type && tl.nodes[i].title == title {
                var p = tl.nodes[i].params
                mutate(&p)
                tl.nodes[i].params = p
            }
            if var sub = tl.nodes[i].subgraph {
                updateParams(in: &sub, type: type, title: title, mutate: mutate)
                tl.nodes[i].subgraph = sub
            }
        }
    }

    /// 写识别阈值（递归子图 compare 标题匹配）
    public mutating func setRecognizeThreshold(_ title: String, _ value: Float) {
        updateNodeParams(.compare, title: title) { $0.threshold = value }
    }

    /// 写信号源：touchData → gate(保持中?).value 连线端口改 source
    public mutating func setSignalSource(_ source: SignalSource) {
        var tl = timeline
        guard let td = tl.firstNode(of: .touchData) else { return }
        let branchIDs = Set(tl.nodes.filter { $0.type == .branch }.map(\.id))
        for i in tl.edges.indices where tl.edges[i].from.nodeID == td.id
            && tl.edges[i].to.portName == "value"
            && branchIDs.contains(tl.edges[i].to.nodeID) {
            tl.edges[i].from.portName = source.rawValue
        }
        timeline = tl
    }

    /// 写变换模式（transform 节点）
    public mutating func setTransformMode(_ mode: TransformMode) {
        updateNodeParams(.transform, title: "变换") { $0.transform = mode }
    }

    /// 写量化参数（quantize 节点）
    public mutating func setQuantize(stepNorm: Float? = nil, triggerMode: TriggerMode? = nil,
                                     sensitivity: Float? = nil) {
        updateNodeParams(.quantize, title: "量化") { p in
            if let s = stepNorm { p.stepNorm = s }
            if let t = triggerMode { p.triggerMode = t }
            if let s = sensitivity { p.sensitivity = s }
        }
    }

    /// 写震动参数（根图 haptic 节点标题匹配）
    public mutating func setHaptic(_ title: String, waveform: Int32? = nil, count: Int? = nil,
                                   intervalUs: Int32? = nil) {
        updateNodeParams(.haptic, title: title) { p in
            if let w = waveform { p.waveform = w }
            if let c = count { p.count = c }
            if let i = intervalUs { p.intervalUs = i }
        }
    }
}
