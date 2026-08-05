import Foundation

/// 配置持久化 + v1/v2 → v3 迁移
public enum ConfigStore {

    /// v2 顶层配置（仅用于解码旧 JSON 并迁移）
    struct AppConfigV2: Codable {
        var version: Int
        var global: GlobalSettings
        var regions: [RegionConfig]
        var gestures: [GestureConfigV2]
        var events: [EventConfig]
    }

    /// 用户当前配置
    public static var configURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TouchpadGestures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    /// 用户自定义默认配置
    public static var userDefaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TouchpadGestures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("default.json")
    }

    // MARK: - v1 旧格式（扁平 GestureConfig）
    /// v1 扁平配置结构，仅用于迁移解码
    struct V1Config: Codable {
        var frameRateLimit: Double = 0
        var touchSizeMax: Float = 1.35
        var touchSizeMin: Float = 0.1
        var edgeRightThreshold: Float = 0.80
        var edgeLeftThreshold: Float = 0.20
        var tapMaxDuration: Double = 0.20
        var tapMaxDrift: Float = 0.05
        var tapMaxGap: Double = 0.30
        var holdMinDuration: Double = 0.20
        var hapticEnter: Int32 = 2
        var volumeStepNorm: Float = 0.02
        var volumeStep: Float = 0.0125
        var brightnessStepNorm: Float = 0.02
        var brightnessStep: Float = 0.0125
        var hapticTick: Int32 = 4
        var boundaryThreshold: Float = 0.001
        var hapticBoundary: Int32 = 2
        var boundaryHapticInterval: Int32 = 50000
        var disassociateMouse: Bool = true
    }

    /// 加载配置（自动迁移 v1 / v2 → v3）
    public static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL) else {
            return AppConfig()
        }
        // 先尝试 v3（当前格式）；旧 v3 文件顶层绑定补入图并保存（图成为唯一事实来源）
        if var cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
            var didChange = false
            // 尺寸过滤修复：旧默认 touchSizeMax=1.0 会过滤较重按压的手指（按压 size 可达 ~1.35）
            // → touching 随机 false → 双击保持中随机退出/误触发；低于 1.2 视为旧默认，提到 1.35
            if cfg.global.touchSizeMax < 1.2 {
                cfg.global.touchSizeMax = 1.35
                didChange = true
            }
            for i in cfg.gestures.indices {
                var gesture = cfg.gestures[i]
                // v8 升级：状态机黑盒（recognizer）→ 展开图（从旧图提取参数重新迁移）
                if gesture.timeline.firstNode(of: .recognizer) != nil {
                    gesture.upgradeStateMachineGraph(events: cfg.events)
                    didChange = true
                }
                // v9 升级：v8 扁平展开图 → 模块化图（识别状态机/冻结管理封装成可折叠组）
                if gesture.timeline.firstNode(of: .module) == nil,
                   gesture.timeline.firstNode(of: .varRef) != nil {
                    gesture.upgradeModularGraph(events: cfg.events)
                    didChange = true
                }
                // v10 升级：旧边界判定 → 方向感知（冻结已屏蔽）；v10.17 起含 boundaryState 的边界分流整体移除
                // （trackedValue 漂移误判"朝外"→ 值卡中间；系统自身 clamp 处理边界）
                let legacyBoundary = gesture.timeline.nodes.contains { $0.type == .branch && $0.params.predicate == .notAtBoundary }
                let activeFreeze = gesture.timeline.nodes.contains { node in
                    node.type == .module
                        && (node.params.moduleInputs?.contains { $0.name == "boundaryPulse" } ?? false)
                        && gesture.timeline.edges.contains { $0.to.nodeID == node.id && $0.to.portName == "boundaryPulse" }
                }
                if legacyBoundary || activeFreeze
                    || gesture.timeline.firstNode(of: .boundaryState) != nil {
                    gesture.upgradeBoundarySense(events: cfg.events)
                    didChange = true
                }
                // v10.16 升级：旧 Force 图（pressure 来自 touchData，任意位置触发）→ finger.pressure 区域内 + touching 条件
                if gesture.timeline.nodes.contains(where: { $0.type == .module && $0.title == "Force按压识别" }) {
                    gesture.upgradeForcePress(events: cfg.events)
                    didChange = true
                }
                gesture.ensureBindingsInGraph()
                // 全局触摸尺寸/手掌过滤是唯一事实来源：finger 节点参数同步 global（含递归子图）
                let synced = syncingFingerSizes(gesture.timeline,
                                                sizeMin: cfg.global.touchSizeMin,
                                                sizeMax: cfg.global.touchSizeMax,
                                                palmFilter: cfg.global.palmFilter)
                if synced != gesture.timeline {
                    gesture.timeline = synced
                    didChange = true
                }
                // 类型校验：只保留"同类型或含 generic"的边（用户规则：只能同类型的连同类型的）
                let removed = gesture.validateEdgeTypes()
                if !removed.isEmpty {
                    fputs("[Config] \(gesture.name) 删除 \(removed.count) 条非法类型边: " +
                          removed.map { "\($0.from.portName)->\($0.to.portName)" }.joined(separator: ", ") + "\n", stderr)
                    didChange = true
                }
                if gesture != cfg.gestures[i] {
                    cfg.gestures[i] = gesture
                    didChange = true
                }
            }
            // v10.14：Force 按压手势自动补齐（左/右边缘各一，压力保持进入——与双击手势共存，
            // 压力识别互不干扰：重按不会让双击手势进 holding，轻点不会让 Force 手势进 holding）
            let forceSpecs: [(name: String, regionName: String, action: ActionType)] = [
                ("左侧Force", "左边缘", .brightness), ("右侧Force", "右边缘", .volume),
            ]
            for spec in forceSpecs where !cfg.gestures.contains(where: { $0.name == spec.name }) {
                guard let region = cfg.regions.first(where: { $0.name == spec.regionName }),
                      let event = cfg.events.first(where: { $0.actionType == spec.action }) else {
                    fputs("[Config] Force 补齐跳过 \(spec.name)：region/action 未匹配\n", stderr)
                    continue
                }
                // Force 进入震动用 buzz（波形3）——与系统触控板点击（click 1/2）明显区分（用户反馈"波形和正常点击没法区分"）
                var forcePipeline = LegacyPipelineConfig()
                forcePipeline.hapticEnter = HapticEvent(enabled: true, waveform: 3, count: 1, intervalUs: 0)
                cfg.gestures.append(GestureConfig(name: spec.name, regionID: region.id, eventID: event.id,
                                                  forcePipeline: forcePipeline, event: event,
                                                  pressureThreshold: 2.0, holdMinDuration: 0.3))
                fputs("[Config] 补齐 Force 手势：\(spec.name)\n", stderr)
                didChange = true
            }
            if didChange { save(cfg) }
            return cfg
        }
        // v2 迁移
        if let v2 = try? JSONDecoder().decode(AppConfigV2.self, from: data) {
            let migrated = migrate(v2: v2)
            save(migrated)
            return migrated
        }
        // v1 迁移
        if let v1 = try? JSONDecoder().decode(V1Config.self, from: data) {
            let migrated = migrate(v1: v1)
            save(migrated)
            return migrated
        }
        return AppConfig()
    }

    /// **诊断最简模式**（隔离验证 tick 底层链路）：每个手势的图重建为最简图——
    /// 屏蔽识别状态机（轻点/双击/进入 holding），手指在绑定区域内接触直接门控 tick 链。
    /// 不落盘（内存态，仅当前进程生效），关闭开关重启即恢复完整图。
    public static func applyMinimalDiagnostic(to cfg: AppConfig) -> AppConfig {
        var c = cfg
        for i in c.gestures.indices {
            var gesture = c.gestures[i]
            guard let regionID = gesture.boundRegionID,
                  let eventID = gesture.boundEventID,
                  let event = c.events.first(where: { $0.id == eventID }) else { continue }
            gesture.timeline = TimelineMigrator.migrate(pipeline: gesture.legacyPipelineValue,
                                                        event: event,
                                                        regionID: regionID, eventID: eventID,
                                                        touchSizeMin: c.global.touchSizeMin,
                                                        touchSizeMax: c.global.touchSizeMax,
                                                        minimalDiagnostic: true)
            c.gestures[i] = gesture
        }
        fputs("[Config] 诊断最简模式：已屏蔽识别状态机，手指接触即调节\n", stderr)
        return c
    }

    /// 保存配置
    public static func save(_ config: AppConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: configURL, options: .atomic)
    }

    // MARK: - 迁移

    /// v2 → v3：每个 v2 手势用迁移器生成 Timeline 图集
    static func migrate(v2: AppConfigV2) -> AppConfig {
        let gestures = v2.gestures.map { g2 -> GestureConfig in
            let event = v2.events.first { $0.id == g2.eventID } ?? EventConfig.defaultVolume
            let pipeline = LegacyPipelineConfig(
                signalSource: g2.signalSource,
                transformMode: g2.transformMode,
                triggerMode: g2.triggerMode,
                stepNorm: g2.stepNorm,
                sensitivity: g2.sensitivity,
                hapticEnter: g2.hapticEnter,
                hapticTick: g2.hapticTick,
                hapticBoundary: g2.hapticBoundary,
                hapticExit: g2.hapticExit,
                disassociateMouse: g2.disassociateMouse,
                tapMaxDuration: g2.tapMaxDuration,
                tapMaxDrift: g2.tapMaxDrift,
                tapMaxGap: g2.tapMaxGap,
                holdMinDuration: g2.holdMinDuration)
            return GestureConfig(id: g2.id, name: g2.name,
                                 regionID: g2.regionID, eventID: g2.eventID,
                                 timeline: TimelineMigrator.migrate(pipeline: pipeline, event: event,
                                                                    regionID: g2.regionID, eventID: g2.eventID,
                                                                    touchSizeMin: v2.global.touchSizeMin,
                                                                    touchSizeMax: v2.global.touchSizeMax))
        }
        return AppConfig(version: 3, global: v2.global, regions: v2.regions,
                         gestures: gestures, events: v2.events)
    }

    /// v1 → v3（经过 v2 语义中间层，一步生成图集）
    static func migrate(v1: V1Config) -> AppConfig {
        let left = RegionConfig(name: "左边缘", xMin: 0, xMax: v1.edgeLeftThreshold, yMin: 0, yMax: 1)
        let right = RegionConfig(name: "右边缘", xMin: v1.edgeRightThreshold, xMax: 1, yMin: 0, yMax: 1)
        let volume = EventConfig(name: "音量", actionType: .volume, step: v1.volumeStep, boundaryThreshold: v1.boundaryThreshold)
        let brightness = EventConfig(name: "亮度", actionType: .brightness, step: v1.brightnessStep, boundaryThreshold: v1.boundaryThreshold)
        let global = GlobalSettings(frameRateLimit: v1.frameRateLimit, touchSizeMin: v1.touchSizeMin, touchSizeMax: v1.touchSizeMax)

        let basePipeline = LegacyPipelineConfig(
            hapticEnter: HapticEvent(enabled: true, waveform: v1.hapticEnter, count: 1, intervalUs: 0),
            hapticTick: HapticEvent(enabled: true, waveform: v1.hapticTick, count: 1, intervalUs: 0),
            hapticBoundary: HapticEvent(enabled: true, waveform: v1.hapticBoundary, count: 2, intervalUs: v1.boundaryHapticInterval),
            hapticExit: .exit,
            disassociateMouse: v1.disassociateMouse,
            tapMaxDuration: v1.tapMaxDuration, tapMaxDrift: v1.tapMaxDrift,
            tapMaxGap: v1.tapMaxGap, holdMinDuration: v1.holdMinDuration)

        var leftPipeline = basePipeline
        leftPipeline.stepNorm = v1.brightnessStepNorm
        leftPipeline.signalSource = .normY
        var rightPipeline = basePipeline
        rightPipeline.stepNorm = v1.volumeStepNorm

        let leftGesture = GestureConfig(name: "左侧", regionID: left.id, eventID: brightness.id,
                                        timeline: TimelineMigrator.migrate(pipeline: leftPipeline, event: brightness,
                                                                           regionID: left.id, eventID: brightness.id,
                                                                           touchSizeMin: global.touchSizeMin,
                                                                           touchSizeMax: global.touchSizeMax))
        let rightGesture = GestureConfig(name: "右侧", regionID: right.id, eventID: volume.id,
                                         timeline: TimelineMigrator.migrate(pipeline: rightPipeline, event: volume,
                                                                            regionID: right.id, eventID: volume.id,
                                                                            touchSizeMin: global.touchSizeMin,
                                                                            touchSizeMax: global.touchSizeMax))
        return AppConfig(version: 3, global: global, regions: [left, right],
                         gestures: [leftGesture, rightGesture], events: [volume, brightness])
    }

    // MARK: - 用户默认配置
    public static func saveAsDefault(_ config: AppConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: userDefaultURL, options: .atomic)
    }

    public static func loadDefault() -> AppConfig {
        if let data = try? Data(contentsOf: userDefaultURL),
           let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return cfg
        }
        return AppConfig()
    }

    public static func clearUserDefault() {
        try? FileManager.default.removeItem(at: userDefaultURL)
    }

    // MARK: - 手指尺寸同步（全局 touchSize 是唯一事实来源，finger 节点参数跟随，含递归子图）

    static func syncingFingerSizes(_ timeline: TimelineConfig,
                                   sizeMin: Float, sizeMax: Float,
                                   palmFilter: Bool) -> TimelineConfig {
        var tl = timeline
        for i in tl.nodes.indices {
            if tl.nodes[i].type == .finger {
                tl.nodes[i].params.touchSizeMin = sizeMin
                tl.nodes[i].params.touchSizeMax = sizeMax
                tl.nodes[i].params.palmFilter = palmFilter
            }
            if var sub = tl.nodes[i].subgraph {
                sub = syncingFingerSizes(sub, sizeMin: sizeMin, sizeMax: sizeMax, palmFilter: palmFilter)
                tl.nodes[i].subgraph = sub
            }
        }
        return tl
    }
}
