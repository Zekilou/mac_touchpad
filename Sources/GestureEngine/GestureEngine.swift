import Foundation
import Darwin
import CoreGraphics
import AppKit
import mt_bridge

/// 手势引擎：管理多个手势的状态机（v3 节点化）
/// - 状态机转换参数（轻点识别）从 onFirstTap 图的 RecognizeNode 读取
/// - holding 内部流程（进入/刻度/退出）由 TimelineRuntime 按图执行
public final class GestureEngine {

    public var config: AppConfig {
        didSet { ConfigStore.save(config) }
    }
    public var deviceID: UInt64 = 0

    /// 每个手势的独立状态机，key = gesture.id
    private var states: [UUID: GestureState] = [:]

    // 鼠标关联状态
    private var mouseDisassociated = false
    private var lockedCursorPos: CGPoint = .zero

    // 帧限频
    private var lastProcessTime: Double = 0

    // Timeline 运行时：每个 holding 手势一个（key = gesture.id）
    private var runtimes: [UUID: TimelineRuntime] = [:]
    /// 当前 holding 手势的事件引用（consume 的 trackedValue 跨帧保留）
    private var eventBox: EventBox?
    /// 副作用桥接
    private let effects = EngineEffects()

    // 回调：手势状态变化时通知 UI（手势名, 状态）
    public var onStateChange: ((String, GestureState) -> Void)?

    public init() {
        config = ConfigStore.load()
        effects.engine = self
        for gesture in config.gestures {
            states[gesture.id] = .idle
        }
    }

    // MARK: - 每帧处理

    public func processFrame(touches: [mt_touch_t]) {
        let now = ProcessInfo.processInfo.systemUptime

        if config.global.frameRateLimit > 0 {
            let interval = 1.0 / config.global.frameRateLimit
            if now - lastProcessTime < interval { return }
            lastProcessTime = now
        }

        for i in 0..<config.gestures.count {
            let gesture = config.gestures[i]
            guard let region = config.regions.first(where: { $0.id == gesture.regionID }),
                  let eventIndex = config.events.firstIndex(where: { $0.id == gesture.eventID }) else { continue }
            if states[gesture.id] == nil { states[gesture.id] = .idle }
            processGesture(gesture, region: region,
                           event: &config.events[eventIndex],
                           state: &states[gesture.id]!,
                           touches: touches, now: now)
        }

        // 鼠标锁定：任意手势在 holding 即锁定
        if mouseDisassociated && isAnyHolding() {
            CGWarpMouseCursorPosition(lockedCursorPos)
        } else if mouseDisassociated && !isAnyHolding() {
            CGAssociateMouseAndMouseCursorPosition(1)
            mouseDisassociated = false
        }
    }

    // MARK: - 单手势状态机

    private func processGesture(_ gesture: GestureConfig, region: RegionConfig,
                                event: inout EventConfig,
                                state: inout GestureState, touches: [mt_touch_t], now: Double) {

        func isSizeValid(_ t: mt_touch_t) -> Bool {
            t.size >= config.global.touchSizeMin && t.size <= config.global.touchSizeMax
        }

        let edgeFinger: mt_touch_t? = touches.first { t in
            region.contains(x: t.norm_x, y: t.norm_y) && t.state != 0 && t.state != 7 && isSizeValid(t)
        }

        func fingerStillThere(_ pathIdx: Int32) -> Bool {
            touches.contains { $0.pathIndex == pathIdx && $0.state != 0 && $0.state != 7 && isSizeValid($0) }
        }

        switch state {
        case .idle:
            if let f = edgeFinger, (f.state == 1 || f.state == 3 || f.state == 4) {
                state = .firstTapDown(pathIndex: f.pathIndex, startTime: now,
                                      startPos: (f.norm_x, f.norm_y), maxDrift: 0)
                onStateChange?(gesture.name, state)
            }

        case .firstTapDown(let pathIdx, let startTime, let startPos, var maxDrift):
            if !fingerStillThere(pathIdx) {
                if maxDrift > gesture.tapMaxDrift {
                    state = .cooldown(pathIndex: pathIdx)
                } else {
                    state = .firstTapUp(pathIndex: pathIdx, endTime: now)
                }
                onStateChange?(gesture.name, state)
            } else {
                if let f = edgeFinger, f.pathIndex == pathIdx {
                    let dx = f.norm_x - startPos.0
                    let dy = f.norm_y - startPos.1
                    let drift = (dx*dx + dy*dy).squareRoot()
                    if drift > maxDrift { maxDrift = drift }
                }
                if now - startTime > gesture.tapMaxDuration || maxDrift > gesture.tapMaxDrift {
                    state = .cooldown(pathIndex: pathIdx)
                    onStateChange?(gesture.name, state)
                }
            }

        case .firstTapUp(_, let endTime):
            if now - endTime > gesture.tapMaxGap {
                state = .idle
                onStateChange?(gesture.name, state)
            } else if let f = edgeFinger, (f.state == 1 || f.state == 3 || f.state == 4) {
                state = .secondTapDown(pathIndex: f.pathIndex, startTime: now,
                                       startPos: (f.norm_x, f.norm_y), maxDrift: 0)
                onStateChange?(gesture.name, state)
            }

        case .secondTapDown(let pathIdx, let startTime, let startPos, var maxDrift):
            if !fingerStillThere(pathIdx) {
                state = .idle
                onStateChange?(gesture.name, state)
            } else {
                if let f = edgeFinger, f.pathIndex == pathIdx {
                    let dx = f.norm_x - startPos.0
                    let dy = f.norm_y - startPos.1
                    let drift = (dx*dx + dy*dy).squareRoot()
                    if drift > maxDrift { maxDrift = drift }
                }
                if maxDrift > gesture.tapMaxDrift {
                    state = .cooldown(pathIndex: pathIdx)
                    onStateChange?(gesture.name, state)
                } else if now - startTime > gesture.holdMinDuration,
                          let f = edgeFinger, f.pathIndex == pathIdx {
                    // 建立运行时 + 事件引用，执行 onEnterHolding 时间线
                    let source = gesture.tickSignalSource
                    let startRaw = source.extract(from: f)
                    event.resetTracking()
                    let startVal = event.trackedCurrentValue()
                    event.postBoundaryKeyOnEnterIfNeeded()
                    eventBox = EventBox(event)
                    effects.eventBox = eventBox
                    effects.resetFrame()
                    runtime(for: gesture).handle(.onEnterHolding,
                                                 frame: FrameContext(rawSignals: rawSignals(of: f),
                                                                     now: now,
                                                                     directionRule: event.directionRule))
                    state = .holding(pathIndex: pathIdx,
                                     startRaw: startRaw, lastTriggerVal: startRaw,
                                     ticks: 0, frozen: false, startValue: startVal)
                    onStateChange?(gesture.name, state)
                }
            }

        case .holding(let pathIdx, let startRaw, let lastTriggerVal, let ticks, let frozen, let startValue):
            if !fingerStillThere(pathIdx) {
                // 退出 → 执行 onExitHolding（解锁鼠标 + 退出震动）
                effects.resetFrame()
                runtime(for: gesture).handle(.onExitHolding, frame: FrameContext(now: now))
                if let box = eventBox { event = box.value }
                eventBox = nil
                effects.eventBox = nil
                runtimes.removeValue(forKey: gesture.id)
                state = .idle
                onStateChange?(gesture.name, state)
            } else if frozen {
                // 冻结中：检查反向滑动是否解冻
                guard let f = edgeFinger, f.pathIndex == pathIdx else { break }
                let raw = gesture.tickSignalSource.extract(from: f)
                let signalDelta = raw - lastTriggerVal
                if abs(signalDelta) >= 0.5 * gesture.tickStepNorm,
                   event.shouldUnfreeze(signalDelta: signalDelta, startValue: startValue) {
                    state = .holding(pathIndex: pathIdx,
                                     startRaw: startRaw, lastTriggerVal: raw,
                                     ticks: ticks, frozen: false, startValue: startValue)
                    onStateChange?(gesture.name, state)
                }
            } else if let f = edgeFinger, f.pathIndex == pathIdx {
                // 执行 onTick 时间线：信号→变换→量化→消费→震动/冻结 全在图上的节点决定
                effects.resetFrame()
                let boundary = eventBox?.value.isAtAnyBoundary() ?? false
                runtime(for: gesture).handle(.onTick,
                                             frame: FrameContext(rawSignals: rawSignals(of: f),
                                                                 now: now,
                                                                 directionRule: event.directionRule,
                                                                 isAtBoundary: boundary))
                let newFrozen = effects.freezeRequested
                let raw = gesture.tickSignalSource.extract(from: f)
                state = .holding(pathIndex: pathIdx,
                                 startRaw: startRaw, lastTriggerVal: raw,
                                 ticks: ticks, frozen: newFrozen, startValue: startValue)
                onStateChange?(gesture.name, state)
            }

        case .cooldown(let pathIdx):
            if !fingerStillThere(pathIdx) {
                state = .idle
                onStateChange?(gesture.name, state)
            }
        }
    }

    // MARK: - Timeline 运行时

    private func runtime(for gesture: GestureConfig) -> TimelineRuntime {
        if let r = runtimes[gesture.id] { return r }
        let r = TimelineRuntime(timelines: gesture.timelines, effects: effects)
        runtimes[gesture.id] = r
        return r
    }

    private func rawSignals(of t: mt_touch_t) -> [SignalSource: Float] {
        [.normY: t.norm_y, .normX: t.norm_x, .size: t.size, .pressure: t.zPressure]
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

    private func isAnyHolding() -> Bool {
        for (_, s) in states {
            if case .holding = s { return true }
        }
        return false
    }

    public func restoreMouse() { associateMouse() }

    /// 当前活跃的手势名（用于 UI 显示）
    public var activeGestureName: String? {
        for (id, s) in states {
            if case .holding = s,
               let g = config.gestures.first(where: { $0.id == id }) {
                return g.name
            }
        }
        return nil
    }
}

// MARK: - GestureConfig 节点图参数辅助（引擎从图提取）

extension GestureConfig {
    /// onTick 图的信号源（SignalNode.params.source）
    var tickSignalSource: SignalSource {
        timeline(for: .onTick)?.nodes.first { $0.type == .signal }?.params.source ?? .normY
    }

    /// onTick 图的量化步长（QuantizeNode.params.stepNorm）
    var tickStepNorm: Float {
        timeline(for: .onTick)?.nodes.first { $0.type == .quantize }?.params.stepNorm ?? 0.02
    }
}
