import XCTest
import Foundation
import mt_bridge
@testable import GestureEngine

/// 功耗回归测试（v10.22）：MT 回调在手指离开后**彻底停止**，引擎 `latestTouches`
/// 于是永久冻结在最后一帧——而最后一帧常含 state=4/6 的残留触摸。
/// 若把冻结帧原样喂给图，finger 节点会认为"还有手指"，识别状态机卡在 phase 3/4/5
/// 永远回不到 0，空载跳帧判定随之永假 → **120Hz 整图求值常驻不停**。
/// 修复前实测：空载 0.5% → ~40% CPU，且不自愈（用户唯一解法是重启 app）。
///
/// 本文件覆盖：① 致命场景确实会常驻满耗（回归护栏）；
/// ② 修复后各种"最后一帧"形态都能在陈旧阈值后回到空载跳帧；
/// ③ v10.11 保护：holding 期间不因 MT 采样间歇而误判抬起。
final class IdlePowerTests: XCTestCase {

    private var tmpConfig: URL!

    override func setUpWithError() throws {
        // 隔离：所有 load/save 都落在临时副本，绝不碰用户真实 config.json
        let real = URL(fileURLWithPath: "/tmp/cfgtest/config.json")
        let src = FileManager.default.fileExists(atPath: real.path) ? real : ConfigStore.configURL
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("idle_\(UUID().uuidString).json")
        if FileManager.default.fileExists(atPath: src.path) {
            try FileManager.default.copyItem(at: src, to: tmp)
        }
        tmpConfig = tmp
        ConfigStore.overrideConfigURL = tmp
        // finger 节点的边沿状态是进程级静态量，跨 test 残留会让 up 永不再触发
        NodeExecutors.resetRuntime()
    }

    override func tearDownWithError() throws {
        ConfigStore.overrideConfigURL = nil
        try? FileManager.default.removeItem(at: tmpConfig)
    }

    // MARK: - 工具

    private func cpuTime() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
            + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    }

    private func touch(_ x: Float, _ y: Float, state: Int32, size: Float = 0.3,
                       z: Float = 0.2, path: Int32 = 1) -> mt_touch_t {
        var t = mt_touch_t()
        t.pathIndex = path
        t.state = state
        t.norm_x = x
        t.norm_y = y
        t.size = size
        t.zPressure = z
        return t
    }

    private func makeEngine() -> GestureEngine {
        let engine = GestureEngine()
        engine.config = ConfigStore.load()
        engine.start()
        Thread.sleep(forTimeInterval: 0.5)
        return engine
    }

    /// 空载 CPU 占用（百分比）。断言用宽松阈值：CI/负载下会有抖动。
    private func idleCPU(_ seconds: Double = 2.0) -> Double {
        let t0 = cpuTime()
        Thread.sleep(forTimeInterval: seconds)
        return (cpuTime() - t0) / seconds * 100
    }

    /// 一次"按下 → 移动 → 以指定帧收尾"，之后 MT 彻底静默（不再有任何 onTouchFrame）
    private func gestureThenSilence(_ engine: GestureEngine, ending: [mt_touch_t]) {
        engine.onTouchFrame(touches: [touch(0.92, 0.5, state: 3)])
        Thread.sleep(forTimeInterval: 0.04)
        for i in 0..<10 {
            engine.onTouchFrame(touches: [touch(0.92, 0.5 + Float(i) * 0.004, state: 4)])
            Thread.sleep(forTimeInterval: 0.01)
        }
        engine.onTouchFrame(touches: ending)
        // 超过陈旧阈值（200ms）后，引擎应把冻结帧当空帧
        Thread.sleep(forTimeInterval: 1.0)
    }

    // MARK: - ① 回归护栏：致命场景（冻结的活动手指帧）必须被判为"无手指"

    /// 最后一帧含活动手指（state=4），随后 MT 静默。
    /// 引擎必须在陈旧阈值后视作无手指 → 回到空载跳帧。
    func testFrozenActiveFingerFrameReturnsToIdle() {
        let engine = makeEngine()
        defer { engine.stop() }

        gestureThenSilence(engine, ending: [touch(0.92, 0.6, state: 4)])

        let d = engine.idleSkipDiagnosis()
        let pct = idleCPU()
        print("POWER 冻结 state=4 → idle \(String(format: "%.2f", pct))% skip=\(d.skipped) \(d.blocker.rawValue) [\(d.detail)]")
        XCTAssertTrue(d.skipped, "冻结的活动手指帧必须被判为无手指（否则 40% 常驻）：\(d.blocker.rawValue) \(d.detail)")
        XCTAssertLessThan(pct, 5.0, "回到空载后 CPU 必须落到低位（修复前 ~40%）")
    }

    /// 双指残留（都被 size 过滤 → present=true/touching=false）也必须回到空载。
    /// 这正是真实日志里活动簇最常见的收尾形态。
    func testFrozenTwoFingerResidueReturnsToIdle() {
        let engine = makeEngine()
        defer { engine.stop() }

        gestureThenSilence(engine, ending: [
            touch(0.92, 0.6, state: 4, size: 2.0, path: 1),
            touch(0.10, 0.6, state: 4, size: 2.0, path: 2),
        ])

        let d = engine.idleSkipDiagnosis()
        let pct = idleCPU()
        print("POWER 冻结双指残留 → idle \(String(format: "%.2f", pct))% skip=\(d.skipped) \(d.blocker.rawValue)")
        XCTAssertTrue(d.skipped, "双指残留冻结帧必须被判为无手指")
        XCTAssertLessThan(pct, 5.0, "回到空载后 CPU 必须落到低位")
    }

    /// 各类"最后一帧"形态逐一验证：全部应回到空载跳帧 + 空载慢速时钟。
    func testAllEndingShapesReturnToIdle() {
        let engine = makeEngine()
        defer { engine.stop() }

        let endings: [(String, [mt_touch_t])] = [
            ("state=6 tap", [touch(0.92, 0.5, state: 6)]),
            ("state=4 touch", [touch(0.92, 0.5, state: 4)]),
            ("state=1 start", [touch(0.92, 0.5, state: 1)]),
            ("state=7 lift", [touch(0.92, 0.5, state: 7)]),
            ("空帧", []),
        ]
        for (label, ending) in endings {
            gestureThenSilence(engine, ending: ending)
            let d = engine.idleSkipDiagnosis()
            let pct = idleCPU(1.5)
            print("POWER 收尾=\(label) → idle \(String(format: "%.2f", pct))% skip=\(d.skipped) 慢速=\(engine.isClockSlowed)")
            XCTAssertTrue(d.skipped, "收尾「\(label)」后必须回到空载跳帧（否则 120Hz 满耗）")
            XCTAssertTrue(engine.isClockSlowed, "空载时必须切到 20Hz 慢速时钟（省电）")
            XCTAssertLessThan(pct, 5.0, "收尾「\(label)」后空载 CPU 必须落到低位")
        }
    }

    // MARK: - ② 交互期不受影响：陈旧阈值回退为全速

    /// 手指仍在触控板上（持续有回调）时必须保持全速 —— 不能因为"省电"而降低响应。
    func testActiveTouchKeepsFullSpeedClock() {
        let engine = makeEngine()
        defer { engine.stop() }

        // 持续喂帧（模拟真实滑动），期间时钟不得进入慢速
        var sawSlow = false
        for i in 0..<30 {
            engine.onTouchFrame(touches: [touch(0.92, 0.4 + Float(i) * 0.01, state: 4)])
            if engine.isClockSlowed { sawSlow = true }
            Thread.sleep(forTimeInterval: 0.008)
        }
        XCTAssertFalse(sawSlow, "手指持续接触期间必须保持 120Hz 全速时钟")
    }

    /// 空载慢速期间来一帧触摸 → 必须立刻脱离慢速（不能等 1/20s 的下一拍）。
    func testTouchEscapesSlowClockPromptly() {
        let engine = makeEngine()
        defer { engine.stop() }

        // 先进入空载（静默超过陈旧阈值）
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(engine.isClockSlowed, "静默后应先进入慢速时钟")

        engine.onTouchFrame(touches: [touch(0.92, 0.5, state: 3)])
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertFalse(engine.isClockSlowed, "触摸到达后必须立刻恢复全速")
    }

    // MARK: - ③ v10.11 保护：holding 期间 MT 采样间歇不得误判抬起

    /// holding 期间 MT 出现 >200ms（但 <1s）的采样间歇时，
    /// 不得把冻结帧当空帧——否则 finger 判抬起，滑动中误退出 holding（用户核心痛点）。
    /// 实测 holding 期间回调间隔上限 ~87ms，这里用 400ms 间歇验证宽阈值生效。
    func testHoldingSurvivesSamplingGap() {
        ConfigStore.overrideConfigURL = tmpConfig
        let engine = makeEngine()
        defer { engine.stop() }

        let x: Float = 0.92
        func frame(_ t: [mt_touch_t], wait: Double = 0.012) {
            engine.onTouchFrame(touches: t)
            Thread.sleep(forTimeInterval: wait)
        }

        // 第一次轻点 → 抬起（等 100ms 让 finger 判抬起）
        frame([touch(x, 0.5, state: 3)])
        frame([touch(x, 0.5, state: 4)])
        frame([touch(x, 0.5, state: 7)])
        frame([], wait: 0.15)

        // 第二次按下并原地保持（漂移阈值避开浮点边界），累计 > 0.2s → 进入 holding
        frame([touch(x, 0.5, state: 3)])
        let deadline = Date().addingTimeInterval(0.45)
        while Date() < deadline { frame([touch(x, 0.5, state: 4)]) }
        XCTAssertGreaterThan(engine.holdingCount, 0, "双击保持应进入 holding")
        let before = engine.debugPhases()

        // 模拟 MT 采样间歇：400ms 无任何回调（>200ms 常规阈值、<1s holding 阈值）
        Thread.sleep(forTimeInterval: 0.4)
        // 手指仍在：恢复回调（同一次触摸继续）
        frame([touch(x, 0.5, state: 4)])
        let after = engine.debugPhases()
        print("POWER holding 间歇前后 phases: \(before) → \(after)")
        XCTAssertEqual(after["右侧"], 4,
                       "holding 期间 400ms 采样间歇不得被当作抬起（v10.11：会误退出 holding）")

        engine.stop()
    }
}
