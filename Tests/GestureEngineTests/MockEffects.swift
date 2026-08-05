import Foundation
@testable import GestureEngine

/// 记录副作用调用的 Mock，供各执行引擎测试共享
final class MockEffects: TimelineEffects {
    var hapticCalls: [(waveform: Int32, count: Int, intervalUs: Int32, async: Bool)] = []
    var consumeOutputs: [GestureOutput] = []
    var hudDirections: [Int] = []
    var lockCount = 0
    var unlockCount = 0
    var freezeCount = 0
    var notifyLabels: [String] = []
    /// consume 返回值（默认 .normal）
    var consumeResult: BoundaryResult = .normal

    func triggerHaptic(waveform: Int32, count: Int, intervalUs: Int32, async: Bool) {
        hapticCalls.append((waveform, count, intervalUs, async))
    }
    func consume(_ output: GestureOutput) -> BoundaryResult {
        consumeOutputs.append(output)
        return consumeResult
    }
    func showHUD(direction: Int) { hudDirections.append(direction) }
    func lockMouse() { lockCount += 1 }
    func unlockMouse() { unlockCount += 1 }
    func freeze() { freezeCount += 1 }
    func notify(label: String) { notifyLabels.append(label) }
}
