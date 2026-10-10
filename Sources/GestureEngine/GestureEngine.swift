import Foundation
import Darwin
import CoreGraphics
import AppKit
import mt_bridge

/// 手势引擎（v6 识别器节点化）：
/// - 不再运行自己的状态机——识别器节点（图上）内部做轻点/双击/保持识别，输出时机脉冲
/// - 引擎每帧把原始触摸帧注入 FrameContext，执行整张图，副作用经图上节点派发
/// - 引擎保留系统能力：鼠标锁定 warp、事件引用（trackedValue 跨帧）、边界判断注入、冻结请求传递
public final class GestureEngine {

    /// 配置（_config 存储）：setter 落盘——但 **init 直接写 _config 不触发 save**，
    /// 否则诊断模式加载（applyMinimalDiagnostic 内存图）会把诊断图错误落盘覆盖用户配置（v10.11 教训）
    private var _config: AppConfig
    /// 配置访问锁：tick 线程每帧读 config，主线程（设置 UI 编辑/updateConfig）写 config——
    /// 无锁时并发读写同一存储属性会触发 Swift 独占访问检查崩溃 / 数组越界（"打开设置闪退"根因）
    private let configLock = NSLock()
    public var config: AppConfig {
        get {
            configLock.lock()
            defer { configLock.unlock() }
            return _config
        }
        set {
            configLock.lock()
            _config = newValue
            configLock.unlock()
            ConfigStore.save(newValue)
        }
    }
    /// 锁内原子"读-改-写"：与主线程 UI 编辑互斥（同一临界区内按 eventID 实时重查索引，
    /// 避免旧快照索引越界 / 覆盖用户最新修改——"打开设置闪退"根因修复）
    private func mutateConfig(_ mutate: (inout AppConfig) -> Void) {
        configLock.lock()
        mutate(&_config)
        let saved = _config
        configLock.unlock()
        ConfigStore.save(saved)
    }
    public var deviceID: UInt64 = 0

    // 鼠标关联状态
    private var mouseDisassociated = false
    private var lockedCursorPos: CGPoint = .zero

    // 副作用桥接
    private let effects: EngineEffects

    /// 每手势的执行器 + 跨帧状态 + 上帧 holding 标志（key = gesture.id）
    private struct Runtime {
        var evaluator: GraphEvaluator
        var store: StateStore
        var wasHolding = false
        /// 该 evaluator 对应的图快照（用于检测"图被编辑"→ 重建执行器）
        var graph: TimelineConfig
    }
    private var runtimes: [UUID: Runtime] = [:]
    /// 当前有手势在 holding（phase 变量 == 4）
    private(set) var holdingCount = 0
    /// 当前 holding 的手势名（UI 显示）
    public private(set) var currentHoldingGestureName: String?
    /// 每手势的事件引用（key = gesture.id；consume 的 trackedValue 跨帧保留）。
    /// per-gesture（v10.20 修复）：原单一 eventBox 被多手势共享，两只手同时在不同边缘
    /// holding 时后进入的手势会消费前一手势的事件 → 调节错对象 + trackedValue 写回串台
    private var eventBoxes: [UUID: EventBox] = [:]

    /// 诊断最简模式（默认关闭）：屏蔽识别状态机等一切与 tick 无关的逻辑，
    /// 手指接触绑定区域即调节——隔离验证"MT 回调 → finger → tick"底层链路。
    /// 置 true 后重启 app 进入诊断模式；false（默认）走完整手势图（识别轻点双击进入 holding）。
    public static var diagnosticMinimalTick = false
    /// 诊断日志（v10.16 Force 阈值校准残留，校准完成后默认关闭）：
    /// 开启后在触控板有手指时 ~20Hz 往 stderr 刷日志。需要排障时置 true 重启。
    public static var forceDebugLogging = false

    public init() {
        var cfg = ConfigStore.load()
        if Self.diagnosticMinimalTick {
            cfg = ConfigStore.applyMinimalDiagnostic(to: cfg)
        }
        _config = cfg    // init 不触发 save（避免诊断图落盘覆盖用户配置）
        NodeExecutors.debugLogging = Self.diagnosticMinimalTick || Self.forceDebugLogging
        effects = EngineEffects()
        effects.engine = self
    }

    private func elog(_ msg: String) {
        #if DEBUG
        DiagnosticsLog.log(msg)   // 可插拔诊断：环形缓冲（导出诊断包用）
        #endif
        // 引擎级 /tmp 日志：诊断最简模式或设置页「诊断日志」开关（forceDebugLogging）开启时写入
        guard Self.diagnosticMinimalTick || Self.forceDebugLogging else { return }
        EngineLog.append("[ENGINE] \(msg)")
    }

    // MARK: - 固定步长帧循环（Godot 式：回调只更新快照，逻辑由固定 tick 驱动）

    /// MT 回调不稳定（采样间歇/丢帧/抬起后可能停止回调），若直接用它驱动状态机：
    /// 计时跳变、边沿丢失、回调停止时时间冻结导致状态机死锁（"进不了状态"）。
    /// 参照 Godot main_timer_sync 的 fixed timestep + accumulator：
    /// - MT 回调只更新最新触摸快照（onTouchFrame）
    /// - DispatchSourceTimer 以固定步长（8.33ms ≈ 120Hz）驱动 pump()
    /// - pump 用时间累积器决定跑几个 tick；间隔超过 maxAccum（挂起/休眠）丢弃不追赶
    /// - 状态机/计时全用"模拟时钟" simTime（每次 tick 固定 +tickInterval，持续前进），
    ///   与回调频率/定时器抖动完全解耦 → 判定确定、可预期
    private let tickQueue = DispatchQueue(label: "com.touchpad.engine.tick")
    private var timer: DispatchSourceTimer?
    private var latestTouches: [mt_touch_t] = []
    private let touchesLock = NSLock()
    private var simTime: Double = 0
    private var lastWall: Double = 0
    private var tickAccum: Double = 0
    private var lastTouchWall: Double = 0
    private var started = false
    /// 引擎帧循环是否在运行（设置页「引擎状态」显示用；计算属性只读，无需 private(set)）
    public var isRunning: Bool { started }
    private static let tickInterval = 1.0 / 120.0
    /// 防追赶螺旋：一次间隔超过该值（挂起/休眠/长停顿）直接丢弃，不补跑（Godot 同样忽略超长 delta）
    private static let maxAccum = 0.25
    /// 触摸快照「陈旧」阈值（秒）：超过该时长没有新的 MT 回调 = 手指已离开、回调已停止。
    /// 与 finger 节点判抬起的 `staleEmpty`（200ms）同源同值。
    static let staleTouchInterval = 0.2
    /// holding 期间使用更宽的陈旧阈值（v10.11 保护）：MT 在滑动中会有采样间歇，
    /// 阈值太紧会把陈旧帧当空帧 → finger 判抬起 → 滑动中误退出 holding（用户核心痛点）。
    /// 实测 holding 期间回调间隔上限仅 ~87ms，1.0s 留了 >10× 余量；而真离开时
    /// MT 彻底静默，1.0s 后仍能把状态机拉回 idle（否则 holding 永不退出、光标永久锁死）。
    static let holdingStaleInterval = 1.0
    /// 空载慢速时钟步长（省电）：确认全局 idle 后把帧定时器从 120Hz 降到 20Hz。
    /// 触摸到达时 `onTouchFrame` 会直接 pump（不依赖定时器），故响应延迟不受影响；
    /// 空载期间 simTime 仍按真实墙钟整步推进（见 pump），frame.now 连续，恢复求值时计时不丢。
    private static let idleTickInterval = 1.0 / 20.0
    /// 当前是否处于「空载慢速」——仅在 tickQueue 上读写
    private var idleSlowed = false
    /// 本拍是否有新触摸到达（tickQueue 上读写）：触摸必须立刻全速处理，不做空载整步跳过
    private var pendingTouch = false
    /// 标识「当前线程就是 tickQueue」——用于避免 stop() 从 tickQueue 上调用时 sync 自锁死
    private let onTickQueueKey = DispatchSpecificKey<Bool>()

    /// 在 tickQueue 上同步执行（若已在 tickQueue 上则直接执行，绝不 sync 自身 → 无死锁）
    private func syncOnTickQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: onTickQueueKey) == true {
            body()
        } else {
            tickQueue.sync(execute: body)
        }
    }

    /// 启动固定步长帧循环（mt_start_touch 之后调用）
    public func start() {
        guard !started else { return }
        started = true
        tickQueue.setSpecific(key: onTickQueueKey, value: true)
        let t = DispatchSource.makeTimerSource(queue: tickQueue)
        t.schedule(deadline: .now(), repeating: Self.tickInterval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.pump() }
        t.resume()
        timer = t
    }

    public func stop() {
        guard started else { return }
        started = false
        timer?.cancel()
        timer = nil
        // 复位帧循环状态（重启后从全速时钟 + 干净累积器开始）。
        // 用 syncOnTickQueue：调用方通常是主线程，但从 tickQueue 内调用也不会自锁死。
        syncOnTickQueue {
            self.idleSlowed = false
            self.pendingTouch = false
            self.tickAccum = 0
            self.lastWall = 0
        }
        // 清理 holding 状态（重启后不残留旧 eventBox/trackedValue/wasHolding）
        eventBoxes.removeAll(keepingCapacity: true)
        effects.eventBox = nil
        for (id, var rt) in runtimes {
            rt.wasHolding = false
            runtimes[id] = rt
        }
        holdingCount = 0
        currentHoldingGestureName = nil
        restoreMouse()
    }

    /// MT 回调入口（任意线程）：只更新最新触摸快照 + 记录快照时刻，不驱动逻辑。
    /// 之后补一次泵，让状态机对触摸的响应延迟 ≤ 一个 tick（8ms）
    public func onTouchFrame(touches: [mt_touch_t]) {
        touchesLock.lock()
        latestTouches = touches
        lastTouchWall = ProcessInfo.processInfo.systemUptime
        touchesLock.unlock()
        tickQueue.async { [weak self] in
            guard let self else { return }
            // 触摸到达 = 可能要做识别/滑动 → 立刻脱离空载慢速（不能等下一次定时器唤醒）。
            // 只在 tickQueue 上改 idleSlowed/pendingTouch，避免与 pump 竞争
            self.pendingTouch = true
            self.pump()
            self.pendingTouch = false
        }
    }

    /// 时间累积器：把墙钟增量折算成固定步长 tick（Godot MainTimerSync::advance_core 模式）。
    ///
    /// 两条路径（v10.22 功耗修复）：
    /// - **空载慢速**：确认全局 idle 后，本帧**只做一次 idle 判定**，把模拟时钟按真实墙钟整步推进
    ///   （不补跑累积的 1/120 小步）。这样空载既减少定时器唤醒（120Hz → 20Hz），
    ///   也减少每帧固定开销，且不会追赶螺旋。安全性由 idle 不变量保证：所有手势 phase==0
    ///   且无 holding 时，不存在任何待处理的时间驱动转移，丢弃中间的 1/120 细分不会漏掉事件。
    /// - **活跃全速**：正常累积器，按固定 1/120 步长补跑，保证交互期计时确定。
    private func pump() {
        let wall = ProcessInfo.processInfo.systemUptime
        if lastWall == 0 {
            lastWall = wall
            return
        }
        let delta = min(wall - lastWall, Self.maxAccum)
        lastWall = wall

        if idleSlowed && !pendingTouch {
            // 空载：整步推进模拟时钟 + 一次判定；不补跑细分步
            tickAccum = 0
            simTime += delta
            tick()
            return
        }

        tickAccum += delta
        // 触摸到达但累积不足一个固定步长（慢速时钟下 delta 可能只有几毫秒）→ 立即处理，
        // 不等下一拍，避免省电把首次触摸的响应延迟拖到 1/20 s。
        // 把已累积的真实时长计入模拟时钟（而非硬给一整步）：now 严格递增，且总时长与墙钟一致，
        // 时间类节点（保持 0.2s / 间隔 0.3s 等）不会因为省电而走快。
        if pendingTouch && tickAccum < Self.tickInterval {
            simTime += tickAccum
            tickAccum = 0
            tick()
            return
        }

        while tickAccum >= Self.tickInterval {
            tickAccum -= Self.tickInterval
            simTime += Self.tickInterval
            tick()
            // tick 内刚判定为空载 → 本次唤醒剩余细分步无意义，交给下一拍慢速整步
            if idleSlowed { break }
        }
    }

    /// 固定步长逻辑执行（读取最新快照）
    private func tick() {
        touchesLock.lock()
        let touches = latestTouches
        let touchWall = lastTouchWall
        touchesLock.unlock()
        let wallNow = ProcessInfo.processInfo.systemUptime

        // 快照陈旧 = 超过阈值没有新的 MT 回调 = 手指已离开、回调已停止。
        // 此时必须把**空帧**喂给图，否则冻结的最后一帧会把识别状态机永久钉在 phase 3/4/5：
        // 最后一帧常含 state=4/6 的残留触摸，finger 节点据此认为"还有手指"，up 永不触发。
        // 实测后果：空载 0.5% → 40% CPU 常驻且**不自愈**（唯一解法是重启 app）。
        //
        // holding 期间用更宽的 holdingStaleInterval（v10.11 保护）：MT 滑动中有采样间歇
        // （实测 ≤87ms），若按 200ms 判陈旧，滑动中会误判抬起 → 提前退出 holding（用户核心痛点）。
        // 故 holding 时阈值放宽到 1.0s；真离开时 MT 彻底静默，1.0s 后仍会走空帧把状态机收回 idle。
        let holdingNow = Self.isHolding(runtimes)
        let staleLimit = holdingNow ? Self.holdingStaleInterval : Self.staleTouchInterval
        let stale = wallNow - touchWall > staleLimit
        let effective = stale ? [] : touches

        // 空载快速路径：无活动手指且所有启用手势都停在 idle 阶段时，跳过整图求值，
        // 仅保证鼠标没有被残留锁定。simTime 已在 pump() 里推进，frame.now 保持连续。
        if canSkipIdleEvaluation(touches: effective) {
            setClockSlowed(true)
            associateMouse()
            return
        }

        setClockSlowed(false)
        processTick(touches: effective, at: simTime, wallNow: wallNow, touchTimestamp: touchWall)
    }

    /// 是否有手势正处于 holding（phase==4）或上一帧 wasHolding
    private static func isHolding(_ runtimes: [UUID: Runtime]) -> Bool {
        runtimes.values.contains { $0.wasHolding || $0.store["phase"]?.intValue == 4 }
    }

    /// 切换空载慢速时钟（仅在 tickQueue 上调用；timer?.schedule 重排为幂等操作）。
    /// 省电目标：无新输入可处理时把定时器唤醒从 120Hz 降到 20Hz，减少每帧固定开销与唤醒次数。
    /// 触摸到达时 `onTouchFrame` 会直接 pump 并立即恢复全速，故响应延迟不受影响。
    ///
    /// deadline 用 `.now() + interval`（而非 `.now()`）：本方法是从定时器自己的 handler
    /// 里调用的，用 `.now()` 会让定时器立刻再次到期 → 多一次无效唤醒。
    private func setClockSlowed(_ slowed: Bool) {
        guard slowed != idleSlowed else { return }
        idleSlowed = slowed
        let interval = slowed ? Self.idleTickInterval : Self.tickInterval
        timer?.schedule(deadline: .now() + interval,
                        repeating: interval,
                        leeway: slowed ? .milliseconds(5) : .milliseconds(1))
    }

    /// 空载快速路径判定：没有活动手指，且所有启用手势都停在 idle 阶段。
    ///
    /// 判定只看**调用方传入的有效帧**（陈旧帧已由 tick 替换为空帧），
    /// 这样"MT 停止回调后 latestTouches 永久冻结在含活动手指的最后一帧"不会让跳帧永假。
    ///
    /// 不变量：任何待处理的「时间驱动转移」（gapTimeout 的 firstTapUp→idle、上抬 100ms 检测等）
    /// 都必然对应 phase != idle，因此 idle 时跳过整图求值不会漏掉这些转移。
    /// - Parameter touches: 调用方已完成陈旧处理后的有效帧（陈旧时为空数组）
    private func canSkipIdleEvaluation(touches: [mt_touch_t]) -> Bool {
        if touches.contains(where: { $0.state != 0 && $0.state != 7 }) { return false }
        let cfg = config
        for gesture in cfg.gestures where gesture.enabled {
            guard let rt = runtimes[gesture.id] else { continue }
            if rt.wasHolding { return false }
            if let phase = rt.store["phase"]?.intValue, phase != 0 { return false }
        }
        return true
    }

    /// 测试/诊断：空载判定被拒的归因（哪一项为 false）
    enum IdleSkipBlocker: String {
        case freshTouches = "新鲜快照里仍有活动手指"
        case wasHolding = "wasHolding"
        case phase = "phase!=0"
        case slowClock = "回到空载慢速"
        case none = "可跳过"
    }

    /// 诊断：返回当前空载判定结果与拦阻原因（供测试定位功耗回归）。
    /// 在 tickQueue 上同步读取，避免与 tick 竞争读到半更新状态。
    func idleSkipDiagnosis() -> (skipped: Bool, blocker: IdleSkipBlocker, detail: String) {
        var result: (Bool, IdleSkipBlocker, String) = (false, .none, "")
        syncOnTickQueue {
            self.touchesLock.lock()
            let touches = self.latestTouches
            let touchWall = self.lastTouchWall
            self.touchesLock.unlock()
            let wallNow = ProcessInfo.processInfo.systemUptime
            let holding = Self.isHolding(self.runtimes)
            let limit = holding ? Self.holdingStaleInterval : Self.staleTouchInterval
            let stale = wallNow - touchWall > limit
            let age = String(format: "%.3f", wallNow - touchWall)

            if !stale, touches.contains(where: { $0.state != 0 && $0.state != 7 }) {
                let states = touches.map { $0.state }
                result = (false, .freshTouches, "age=\(age) holding=\(holding) states=\(states)")
                return
            }
            for gesture in self.config.gestures where gesture.enabled {
                guard let rt = self.runtimes[gesture.id] else { continue }
                if rt.wasHolding { result = (false, .wasHolding, gesture.name); return }
                if let phase = rt.store["phase"]?.intValue, phase != 0 {
                    result = (false, .phase, "\(gesture.name) phase=\(phase)"); return
                }
            }
            result = (true, .none, "stale=\(stale) age=\(age) idleSlowed=\(self.idleSlowed)")
        }
        return (result.0, result.1, result.2)
    }

    /// 诊断：所有已建执行器手势的 phase（在 tickQueue 上同步读取，避免与 tick 竞争读到半更新状态）
    func debugPhases() -> [String: Int32] {
        var out: [String: Int32] = [:]
        let cfg = config
        syncOnTickQueue {
            for g in cfg.gestures {
                guard let rt = self.runtimes[g.id] else { continue }
                out[g.name] = rt.store["phase"]?.intValue ?? -1
            }
        }
        return out
    }

    /// 诊断：当前帧循环是否已进入空载慢速（20Hz）
    var isClockSlowed: Bool {
        var slowed = false
        syncOnTickQueue { slowed = self.idleSlowed }
        return slowed
    }

    /// 鼠标锁定：由图上 cursorLocked 变量驱动（enter 链写 1 / exit 链写 0）
    private func syncCursorLock() {
        let locked = runtimes.values.contains { $0.store["cursorLocked"]?.boolValue == true }
        if locked {
            if !mouseDisassociated {
                let event = CGEvent(source: nil)
                lockedCursorPos = event?.location ?? .zero
                CGAssociateMouseAndMouseCursorPosition(0)
                mouseDisassociated = true
            }
            CGWarpMouseCursorPosition(lockedCursorPos)
        } else if mouseDisassociated {
            CGAssociateMouseAndMouseCursorPosition(1)
            mouseDisassociated = false
        }
    }

    // MARK: - 每 tick 处理

    /// 一个固定步长的状态机执行（原 processFrame 主体；now = 模拟时钟，与回调频率无关）
    /// - Parameter touchTimestamp: 本帧所用触摸快照的墙钟时刻（与 wallNow 一起供 finger 节点判抬起）
    private func processTick(touches: [mt_touch_t], at now: Double,
                             wallNow: Double, touchTimestamp: Double) {
        holdingCount = 0
        currentHoldingGestureName = nil

        // 单次快照：整帧统一用同一份 config（避免多次 getter 之间主线程替换 config →
        // 旧快照索引越界；写入走 mutateConfig 锁内原子，见退出分支）
        let cfg = config
        for gesture in cfg.gestures where gesture.enabled {
            // 绑定从图上 RegionRef/EventRef 节点读取（旧文件回退顶层字段）
            guard let regionID = gesture.boundRegionID,
                  let eventID = gesture.boundEventID,
                  let region = cfg.regions.first(where: { $0.id == regionID }),
                  let eventIndex = cfg.events.firstIndex(where: { $0.id == eventID }) else { continue }

            // 本手势的事件引用（per-gesture，v10.20 修复：多手势同时 holding 不串台）
            let box = eventBoxes[gesture.id]
            effects.eventBox = box
            // 边界状态：holding 中读事件 trackedValue；非 holding 无 box → false/0
            let boundary = box?.value.isAtAnyBoundary() ?? false
            let boundarySide = box.map { self.boundarySide(of: $0) } ?? 0

            let frame = FrameContext(
                rawSignals: rawSignals(of: touches.first),
                now: now,
                directionRule: cfg.events[eventIndex].directionRule,
                isAtBoundary: boundary,
                boundarySide: boundarySide,
                touches: touches,
                region: region,
                touchTimestamp: touchTimestamp,
                wallNow: wallNow
            )

            var rt = runtime(for: gesture)
            rt.evaluator.evaluate(frame: frame, state: &rt.store, effects: effects, entryIDs: nil)

            // v8：holding 由图上 phase 变量驱动（状态机已展开到图，引擎只读结果）
            let holding = rt.store["phase"]?.intValue == 4
            if holding {
                // 统计当前实际 holding 的手势数（v10.20 修复：原实现只在"新进入"帧 +1，
                // 持续 holding 期间 holdingCount 恒 0 → UI 状态显示错误）
                holdingCount += 1
                if !rt.wasHolding {
                    elog("进入 holding: \(gesture.name)")
                    currentHoldingGestureName = cfg.events[eventIndex].name
                    // 建立本手势事件引用（consume 的 trackedValue 跨帧保留）
                    if eventBoxes[gesture.id] == nil {
                        var event = cfg.events[eventIndex]
                        event.resetTracking()
                        let newBox = EventBox(event)
                        eventBoxes[gesture.id] = newBox
                        effects.eventBox = newBox
                        // 进入 holding 时若当前值已在边界，发一次媒体键唤起 HUD（显示当前档位）
                        newBox.value.postBoundaryKeyOnEnterIfNeeded()
                    }
                }
            } else if rt.wasHolding {
                elog("退出 holding: \(gesture.name)")
                // 退出：trackedValue 写回配置（锁内原子：按 eventID 实时重查 index，
                // 避免与主线程 UI 编辑并发时旧快照索引越界 / 覆盖用户最新修改——"打开设置闪退"根因修复）
                if let b = eventBoxes[gesture.id] {
                    let updated = b.value
                    let eid = eventID
                    mutateConfig { c in
                        if let i = c.events.firstIndex(where: { $0.id == eid }) {
                            c.events[i] = updated
                        }
                    }
                }
                eventBoxes[gesture.id] = nil
                effects.eventBox = nil
            }
            rt.wasHolding = holding
            runtimes[gesture.id] = rt
        }

        // 鼠标锁定：由图上 cursorLocked 变量驱动（enter 链写 1 / exit 链写 0）
        syncCursorLock()
    }

    /// 当前事件值在哪个边界（-1=下边界 / 0=不在边界 / +1=上边界）
    /// 读取不可靠（trackedValue=0，getBrightness 部分机型失败）→ 0（不判定边界）
    private func boundarySide(of box: EventBox) -> Int {
        let v = box.value.trackedCurrentValue()
        guard v > 0 else { return 0 }
        if v >= 1.0 - box.value.boundaryThreshold { return 1 }
        if v <= box.value.boundaryThreshold { return -1 }
        return 0
    }

    // MARK: - 图执行运行时

    /// 取当前手势的执行器（图变化时重建）。
    ///
    /// `GraphEvaluator` 在 init 时**拷贝** timeline 并预计算入边索引
    /// （见 GraphEvaluator.swift："timeline 在 evaluator 生命周期内不可变"），
    /// 而 runtimes 按 gesture.id 缓存、只在 stop() 清理。因此用户在画布/波形页
    /// 编辑图后（改波形引用、调参数、连连线），若 id 未变会**继续执行旧图**——
    /// 表现为"界面变了但实际行为不变"（用户反馈：波形图变了但手感没变）。
    ///
    /// 修复：缓存中同时保存该执行器对应的图，用**精确相等**比较（TimelineConfig: Hashable）
    /// 判断是否需要重建。不用 hashValue 作指纹——哈希碰撞会让少数编辑静默失效，
    /// 正是本 bug 要根除的"改了没反应"。
    private func runtime(for gesture: GestureConfig) -> Runtime {
        if let rt = runtimes[gesture.id], rt.graph == gesture.timeline {
            return rt
        }
        // 图已变（用户编辑）→ 重建执行器；跨帧状态按 key 保留，
        // 避免编辑一次参数就把 baseline/transform.last 等运行态清空导致手感跳变
        let preservedStore = runtimes[gesture.id]?.store ?? StateStore()
        let wasHolding = runtimes[gesture.id]?.wasHolding ?? false
        guard let evaluator = GraphEvaluator(timeline: gesture.timeline) else {
            // 图非法（环/悬挂边）：退回空执行器，避免崩溃
            let empty = TimelineConfig(trigger: .onFirstTap)
            let ev = GraphEvaluator(timeline: empty)!
            let rt = Runtime(evaluator: ev, store: StateStore(), wasHolding: wasHolding,
                             graph: gesture.timeline)
            runtimes[gesture.id] = rt
            return rt
        }
        let rt = Runtime(evaluator: evaluator, store: preservedStore, wasHolding: wasHolding,
                         graph: gesture.timeline)
        runtimes[gesture.id] = rt
        return rt
    }

    private func rawSignals(of t: mt_touch_t?) -> [SignalSource: Float] {
        guard let t else { return [:] }
        return [.normY: t.norm_y, .normX: t.norm_x, .size: t.size, .pressure: t.zPressure,
                .velX: t.vel_x, .velY: t.vel_y]
    }

    // MARK: - 震动（同步单次 + 多次后台 + 全局节流）

    /// 触觉反馈节流状态：mt_actuate 单次很快（发指令非等待执行），同步执行时序确定；
    /// 全局 30ms 间隔合并"相同行为"——滑动每帧一次的震动请求超频时丢弃（最多 33 次/s，防触觉风暴）
    private var lastHapticTime: Double = 0
    private static let hapticInterval = 0.03

    /// 触发触觉反馈：
    /// - count <= 1：同步 mt_actuate（单次毫秒级，时序确定，不阻塞）
    /// - count > 1：后台队列按 intervalUs 间隔执行（间隔 usleep 会阻塞，必须后台）
    /// - 全局 30ms 节流：丢弃超频请求（相同行为合并），防触觉风暴
    /// - customWaveformID 非 nil 且能在配置中解析到 → 走自定义波形通路（忽略 waveform 预设 ID）
    func triggerHaptic(waveform: Int32, customWaveformID: UUID?, count: Int, intervalUs: Int32, async: Bool) {
        // 自愈：deviceID 为 0（offset 64 部分机型读 0 / IORegistry 首次时序失败）时
        // 重试一次获取——否则震动静默失效（"权限全绿但无触控板反馈"的高频根因之一）
        if deviceID == 0 {
            let retry = mt_device_get_id_by_index(0)
            if retry != 0 { deviceID = retry }
        }
        guard deviceID != 0 else {
            EngineLog.append("[ENGINE] triggerHaptic 跳过：deviceID 为 0（触觉设备不可用）")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHapticTime >= Self.hapticInterval else { return }
        lastHapticTime = now
        let dev = deviceID

        // 自定义波形：配置里解析不到（已被删除）时静默回退为预设波形，避免"删了波形就没震动"
        let spec = config.customWaveform(id: customWaveformID)?.spec

        if count <= 1 {
            Self.fireHaptic(deviceID: dev, waveform: waveform, spec: spec)
        } else {
            let wave = waveform
            let n = count
            let us = UInt32(max(0, intervalUs))
            DispatchQueue.global(qos: .userInitiated).async {
                for i in 0..<n {
                    Self.fireHaptic(deviceID: dev, waveform: wave, spec: spec)
                    if i < n - 1 && us > 0 { usleep(us) }
                }
            }
        }
    }

    /// 试听：立即播放一次波形（供「波形」页试听按钮使用）。
    /// 与 triggerHaptic 的区别：**不走 30ms 节流**——用户手动点击应即时响应。
    public func previewWaveform(_ spec: WaveformSpec, count: Int = 1) {
        if deviceID == 0 {
            let retry = mt_device_get_id_by_index(0)
            if retry != 0 { deviceID = retry }
        }
        guard deviceID != 0 else { return }
        let dev = deviceID
        let n = max(1, count)
        if n == 1 {
            Self.fireHaptic(deviceID: dev, waveform: 2, spec: spec)
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                for i in 0..<n {
                    Self.fireHaptic(deviceID: dev, waveform: 2, spec: spec)
                    if i < n - 1 { usleep(50000) }
                }
            }
        }
    }

    /// 单次触发放到静态方法：闭包不捕获 self，避免后台队列持有引擎引用
    private static func fireHaptic(deviceID: UInt64, waveform: Int32, spec: WaveformSpec?) {
        guard let spec else {
            mt_actuate(deviceID, waveform)
            return
        }
        // 字符串指针仅在 C 调用期间有效（C 侧同步消费，不保留）
        spec.envelopeType.withCString { envPtr in
            spec.toneType.rawValue.withCString { tonePtr in
                var wf = mt_waveform_t()
                wf.envelope_type = envPtr
                wf.envelope_amplitude = spec.envelopeAmplitude
                wf.envelope_duration_ms = spec.envelopeDurationMs
                wf.tone_type = tonePtr
                wf.tone_frequency_khz = spec.toneFrequencyKHz
                wf.tone_amplitude = spec.toneAmplitude
                wf.tone_duration_ms = spec.toneDurationMs
                wf.tone_delay_ms = spec.toneDelayMs
                wf.envelope_light = spec.envelopeLight
                wf.envelope_medium = spec.envelopeMedium
                wf.envelope_firm = spec.envelopeFirm
                wf.tone_light = spec.toneLight
                wf.tone_medium = spec.toneMedium
                wf.tone_firm = spec.toneFirm
                let rc = mt_actuate_custom(deviceID, wf)
                // -1 = 私有符号缺失（未来系统移除该能力）→ 回退预设波形，保证仍有震动。
                // -2 = 参数/设备问题，不回退（避免与已下发的震动叠加成双震）。
                if rc == -1 {
                    mt_actuate(deviceID, 2)
                }
            }
        }
    }

    // MARK: - 鼠标关联（供 TimelineEffects 调用）

    func disassociateMouse() {
        guard !mouseDisassociated else { return }
        let event = CGEvent(source: nil)
        lockedCursorPos = event?.location ?? .zero
        CGAssociateMouseAndMouseCursorPosition(0)
        mouseDisassociated = true
    }

    func associateMouse() {
        guard mouseDisassociated else { return }
        CGAssociateMouseAndMouseCursorPosition(1)
        mouseDisassociated = false
    }

    public func restoreMouse() { associateMouse() }
}
