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

    /// 测试注入：重定向 configURL（避免单测读写真实用户配置）
    static var overrideConfigURL: URL?

    /// 是否运行在测试进程里（XCTest 会注入该环境变量）。
    /// 根因防护：`GestureEngine.config` 的 setter 会无条件 `ConfigStore.save`，
    /// 而单测里构造的 `AppConfig()` 用的是**全新随机 UUID**——一旦某个测试忘了设置
    /// `overrideConfigURL`，就会把"测试用默认配置"直接写进**用户的真实 config.json**，
    /// 把用户的手势/区域/事件 id 全部换掉（且旧 id 不可恢复）。
    /// 故在此兜底：测试进程内绝不允许写真实路径，只能写显式重定向的临时文件。
    static var isRunningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// 用户当前配置
    public static var configURL: URL {
        if let override = overrideConfigURL { return override }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TouchpadGestures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    /// 是否允许写盘：测试进程必须显式重定向，否则拒绝（防止污染用户真实配置）
    private static var mayPersist: Bool {
        overrideConfigURL != nil || !isRunningUnderTests
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
    ///
    /// **损坏防护**：JSON 无法解析时绝不直接丢弃用户配置。原实现任何读取/解码失败都返回
    /// `AppConfig()`（4 个全新随机 UUID 手势），随后任意一次 UI 编辑就会把这份空配置
    /// 覆写回真实 `config.json`，用户原配置不可恢复。现在改为：损坏文件先备份为
    /// `config.corrupt-<时间戳>.json` 并打印 stderr，再回退默认值——数据始终可从备份取回。
    public static func load() -> AppConfig {
        let url = configURL
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        guard let data = try? Data(contentsOf: url) else {
            // 文件存在但读不出（权限/半写）→ 隔离备份；文件本就不存在（首次运行）→ 静默默认
            if fileExists {
                quarantineCorruptConfig(reason: "读取失败（权限或文件不完整）")
            }
            return AppConfig()
        }
        // 版本探测（H1 修复）：v2 JSON 顶层 version=2 且键集合与 AppConfig 重合，若先 decode v3
        // 必被宽松成功 → gesture 缺 timeline 键回退空图、version=2 写回、迁移分支不可达。
        // 故优先按顶层 version 分流：<3 先走 v2/v1 迁移；无 version 键视为 v1 扁平。
        let version: Int? = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { ($0["version"] as? NSNumber)?.intValue }
        if let version, version < 3 {
            if let v2 = try? JSONDecoder().decode(AppConfigV2.self, from: data) {
                let migrated = migrate(v2: v2)
                save(migrated)
                return migrated
            }
            if let v1 = try? JSONDecoder().decode(V1Config.self, from: data) {
                let migrated = migrate(v1: v1)
                save(migrated)
                return migrated
            }
            quarantineCorruptConfig(reason: "version=\(version) 但 v2/v1 均解码失败")
            return AppConfig()
        }
        if version == nil, let v1 = try? JSONDecoder().decode(V1Config.self, from: data) {
            let migrated = migrate(v1: v1)
            save(migrated)
            return migrated
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
                // H2：保证所有 module 节点有非空子图（缺失补空子图）——旧配置里 module
                // 无子图会导致双击进入后把根图写进子图 → 执行期无限递归
                let ensured = gesture.timeline.ensuringModuleSubgraphs()
                if ensured != gesture.timeline {
                    gesture.timeline = ensured
                    didChange = true
                }
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
            didChange = ensureEdgeSeekGestures(&cfg) || didChange
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
        quarantineCorruptConfig(reason: "v3/v2/v1 全部解码失败")
        return AppConfig()
    }

    /// 把损坏的 config.json 隔离备份（绝不在原地丢弃用户数据）。
    /// 备份文件名带时间戳，保留原始字节以便人工恢复；同时打印 stderr 便于排查。
    /// 备份成功后原文件会被移走，避免后续 save 把默认值写回原路径时"看起来正常"。
    private static func quarantineCorruptConfig(reason: String) {
        guard mayPersist else { return }
        let src = configURL
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = src.deletingLastPathComponent()
            .appendingPathComponent("config.corrupt-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: src, to: backup)
            fputs("[Config] 配置损坏（\(reason)）→ 已备份为 \(backup.lastPathComponent)，"
                  + "本次以默认配置启动。原配置未被删除，可人工恢复。\n", stderr)
            DiagnosticsBus.config("config_corrupted",
                                  "配置文件损坏，已备份为 \(backup.lastPathComponent) 并以默认配置启动",
                                  context: ["reason": reason,
                                            "backup": backup.lastPathComponent])
        } catch {
            fputs("[Config] 配置损坏（\(reason)）且备份失败：\(error)。"
                  + "为安全起见保留原文件不动。\n", stderr)
            DiagnosticsBus.config("config_corrupt_backup_failed",
                                  "配置文件损坏且备份失败：\(error.localizedDescription)",
                                  context: ["reason": reason])
        }
    }

    /// **v11 补齐**：上下边缘横向滑动 → 媒体进度（seek）。为旧配置补齐：
    /// seek 事件、上/下边缘区域、上边缘手势（启用）、下边缘手势（配置但不启用）。
    /// 已有同名手势/区域/ActionType 时不重复添加。返回是否发生变更。
    @discardableResult
    static func ensureEdgeSeekGestures(_ cfg: inout AppConfig) -> Bool {
        // 两个手势都已存在 → 无需补齐
        guard !(cfg.gestures.contains { $0.name == "上边缘" }
                && cfg.gestures.contains { $0.name == "下边缘" }) else { return false }
        let regionNames = ["上边缘", "下边缘"]
        var changed = false
        // 1) seek 事件
        var seek = cfg.events.first { $0.actionType == .seek }
        if seek == nil {
            seek = EventConfig.defaultSeek
            cfg.events.append(seek!)
            fputs("[Config] 补齐媒体进度事件\n", stderr)
            changed = true
        }
        // 2) 上/下边缘区域
        var regions: [String: RegionConfig] = [:]
        for name in regionNames {
            if let existing = cfg.regions.first(where: { $0.name == name }) {
                regions[name] = existing
                continue
            }
            let region = (name == "上边缘") ? RegionConfig.defaultTop : RegionConfig.defaultBottom
            cfg.regions.append(region)
            regions[name] = region
            fputs("[Config] 补齐区域：\(name)\n", stderr)
            changed = true
        }
        // 3) 手势：上边缘启用、下边缘不启用
        let specs: [(name: String, region: String, enabled: Bool)] = [
            ("上边缘", "上边缘", true), ("下边缘", "下边缘", false),
        ]
        for spec in specs where !cfg.gestures.contains(where: { $0.name == spec.name }) {
            guard let region = regions[spec.region], let event = seek else { continue }
            cfg.gestures.append(GestureConfig(name: spec.name, regionID: region.id, eventID: event.id,
                                              pipeline: LegacyPipelineConfig(signalSource: .normX),
                                              event: event, enabled: spec.enabled))
            fputs("[Config] 补齐边缘手势：\(spec.name)\n", stderr)
            changed = true
        }
        return changed
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

    /// 保存配置。
    ///
    /// **不得静默吞掉编码错误**：`JSONEncoder` 对 NaN/±Inf 会抛错（用户可在节点参数里输入
    /// "nan"），原实现 `try?` 一吞，后续每次保存都静默失效而 UI 看起来正常。现在把失败
    /// 打到 stderr，返回是否成功，供调用方感知。
    @discardableResult
    public static func save(_ config: AppConfig) -> Bool {
        // 测试进程未重定向 → 拒绝写盘（否则会把测试默认配置写进用户真实 config.json）
        guard mayPersist else { return false }
        let data: Data
        do {
            data = try JSONEncoder().encode(config)
        } catch {
            fputs("[Config] 保存失败（编码错误，可能是 NaN/Inf 参数）：\(error)\n", stderr)
            DiagnosticsBus.config("config_encode_failed",
                                  "配置保存失败（编码错误，可能是 NaN/Inf 参数）：\(error.localizedDescription)")
            return false
        }
        do {
            try data.write(to: configURL, options: .atomic)
            return true
        } catch {
            fputs("[Config] 保存失败（写入错误）：\(error)\n", stderr)
            DiagnosticsBus.config("config_write_failed",
                                  "配置保存失败（写入错误）：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 合并写入（防抖）

    /// 待写入的最新配置 + 其调度状态。
    /// 目的：UI 拖动一个滑杆会产生 **每一帧一次** `engine.config = ...` → 原实现每次都
    /// 同步 JSON 编码 + 原子落盘（N 次/秒），既卡帧又磨损 SSD。改为合并：短时间内多次
    /// 保存只落盘最后一次，且写盘移到专用串行队列（不阻塞主线程/tick 线程）。
    private static let saveQueue = DispatchQueue(label: "com.touchpad.config.save", qos: .utility)
    private static let pendingLock = NSLock()
    private static var pendingConfig: AppConfig?
    private static var pendingWorkItem: DispatchWorkItem?
    /// 合并窗口：略大于一帧（16ms），既能吸收拖拽期间的高频写入，又保证用户松手后很快落盘
    private static let saveDebounceInterval: DispatchTimeInterval = .milliseconds(300)

    /// 防抖保存：把最新配置排入待写，300ms 内的后续调用覆盖前一次。
    /// - Note: 进程退出路径请调用 `flushPendingSave()` 确保不丢最后一次修改。
    public static func saveCoalesced(_ config: AppConfig) {
        guard mayPersist else { return }
        pendingLock.lock()
        pendingConfig = config
        pendingWorkItem?.cancel()
        let item = DispatchWorkItem {
            pendingLock.lock()
            let toWrite = pendingConfig
            pendingConfig = nil
            pendingWorkItem = nil
            pendingLock.unlock()
            if let toWrite { saveQueue.async { _ = save(toWrite) } }
        }
        pendingWorkItem = item
        pendingLock.unlock()
        // 在全局队列延迟触发（而非主队列）：即便主线程正忙于 SwiftUI 渲染也能准时落盘
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + saveDebounceInterval, execute: item)
    }

    /// 立即把待写配置落盘（退出/关窗时调用，避免防抖窗口内的修改丢失）。
    public static func flushPendingSave() {
        pendingLock.lock()
        let toWrite = pendingConfig
        pendingConfig = nil
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        pendingLock.unlock()
        if let toWrite { _ = save(toWrite) }
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
        // 与 save 同源防护：测试进程未重定向时拒绝写盘，否则会污染用户真实 default.json
        guard mayPersist else { return }
        guard let data = try? JSONEncoder().encode(config) else {
            fputs("[Config] 保存默认配置失败（编码错误）\n", stderr)
            DiagnosticsBus.config("default_encode_failed", "保存默认配置失败（编码错误）")
            return
        }
        do {
            try data.write(to: userDefaultURL, options: .atomic)
        } catch {
            fputs("[Config] 保存默认配置失败（写入错误）：\(error)\n", stderr)
            DiagnosticsBus.config("default_write_failed",
                                  "保存默认配置失败（写入错误）：\(error.localizedDescription)")
        }
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
