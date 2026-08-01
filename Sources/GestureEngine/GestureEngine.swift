import Foundation
import Darwin
import CoreGraphics
import AppKit
import mt_bridge

/// 手势引擎：管理多个手势的状态机（字典版，v2 全配置化管线）
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

    // 回调：手势状态变化时通知 UI（手势名, 状态）
    public var onStateChange: ((String, GestureState) -> Void)?

    public init() {
        config = ConfigStore.load()
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

        // 遍历所有手势
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

        // 在该区域内 + 活跃 + 面积合格的手指
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
                } else if now - startTime > gesture.holdMinDuration {
                    let startRaw = gesture.signalSource.extract(from: edgeFinger ?? touches.first!)
                    // 重置追踪值，用追踪值获取起始系统值（避免 getBrightness 不准）
                    event.resetTracking()
                    let startVal = event.trackedCurrentValue()
                    // 进入 holding 时若事件在边界，发送朝边界外的媒体键唤起 HUD
                    event.postBoundaryKeyOnEnterIfNeeded()
                    state = .holding(pathIndex: pathIdx,
                                     startRaw: startRaw, lastTriggerVal: startRaw,
                                     ticks: 0, frozen: false, startValue: startVal)
                    triggerHaptic(gesture.hapticEnter)
                    if gesture.disassociateMouse { disassociateMouse() }
                    onStateChange?(gesture.name, state)
                }
            }

        case .holding(let pathIdx, let startRaw, let lastTriggerVal, let ticks, let frozen, let startValue):
            if !fingerStillThere(pathIdx) {
                // 退出 → 触发 hapticExit
                triggerHaptic(gesture.hapticExit)
                associateMouse()
                state = .idle
                onStateChange?(gesture.name, state)
            } else if frozen {
                // 冻结中：检查反向滑动是否解冻
                guard let f = edgeFinger, f.pathIndex == pathIdx else { break }
                let raw = gesture.signalSource.extract(from: f)
                let signalDelta: Float
                switch gesture.transformMode {
                case .delta:    signalDelta = raw - lastTriggerVal
                case .absolute: signalDelta = raw - startRaw
                }
                if abs(signalDelta) >= 0.5 * gesture.stepNorm,  // 至少动半个 step 才算有意图
                   event.shouldUnfreeze(signalDelta: signalDelta, startValue: startValue) {
                    state = .holding(pathIndex: pathIdx,
                                     startRaw: startRaw, lastTriggerVal: raw,
                                     ticks: ticks, frozen: false, startValue: startValue)
                    onStateChange?(gesture.name, state)
                }
            } else if let f = edgeFinger, f.pathIndex == pathIdx {
                // --- 阶段1 + 2：提取信号 + 变换 ---
                let raw = gesture.signalSource.extract(from: f)
                let delta: Float
                switch gesture.transformMode {
                case .delta:
                    delta = raw - lastTriggerVal
                case .absolute:
                    // absolute 模式：delta = 当前信号原始值（0~1 映射）
                    delta = raw
                }

                // --- 阶段3：量化 → GestureOutput ---
                guard let output = quantize(
                    delta: delta,
                    triggerMode: gesture.triggerMode,
                    stepNorm: gesture.stepNorm,
                    sensitivity: gesture.sensitivity,
                    mapDirection: { event.directionRule.mapSignalDirection($0) }
                ) else {
                    break // 不满足触发条件
                }

                // --- 阶段5：事件消费（内部处理边界/冻结/HUD/调节）---
                let result = event.consume(output: output)

                // --- 阶段6：基于结果触发震动 ---
                switch result {
                case .normal:
                    triggerHaptic(gesture.hapticTick)
                case .hitBoundary:
                    triggerHaptic(gesture.hapticBoundary)
                case .frozen:
                    break // 不动也不震
                }

                // --- 更新状态：lastTriggerVal 根据 triggerMode 推进 ---
                let newLastTrigger: Float
                var newTicks = ticks
                switch output {
                case .tick(_, let count):
                    // discrete 模式：按 count 个 stepNorm 推进（多档补偿），避免余值累积丢刻度
                    let sign: Float = (delta >= 0) ? 1.0 : -1.0
                    newLastTrigger = lastTriggerVal + sign * Float(count) * gesture.stepNorm
                    newTicks = ticks + count
                case .continuous:
                    newLastTrigger = raw
                }

                let newFrozen = (result == .hitBoundary) || (result == .frozen)
                state = .holding(pathIndex: pathIdx,
                                 startRaw: startRaw, lastTriggerVal: newLastTrigger,
                                 ticks: newTicks, frozen: newFrozen, startValue: startValue)
                onStateChange?(gesture.name, state)
            }

        case .cooldown(let pathIdx):
            if !fingerStillThere(pathIdx) {
                state = .idle
                onStateChange?(gesture.name, state)
            }
        }
    }

    // MARK: - 震动（非阻塞，多次震动用 async 后台）

    /// 触发单个 HapticEvent 配置的震动
    /// - 单个震动：直接调用 mt_actuate（同步，~ms 级）
    /// - 多个震动：后台线程 async 执行，避免阻塞帧回调
    private func triggerHaptic(_ h: HapticEvent) {
        guard h.enabled, deviceID != 0 else { return }
        let dev = deviceID
        if h.count <= 1 {
            mt_actuate(dev, Int32(h.waveform))
        } else {
            let wave = Int32(h.waveform)
            let n = h.count
            let us = UInt32(h.intervalUs)
            DispatchQueue.global(qos: .userInitiated).async {
                for i in 0..<n {
                    mt_actuate(dev, wave)
                    if i < n - 1 && us > 0 {
                        usleep(us)
                    }
                }
            }
        }
    }

    // MARK: - 鼠标关联

    private func disassociateMouse() {
        guard !mouseDisassociated else { return }
        let event = CGEvent(source: nil)
        lockedCursorPos = event?.location ?? .zero
        CGAssociateMouseAndMouseCursorPosition(0)
        mouseDisassociated = true
    }

    private func associateMouse() {
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
