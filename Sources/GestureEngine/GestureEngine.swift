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

    public var config: AppConfig {
        didSet { ConfigStore.save(config) }
    }
    public var deviceID: UInt64 = 0

    // 鼠标关联状态
    private var mouseDisassociated = false
    private var lockedCursorPos: CGPoint = .zero

    // 帧限频
    private var lastProcessTime: Double = 0

    // 副作用桥接
    private let effects = EngineEffects()

    /// 每手势的执行器 + 跨帧状态（key = gesture.id）
    private var runtimes: [UUID: (evaluator: GraphEvaluator, store: StateStore)] = [:]
    /// 当前有手势在 holding（识别器报告）
    private(set) var holdingCount = 0
    /// 当前 holding 的手势名（UI 显示）
    public private(set) var currentHoldingGestureName: String?
    /// 当前处理手势的事件引用（识别器 holding 进出时创建/写回）
    private var eventBox: EventBox?
    private var currentEventIndex: Int?

    public init() {
        config = ConfigStore.load()
        effects.engine = self
    }

    // MARK: - 每帧处理

    public func processFrame(touches: [mt_touch_t]) {
        let now = ProcessInfo.processInfo.systemUptime

        if config.global.frameRateLimit > 0 {
            let interval = 1.0 / config.global.frameRateLimit
            if now - lastProcessTime < interval { return }
            lastProcessTime = now
        }

        holdingCount = 0
        currentHoldingGestureName = nil

        for gesture in config.gestures {
            // 绑定从图上 RegionRef/EventRef 节点读取（旧文件回退顶层字段）
            guard let regionID = gesture.boundRegionID,
                  let eventID = gesture.boundEventID,
                  let region = config.regions.first(where: { $0.id == regionID }),
                  let eventIndex = config.events.firstIndex(where: { $0.id == eventID }) else { continue }

            currentEventIndex = eventIndex
            // 边界状态：holding 中读事件 trackedValue；非 holding 无 eventBox → false
            let boundary = eventBox?.value.isAtAnyBoundary() ?? false

            let frame = FrameContext(
                rawSignals: rawSignals(of: touches.first),
                now: now,
                directionRule: config.events[eventIndex].directionRule,
                isAtBoundary: boundary,
                touches: touches,
                region: region
            )

            var rt = runtime(for: gesture)
            rt.evaluator.evaluate(frame: frame, state: &rt.store, effects: effects, entryIDs: nil)
        }

        // 鼠标锁定：由图上 cursorLocked 变量驱动（enter 链 set=1 / exit 链 set=0）
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

    // MARK: - 识别器 holding 状态桥接（EngineEffects → 引擎）

    func recognizerState(holding: Bool) {
        if holding {
            holdingCount += 1
            currentHoldingGestureName = currentGestureName
            // 建立事件引用（consume 的 trackedValue 跨帧保留）
            if eventBox == nil, let index = currentEventIndex {
                var event = config.events[index]
                event.resetTracking()
                let box = EventBox(event)
                eventBox = box
                effects.eventBox = box
            }
        } else {
            holdingCount = max(0, holdingCount - 1)
            // 退出：trackedValue 写回配置
            if let box = eventBox, let index = currentEventIndex {
                config.events[index] = box.value
            }
            eventBox = nil
            effects.eventBox = nil
        }
    }

    private var currentGestureName: String? {
        guard let index = currentEventIndex else { return nil }
        return config.events[index].name
    }

    // MARK: - 图执行运行时

    private func runtime(for gesture: GestureConfig) -> (evaluator: GraphEvaluator, store: StateStore) {
        if let rt = runtimes[gesture.id] { return rt }
        guard let evaluator = GraphEvaluator(timeline: gesture.timeline) else {
            // 图非法（环/悬挂边）：退回空执行器，避免崩溃
            let empty = TimelineConfig(trigger: .onFirstTap)
            let ev = GraphEvaluator(timeline: empty)!
            let rt = (ev, StateStore())
            runtimes[gesture.id] = rt
            return rt
        }
        let rt = (evaluator, StateStore())
        runtimes[gesture.id] = rt
        return rt
    }

    private func rawSignals(of t: mt_touch_t?) -> [SignalSource: Float] {
        guard let t else { return [:] }
        return [.normY: t.norm_y, .normX: t.norm_x, .size: t.size, .pressure: t.zPressure,
                .velX: t.vel_x, .velY: t.vel_y]
    }

    // MARK: - 震动（非阻塞，供 TimelineEffects 调用）

    /// 触发触觉反馈：单个直接调用，多次后台异步执行避免阻塞帧回调
    func triggerHaptic(waveform: Int32, count: Int, intervalUs: Int32, async: Bool) {
        guard deviceID != 0 else { return }
        let dev = deviceID
        if count <= 1 {
            mt_actuate(dev, waveform)
        } else {
            let wave = waveform
            let n = count
            let us = UInt32(max(0, intervalUs))
            let queue = async ? DispatchQueue.global(qos: .userInitiated) : DispatchQueue.global()
            queue.async {
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
