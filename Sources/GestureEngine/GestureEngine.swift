import Foundation
import Darwin
import CoreGraphics
import AppKit
import mt_bridge

/// 手势动作类型
public enum GestureAction: String, Codable, CaseIterable {
    case volume = "音量"
    case brightness = "亮度"
}

/// 单侧边缘的手势状态机
public enum GestureState {
    case idle
    case firstTapDown(pathIndex: Int32, startTime: Double, startPos: (Float, Float), maxDrift: Float)
    case firstTapUp(pathIndex: Int32, endTime: Double)
    case secondTapDown(pathIndex: Int32, startTime: Double, startPos: (Float, Float), maxDrift: Float)
    case holding(pathIndex: Int32, startY: Float, lastTickY: Float, ticks: Int, frozen: Bool, startValue: Float)
    case cooldown(pathIndex: Int32)
}

/// 手势引擎：管理左右两个边缘的状态机
public final class GestureEngine {

    public var config: GestureConfig {
        didSet { config.save() }
    }
    public var deviceID: UInt64 = 0

    // 左右各自独立的状态机
    private var leftState: GestureState = .idle
    private var rightState: GestureState = .idle

    // 鼠标关联状态
    private var mouseDisassociated = false
    /// 进入 holding 时锁定的光标位置，每帧 warp 回此点
    private var lockedCursorPos: CGPoint = .zero

    // 帧限频
    private var lastProcessTime: Double = 0

    // 回调：手势状态变化时通知 UI
    public var onStateChange: ((GestureAction?, GestureState) -> Void)?

    public init() {
        config = GestureConfig.load()
    }

    // MARK: - 每帧处理

    public func processFrame(touches: [mt_touch_t]) {
        let now = ProcessInfo.processInfo.systemUptime

        // 帧限频：0 = 不限频
        if config.frameRateLimit > 0 {
            let interval = 1.0 / config.frameRateLimit
            if now - lastProcessTime < interval {
                return
            }
            lastProcessTime = now
        }

        // 分别处理左右边缘
        processEdge(.right, state: &rightState, touches: touches, now: now)
        processEdge(.left, state: &leftState, touches: touches, now: now)

        // 鼠标锁定：holding 期间每帧把光标 warp 回原位
        if mouseDisassociated && isAnyHolding() {
            CGWarpMouseCursorPosition(lockedCursorPos)
        } else if mouseDisassociated && !isAnyHolding() {
            // 离开 holding，恢复关联
            CGAssociateMouseAndMouseCursorPosition(1)
            mouseDisassociated = false
        }
    }

    private enum EdgeSide {
        case left, right
    }

    private func edgeThreshold(_ side: EdgeSide) -> Float {
        side == .right ? config.edgeRightThreshold : config.edgeLeftThreshold
    }

    private func isInEdge(_ side: EdgeSide, x: Float) -> Bool {
        side == .right ? x > config.edgeRightThreshold : x < config.edgeLeftThreshold
    }

    private func action(_ side: EdgeSide) -> GestureAction {
        side == .right ? .volume : .brightness
    }

    /// 面积过滤：接触面积在 [touchSizeMin, touchSizeMax] 范围内才算有效手指
    private func isSizeValid(_ t: mt_touch_t) -> Bool {
        t.size >= config.touchSizeMin && t.size <= config.touchSizeMax
    }

    private func processEdge(_ side: EdgeSide, state: inout GestureState, touches: [mt_touch_t], now: Double) {

        // 找到该边缘的有效手指（边缘区域 + 活跃状态 + 面积过滤）
        let edgeFinger: mt_touch_t? = touches.first { t in
            isInEdge(side, x: t.norm_x) && t.state != 0 && t.state != 7 && isSizeValid(t)
        }

        func fingerStillThere(_ pathIdx: Int32) -> Bool {
            touches.contains { $0.pathIndex == pathIdx && $0.state != 0 && $0.state != 7 && isSizeValid($0) }
        }

        switch state {
        case .idle:
            if let f = edgeFinger, (f.state == 1 || f.state == 3 || f.state == 4) {
                state = .firstTapDown(
                    pathIndex: f.pathIndex, startTime: now,
                    startPos: (f.norm_x, f.norm_y), maxDrift: 0)
                onStateChange?(action(side), state)
            }

        case .firstTapDown(let pathIdx, let startTime, let startPos, var maxDrift):
            if !fingerStillThere(pathIdx) {
                if maxDrift > config.tapMaxDrift {
                    state = .cooldown(pathIndex: pathIdx)
                } else {
                    state = .firstTapUp(pathIndex: pathIdx, endTime: now)
                }
                onStateChange?(action(side), state)
            } else {
                if let f = edgeFinger, f.pathIndex == pathIdx {
                    let dx = f.norm_x - startPos.0
                    let dy = f.norm_y - startPos.1
                    let drift = (dx*dx + dy*dy).squareRoot()
                    if drift > maxDrift { maxDrift = drift }
                }
                if now - startTime > config.tapMaxDuration || maxDrift > config.tapMaxDrift {
                    state = .cooldown(pathIndex: pathIdx)
                    onStateChange?(action(side), state)
                }
            }

        case .firstTapUp(_, let endTime):
            if now - endTime > config.tapMaxGap {
                state = .idle
                onStateChange?(action(side), state)
            } else if let f = edgeFinger,
                      (f.state == 1 || f.state == 3 || f.state == 4) {
                state = .secondTapDown(
                    pathIndex: f.pathIndex, startTime: now,
                    startPos: (f.norm_x, f.norm_y), maxDrift: 0)
                onStateChange?(action(side), state)
            }

        case .secondTapDown(let pathIdx, let startTime, let startPos, var maxDrift):
            if !fingerStillThere(pathIdx) {
                state = .idle
                onStateChange?(action(side), state)
            } else {
                if let f = edgeFinger, f.pathIndex == pathIdx {
                    let dx = f.norm_x - startPos.0
                    let dy = f.norm_y - startPos.1
                    let drift = (dx*dx + dy*dy).squareRoot()
                    if drift > maxDrift { maxDrift = drift }
                }
                if maxDrift > config.tapMaxDrift {
                    state = .cooldown(pathIndex: pathIdx)
                    onStateChange?(action(side), state)
                } else if now - startTime > config.holdMinDuration {
                    let startY = edgeFinger?.norm_y ?? startPos.1
                    let startVal = side == .right
                        ? SystemControl.getVolume()
                        : SystemControl.getBrightness()
                    // 进入 holding 时如果在边界，立即发送朝边界外的媒体键唤起 HUD（值不变）
                    // 让用户立刻看到当前值的 HUD 指示框，知道已在边界
                    if startVal >= 1.0 - config.boundaryThreshold {
                        switch action(side) {
                        case .volume: SystemControl.volumeUp()
                        case .brightness: SystemControl.brightnessUp()
                        }
                    } else if startVal <= config.boundaryThreshold {
                        switch action(side) {
                        case .volume: SystemControl.volumeDown()
                        case .brightness: SystemControl.brightnessDown()
                        }
                    }
                    state = .holding(pathIndex: pathIdx, startY: startY, lastTickY: startY, ticks: 0, frozen: false, startValue: startVal)
                    // 进入 holding：震动 + 解除鼠标关联
                    if deviceID != 0 { mt_actuate(deviceID, config.hapticEnter) }
                    if config.disassociateMouse { disassociateMouse() }
                    onStateChange?(action(side), state)
                }
            }

        case .holding(let pathIdx, let startY, let lastTickY, let ticks, let frozen, let startValue):
            if !fingerStillThere(pathIdx) {
                associateMouse()
                state = .idle
                onStateChange?(action(side), state)
            } else if frozen {
                break
            } else if let f = edgeFinger, f.pathIndex == pathIdx {
                let dy = f.norm_y - lastTickY
                let stepNorm = side == .right ? config.volumeStepNorm : config.brightnessStepNorm
                if abs(dy) >= stepNorm {
                    let direction: Int = dy > 0 ? 1 : -1  // norm_y 增大=下滑=增大

                    // 边界检测：读取当前实际值判断（不依赖固定档位数）
                    // startValue > boundaryThreshold 表示 API 可靠，可以检测边界
                    let canDetect = startValue > config.boundaryThreshold
                    var atBoundary = false
                    if canDetect {
                        let currentValue = side == .right
                            ? SystemControl.getVolume()
                            : SystemControl.getBrightness()
                        if direction < 0 && currentValue <= config.boundaryThreshold {
                            atBoundary = true
                        } else if direction > 0 && currentValue >= 1.0 - config.boundaryThreshold {
                            atBoundary = true
                        }
                    }

                    if atBoundary {
                        // 判断进入 holding 时是否已在边界
                        // 若已在边界，HUD 已在进入时唤起，此处不再发送媒体键
                        // 若进入时不在边界（滑动过程中才到达边界），发送媒体键唤起 HUD
                        let enterAtBoundary = startValue >= 1.0 - config.boundaryThreshold
                            || startValue <= config.boundaryThreshold
                        if !enterAtBoundary {
                            switch action(side) {
                            case .volume:
                                if direction > 0 { SystemControl.volumeUp() }
                                else { SystemControl.volumeDown() }
                            case .brightness:
                                if direction > 0 { SystemControl.brightnessUp() }
                                else { SystemControl.brightnessDown() }
                            }
                        }
                        // 到边界：强震动 + 冻结
                        if deviceID != 0 {
                            mt_actuate(deviceID, config.hapticBoundary)
                            usleep(useconds_t(config.boundaryHapticInterval))
                            mt_actuate(deviceID, config.hapticBoundary)
                        }
                        state = .holding(
                            pathIndex: pathIdx, startY: startY,
                            lastTickY: f.norm_y, ticks: ticks, frozen: true, startValue: startValue)
                    } else {
                        // 正常调节
                        switch action(side) {
                        case .volume:
                            if direction > 0 { SystemControl.volumeUp() }
                            else { SystemControl.volumeDown() }
                        case .brightness:
                            if direction > 0 { SystemControl.brightnessUp() }
                            else { SystemControl.brightnessDown() }
                        }
                        if deviceID != 0 { mt_actuate(deviceID, config.hapticTick) }
                        state = .holding(
                            pathIndex: pathIdx, startY: startY,
                            lastTickY: f.norm_y, ticks: ticks, frozen: false, startValue: startValue)
                    }
                    onStateChange?(action(side), state)
                }
            }

        case .cooldown(let pathIdx):
            if !fingerStillThere(pathIdx) {
                state = .idle
                onStateChange?(action(side), state)
            }
        }
    }

    // MARK: - 鼠标关联

    private func disassociateMouse() {
        guard !mouseDisassociated else { return }
        // 记录当前光标位置作为锁定点
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
        if case .holding = rightState { return true }
        if case .holding = leftState { return true }
        return false
    }

    /// 恢复鼠标关联（退出时调用）
    public func restoreMouse() {
        associateMouse()
    }

    /// 当前活跃的手势动作（用于 UI 显示）
    public var activeAction: GestureAction? {
        if case .holding = rightState { return .volume }
        if case .holding = leftState { return .brightness }
        return nil
    }
}
