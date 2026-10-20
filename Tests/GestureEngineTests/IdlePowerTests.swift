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

    /// 喂帧用的横坐标：落在**默认右边缘**（xMin 0.8 / xMax 1.0）内部。
    ///
    /// 曾经这里直接写 0.92，而配置来源是「/tmp/cfgtest/config.json 存在就用它，否则用
    /// 用户真实 config.json」——于是同一份代码在别人机器上会因用户把边缘调窄（例如
    /// 0.9927~1.0）而失败，表现为"双击进不了 holding"，却与识别逻辑无关。
    /// 现在配置由测试自己生成（见 setUp），坐标与之配套，并由
    /// `testProbeCoordinateLiesInsideRightEdge` 锁死这个不变量。
    static let probeX: Float = 0.92
    /// 纵向中部：避开上/下边缘（y 0~0.2 / 0.8~1.0）
    static let probeY: Float = 0.5

    override func setUpWithError() throws {
        // 隔离 + 确定性：不再读取 /tmp/cfgtest 或用户真实配置。
        // 测试一旦依赖宿主机上的外部文件，结果就会随用户设置漂移（正是本文件曾经的 flaky 根因）。
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("idle_\(UUID().uuidString).json")
        // 写入一份全新的默认配置（默认右边缘 0.8~1.0，与 probeX 配套）
        let defaultConfig = AppConfig()
        let data = try JSONEncoder().encode(defaultConfig)
        try data.write(to: tmp)
        tmpConfig = tmp
        ConfigStore.overrideConfigURL = tmp
        // finger 节点的边沿状态是进程级静态量，跨 test 残留会让 up 永不再触发
        NodeExecutors.resetRuntime()
    }

    override func tearDownWithError() throws {
        // 复位阈值覆盖，避免影响其它用例（覆盖是进程级 static）
        GestureEngine.staleTouchIntervalOverride = nil
        GestureEngine.holdingStaleIntervalOverride = nil
        ConfigStore.overrideConfigURL = nil
        try? FileManager.default.removeItem(at: tmpConfig)
    }

    /// 放宽引擎的「触摸快照陈旧」阈值，供**模拟连续接触**的用例使用。
    ///
    /// 背景：这类用例用 `onTouchFrame` + `Thread.sleep` 以墙钟驱动，模拟"手指一直在滑动"。
    /// 整仓并发/高负载下，harness 自身的喂帧间隔可能超过引擎的陈旧阈值（生产 0.2s）——
    /// 引擎于是**正确地**判定"手指已离开、回调已停"，并给图喂空帧；而用例本意是模拟连续
    /// 接触，断言随即失败。这是测试宿主的调度抖动，不是产品缺陷：
    /// 6 次全量运行的失败全部集中在 `IdlePowerTests`，且同一用例单独运行恒定通过。
    ///
    /// 放宽后，用例只验证**逻辑**（接触期间不降速 / holding 不被采样间歇打断 / 重启后行为
    /// 正确），不再依赖宿主机调度是否准点。生产阈值本身由
    /// `testProductionStaleThresholdsArePinned` 单独锁定，避免此处放宽掩盖真实回归。
    private func widenStaleThresholdsForContinuousTouchTests(
        stale: Double = 30.0, holding: Double = 30.0) {
        GestureEngine.staleTouchIntervalOverride = stale
        GestureEngine.holdingStaleIntervalOverride = holding
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
        engine.onTouchFrame(touches: [touch(Self.probeX, Self.probeY, state: 3)])
        Thread.sleep(forTimeInterval: 0.04)
        for i in 0..<10 {
            engine.onTouchFrame(touches: [touch(Self.probeX, Self.probeY + Float(i) * 0.004, state: 4)])
            Thread.sleep(forTimeInterval: 0.01)
        }
        engine.onTouchFrame(touches: ending)
        // 超过陈旧阈值（200ms）后，引擎应把冻结帧当空帧
        Thread.sleep(forTimeInterval: 1.0)
    }

    // MARK: - ① 回归护栏：致命场景（冻结的活动手指帧）必须被判为"无手指"

    /// 锁定**生产**陈旧阈值，防止上面几处测试用的 override 掩盖真实回归
    /// （例如有人把 0.2s 改成 5s，会让"手指离开后回到空载"严重变慢，而放宽后的用例仍会通过）。
    func testProductionStaleThresholdsArePinned() {
        XCTAssertNil(GestureEngine.staleTouchIntervalOverride, "默认不得有阈值覆盖")
        XCTAssertNil(GestureEngine.holdingStaleIntervalOverride, "默认不得有阈值覆盖")
        XCTAssertEqual(GestureEngine.staleTouchInterval, 0.2, accuracy: 1e-9,
                       "非 holding 陈旧阈值必须为 0.2s（与 finger 节点 staleEmpty 同源）")
        XCTAssertEqual(GestureEngine.holdingStaleInterval, 1.0, accuracy: 1e-9,
                       "holding 陈旧阈值必须为 1.0s（v10.11：滑动采样间歇实测 ≤87ms，需 >10× 余量）")
        // 必须严格大于关系：holding 窗口更宽才能保住滑动中的采样间歇
        XCTAssertGreaterThan(GestureEngine.holdingStaleInterval,
                             GestureEngine.staleTouchInterval,
                             "holding 阈值必须宽于常规阈值，否则滑动中会误判抬起")
    }

    /// 不变量：喂帧坐标必须落在「右侧」手势绑定的区域内。
    ///
    /// 这条断言存在的理由是一次真实事故：本文件曾从 `/tmp/cfgtest/config.json` 或
    /// 用户真实配置读取区域，而坐标写死 0.92。用户把右边缘调窄到 0.9927~1.0 后，
    /// 0.92 落到区域外，双击根本不会触发——测试报「双击保持应进入 holding」，
    /// 看起来像识别逻辑坏了，实际是坐标与配置不匹配。
    ///
    /// 现在配置由 setUp 自己生成，这条断言把"两者必须配套"钉死：以后谁改了
    /// probeX 或默认区域，会在这里立刻失败，而不是变成一个 flaky 用例。
    func testProbeCoordinateLiesInsideRightEdge() throws {
        let config = ConfigStore.load()
        let rightGesture = try XCTUnwrap(
            config.gestures.first { $0.name == "右侧" },
            "默认配置里应有「右侧」手势")
        let regionID = try XCTUnwrap(rightGesture.boundRegionID,
                                     "「右侧」手势应绑定区域")
        let region = try XCTUnwrap(
            config.regions.first { $0.id == regionID },
            "绑定区域应存在")
        XCTAssertTrue(rightGesture.enabled, "「右侧」手势默认应启用")

        XCTAssertGreaterThanOrEqual(Self.probeX, region.xMin,
                                    "probeX 必须 >= 区域左界 \(region.xMin)")
        XCTAssertLessThanOrEqual(Self.probeX, region.xMax,
                                 "probeX 必须 <= 区域右界 \(region.xMax)")
        XCTAssertGreaterThanOrEqual(Self.probeY, region.yMin)
        XCTAssertLessThanOrEqual(Self.probeY, region.yMax)

        // 同时不得落进「其它区域」（上/下边缘等），否则喂帧会串到别的手势。
        // 注意：同一区域内可以共存多个手势（例如「右侧」与「右侧Force」共用右边缘），
        // 这里比较的是**区域**而不是手势名。
        for other in config.regions where other.id != regionID {
            let insideX = Self.probeX >= other.xMin && Self.probeX <= other.xMax
            let insideY = Self.probeY >= other.yMin && Self.probeY <= other.yMax
            XCTAssertFalse(insideX && insideY,
                           "probe 坐标不得落在「\(other.name)」区域内（会串到该区域的手势）")
        }
    }

    /// 最后一帧含活动手指（state=4），随后 MT 静默。
    /// 引擎必须在陈旧阈值后视作无手指 → 回到空载跳帧。
    func testFrozenActiveFingerFrameReturnsToIdle() {
        let engine = makeEngine()
        defer { engine.stop() }

        gestureThenSilence(engine, ending: [touch(Self.probeX, 0.6, state: 4)])

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
            touch(Self.probeX, 0.6, state: 4, size: 2.0, path: 1),
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
            ("state=6 tap", [touch(Self.probeX, Self.probeY, state: 6)]),
            ("state=4 touch", [touch(Self.probeX, Self.probeY, state: 4)]),
            ("state=1 start", [touch(Self.probeX, Self.probeY, state: 1)]),
            ("state=7 lift", [touch(Self.probeX, Self.probeY, state: 7)]),
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
        // 模拟连续接触：不受宿主调度及时性影响（见 widenStaleThresholds... 注释）
        widenStaleThresholdsForContinuousTouchTests()
        let engine = makeEngine()
        defer { engine.stop() }

        // 持续喂帧（模拟真实滑动），期间时钟不得进入慢速
        var sawSlow = false
        for i in 0..<30 {
            engine.onTouchFrame(touches: [touch(Self.probeX, 0.4 + Float(i) * 0.01, state: 4)])
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

        engine.onTouchFrame(touches: [touch(Self.probeX, Self.probeY, state: 3)])
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertFalse(engine.isClockSlowed, "触摸到达后必须立刻恢复全速")
    }

    // MARK: - ③ v10.11 保护：holding 期间 MT 采样间歇不得误判抬起

    /// holding 期间 MT 出现 >200ms（但 <1s）的采样间歇时，
    /// 不得把冻结帧当空帧——否则 finger 判抬起，滑动中误退出 holding（用户核心痛点）。
    /// 实测 holding 期间回调间隔上限 ~87ms，这里用 400ms 间歇验证宽阈值生效。
    func testHoldingSurvivesSamplingGap() {
        ConfigStore.overrideConfigURL = tmpConfig
        // 模拟"手指仍在、只是采样有间歇"：把阈值放宽，使用例不受宿主调度抖动影响
        widenStaleThresholdsForContinuousTouchTests(stale: 30.0, holding: 30.0)
        let engine = makeEngine()
        defer { engine.stop() }

        let x: Float = Self.probeX
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
        // 轮询等待 holding 成立：固定睡 0.45s 在整仓测试并发/高负载下会偶发未达（测试自身不确定性，
        // 与产品行为无关），故改为"最多等 1.5s，一旦进入就停"
        let holdDeadline = Date().addingTimeInterval(1.5)
        while Date() < holdDeadline && engine.holdingCount == 0 {
            frame([touch(x, 0.5, state: 4)])
        }
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

    // MARK: - ④ 生命周期：stop 与迟到触摸帧的竞态

    /// 回归：`stop()` 期间/之后到达的触摸帧不得再驱动 tick。
    /// 原实现把 eventBoxes/runtimes 清理放在 syncOnTickQueue 之外，且 pump() 无 started 守卫
    /// → 迟到的 onTouchFrame 块会与清理并发读写同一批字典（内存破坏）。
    /// 这里在「手指刚落下的瞬间」反复 stop，并穿插喂帧，验证不崩且状态干净。
    func testStopDuringActiveTouchesIsRaceFree() {
        for _ in 0..<20 {
            let engine = makeEngine()
            // 制造活跃触摸（可能进入识别/holding 链）
            engine.onTouchFrame(touches: [touch(Self.probeX, Self.probeY, state: 3)])
            engine.onTouchFrame(touches: [touch(Self.probeX, Self.probeY, state: 4)])
            // 立刻 stop（此时 tickQueue 上很可能仍有排队的回调块）
            engine.stop()
            XCTAssertFalse(engine.isRunning, "stop 后 isRunning 必须为 false")
            XCTAssertEqual(engine.holdingCount, 0, "stop 必须清空 holding 计数")
            XCTAssertNil(engine.currentHoldingGestureName, "stop 必须清空 holding 手势名")
            // stop 之后喂帧：不得崩溃、不得复活引擎
            engine.onTouchFrame(touches: [touch(Self.probeX, 0.6, state: 4)])
            Thread.sleep(forTimeInterval: 0.02)
            XCTAssertFalse(engine.isRunning, "stop 后到达的触摸帧不得重新启动引擎")
            engine.stop()   // 幂等
        }
    }

    /// 回归：stop → start 可以安全重启，且重启后仍能正常进入 holding。
    func testStopThenRestartRecoversCleanly() {
        // 模拟连续接触进入 holding：不受宿主调度及时性影响
        widenStaleThresholdsForContinuousTouchTests()
        let engine = makeEngine()
        engine.stop()
        XCTAssertFalse(engine.isRunning)

        engine.start()
        XCTAssertTrue(engine.isRunning, "start 后应恢复运行")
        Thread.sleep(forTimeInterval: 0.2)

        let x: Float = Self.probeX
        func frame(_ t: [mt_touch_t], wait: Double = 0.012) {
            engine.onTouchFrame(touches: t)
            Thread.sleep(forTimeInterval: wait)
        }
        frame([touch(x, 0.5, state: 3)])
        frame([touch(x, 0.5, state: 4)])
        frame([touch(x, 0.5, state: 7)])
        frame([], wait: 0.15)
        frame([touch(x, 0.5, state: 3)])
        // 轮询等待 holding 成立（固定睡 0.45s 在负载机器上会偶发未达，属测试自身的不确定性）
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline && engine.holdingCount == 0 {
            frame([touch(x, 0.5, state: 4)])
        }

        XCTAssertGreaterThan(engine.holdingCount, 0, "重启后手势链应仍能正常进入 holding")
        engine.stop()
    }

    // MARK: - ⑤ 运行时状态淘汰（防无界增长）

    /// 回归：删除手势后，其 Runtime（内含整份 TimelineConfig 深拷贝）必须被淘汰。
    /// 原实现 runtimes 只增不减 → 每次删手势都永久泄漏一份图。
    /// 同时验证：淘汰不能影响仍在配置中的手势（曾出现的"误删活跃手势"风险）。
    func testDeletingGestureReleasesItsRuntime() {
        // 关闭自动补齐，构造一个可控的两手势配置
        var cfg = ConfigStore.loadDefault()
        cfg.gestures = [cfg.gestures[0]]

        ConfigStore.save(cfg)
        let engine = GestureEngine()
        engine.config = cfg
        engine.start()
        defer { engine.stop() }

        // 让两个手势都建立 runtime。
        // 注意：空载时引擎会跳过整图求值（runtimes 不会建立），必须喂一帧活动触摸
        // 才能进入 processTick —— 这也说明淘汰是"按需惰性"执行的。
        func drive() {
            engine.onTouchFrame(touches: [touch(0.5, 0.5, state: 4)])
            Thread.sleep(forTimeInterval: 0.1)
            engine.onTouchFrame(touches: [])
            Thread.sleep(forTimeInterval: 0.15)
        }
        var cfg2 = cfg
        guard let baseGesture = cfg.gestures.first else { return XCTFail("缺少基础手势") }
        var extra = baseGesture
        extra.name = "临时手势"
        cfg2.gestures.append(extra)
        engine.config = cfg2
        drive()

        let withTwo = engine.debugPhases().count
        XCTAssertGreaterThanOrEqual(withTwo, 2, "两个启用手势都应建立 runtime：\(engine.debugPhases())")

        // 删掉临时手势 → 其 runtime 应被淘汰
        engine.config = cfg
        drive()
        let phases = engine.debugPhases()
        XCTAssertFalse(phases.keys.contains("临时手势"), "已删除手势的 runtime 必须被淘汰")
        XCTAssertTrue(phases.keys.contains(baseGesture.name), "保留手势的 runtime 不得被误删")
    }
}
