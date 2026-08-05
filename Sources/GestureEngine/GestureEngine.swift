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
    public var config: AppConfig {
        get { _config }
        set { _config = newValue; ConfigStore.save(newValue) }
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
    /// 临时（v10.16）：强制开启 finger/transform/quantize 诊断日志——校准 Force 压力阈值
    /// （finger 日志输出真实 zPressure 读数）。校准完成后改回 false。
    public static var forceDebugLogging = true

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
        guard Self.diagnosticMinimalTick else { return }
        fputs("[ENGINE] \(msg)\n", stderr)
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
    private static let tickInterval = 1.0 / 120.0
    /// 防追赶螺旋：一次间隔超过该值（挂起/休眠/长停顿）直接丢弃，不补跑（Godot 同样忽略超长 delta）
    private static let maxAccum = 0.25

    /// 启动固定步长帧循环（mt_start_touch 之后调用）
    public func start() {
        guard !started else { return }
        started = true
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
        restoreMouse()
    }

    /// MT 回调入口（任意线程）：只更新最新触摸快照 + 记录快照时刻，不驱动逻辑。
    /// 之后补一次泵，让状态机对触摸的响应延迟 ≤ 一个 tick（8ms）
    public func onTouchFrame(touches: [mt_touch_t]) {
        touchesLock.lock()
        latestTouches = touches
        touchesLock.unlock()
        lastTouchWall = ProcessInfo.processInfo.systemUptime
        tickQueue.async { [weak self] in self?.pump() }
    }

    /// 时间累积器：把墙钟增量折算成固定步长 tick（Godot MainTimerSync::advance_core 模式）
    private func pump() {
        let wall = ProcessInfo.processInfo.systemUptime
        if lastWall == 0 {
            lastWall = wall
            return
        }
        let delta = min(wall - lastWall, Self.maxAccum)
        lastWall = wall
        tickAccum += delta
        while tickAccum >= Self.tickInterval {
            tickAccum -= Self.tickInterval
            simTime += Self.tickInterval
            tick()
        }
    }

    /// 固定步长逻辑执行（读取最新快照）
    private func tick() {
        touchesLock.lock()
        let touches = latestTouches
        touchesLock.unlock()
        processTick(touches: touches, at: simTime, wallNow: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: - 每 tick 处理

    /// 一个固定步长的状态机执行（原 processFrame 主体；now = 模拟时钟，与回调频率无关）
    private func processTick(touches: [mt_touch_t], at now: Double, wallNow: Double) {
        holdingCount = 0
        currentHoldingGestureName = nil

        for gesture in config.gestures where gesture.enabled {
            // 绑定从图上 RegionRef/EventRef 节点读取（旧文件回退顶层字段）
            guard let regionID = gesture.boundRegionID,
                  let eventID = gesture.boundEventID,
                  let region = config.regions.first(where: { $0.id == regionID }),
                  let eventIndex = config.events.firstIndex(where: { $0.id == eventID }) else { continue }

            // 本手势的事件引用（per-gesture，v10.20 修复：多手势同时 holding 不串台）
            let box = eventBoxes[gesture.id]
            effects.eventBox = box
            // 边界状态：holding 中读事件 trackedValue；非 holding 无 box → false/0
            let boundary = box?.value.isAtAnyBoundary() ?? false
            let boundarySide = box.map { self.boundarySide(of: $0) } ?? 0

            let frame = FrameContext(
                rawSignals: rawSignals(of: touches.first),
                now: now,
                directionRule: config.events[eventIndex].directionRule,
                isAtBoundary: boundary,
                boundarySide: boundarySide,
                touches: touches,
                region: region,
                touchTimestamp: lastTouchWall,
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
                    currentHoldingGestureName = config.events[eventIndex].name
                    // 建立本手势事件引用（consume 的 trackedValue 跨帧保留）
                    if eventBoxes[gesture.id] == nil {
                        var event = config.events[eventIndex]
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
                // 退出：trackedValue 写回配置
                if let b = eventBoxes[gesture.id] {
                    config.events[eventIndex] = b.value
                }
                eventBoxes[gesture.id] = nil
                effects.eventBox = nil
            }
            rt.wasHolding = holding
            runtimes[gesture.id] = rt
        }

        // 鼠标锁定：由图上 cursorLocked 变量驱动（enter 链写 1 / exit 链写 0）
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

    private func runtime(for gesture: GestureConfig) -> Runtime {
        if let rt = runtimes[gesture.id] {
            return rt
        }
        guard let evaluator = GraphEvaluator(timeline: gesture.timeline) else {
            // 图非法（环/悬挂边）：退回空执行器，避免崩溃
            let empty = TimelineConfig(trigger: .onFirstTap)
            let ev = GraphEvaluator(timeline: empty)!
            let rt = Runtime(evaluator: ev, store: StateStore())
            runtimes[gesture.id] = rt
            return rt
        }
        let rt = Runtime(evaluator: evaluator, store: StateStore())
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
    func triggerHaptic(waveform: Int32, count: Int, intervalUs: Int32, async: Bool) {
        guard deviceID != 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHapticTime >= Self.hapticInterval else { return }
        lastHapticTime = now
        let dev = deviceID
        if count <= 1 {
            mt_actuate(dev, waveform)
        } else {
            let wave = waveform
            let n = count
            let us = UInt32(max(0, intervalUs))
            DispatchQueue.global(qos: .userInitiated).async {
                for i in 0..<n {
                    mt_actuate(dev, wave)
                    if i < n - 1 && us > 0 { usleep(us) }
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
