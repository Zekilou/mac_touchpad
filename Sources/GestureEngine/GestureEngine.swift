import Foundation
import Darwin
import CoreGraphics
import AppKit
import mt_bridge

/// 手势引擎：管理多个手势的状态机（字典版，v2）
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
        for gesture in config.gestures {
            guard let region = config.regions.first(where: { $0.id == gesture.regionID }),
                  let event = config.events.first(where: { $0.id == gesture.eventID }) else { continue }
            if states[gesture.id] == nil { states[gesture.id] = .idle }
            processGesture(gesture, region: region, event: event,
                           state: &states[gesture.id]!, touches: touches, now: now)
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

    private func processGesture(_ gesture: GestureConfig, region: RegionConfig, event: EventConfig,
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
                    let startY = edgeFinger?.norm_y ?? startPos.1
                    let startVal = event.currentValue()
                    // 进入 holding 时若事件在边界，发送朝边界外的媒体键唤起 HUD
                    if event.isAtAnyBoundary() {
                        event.postBoundaryKey()
                    }
                    state = .holding(pathIndex: pathIdx, startY: startY, lastTickY: startY,
                                     ticks: 0, frozen: false, startValue: startVal)
                    if deviceID != 0 { mt_actuate(deviceID, gesture.hapticEnter) }
                    if gesture.disassociateMouse { disassociateMouse() }
                    onStateChange?(gesture.name, state)
                }
            }

        case .holding(let pathIdx, let startY, let lastTickY, let ticks, let frozen, let startValue):
            if !fingerStillThere(pathIdx) {
                associateMouse()
                state = .idle
                onStateChange?(gesture.name, state)
            } else if frozen {
                break
            } else if let f = edgeFinger, f.pathIndex == pathIdx {
                let dy = f.norm_y - lastTickY
                if abs(dy) >= gesture.slideStepNorm {
                    let direction: Int = dy > 0 ? 1 : -1  // norm_y 增大=下滑=增大

                    // canDetect: 进入时不在边界，API 可靠
                    let canDetect = startValue > event.boundaryThreshold
                        && startValue < 1.0 - event.boundaryThreshold
                    var atBoundary = false
                    if canDetect {
                        atBoundary = event.isAtBoundary(direction: direction)
                    }

                    if atBoundary {
                        // 滑动过程中到达边界，发媒体键唤起 HUD（值不变）
                        event.perform(direction: direction)
                        // 强震动 + 冻结
                        if deviceID != 0 {
                            mt_actuate(deviceID, gesture.hapticBoundary)
                            usleep(useconds_t(gesture.boundaryHapticInterval))
                            mt_actuate(deviceID, gesture.hapticBoundary)
                        }
                        state = .holding(pathIndex: pathIdx, startY: startY,
                                         lastTickY: f.norm_y, ticks: ticks,
                                         frozen: true, startValue: startValue)
                    } else {
                        // 正常调节
                        event.perform(direction: direction)
                        if deviceID != 0 { mt_actuate(deviceID, gesture.hapticTick) }
                        state = .holding(pathIndex: pathIdx, startY: startY,
                                         lastTickY: f.norm_y, ticks: ticks + 1,
                                         frozen: false, startValue: startValue)
                    }
                    onStateChange?(gesture.name, state)
                }
            }

        case .cooldown(let pathIdx):
            if !fingerStillThere(pathIdx) {
                state = .idle
                onStateChange?(gesture.name, state)
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
