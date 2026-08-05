import Foundation

// MARK: - 模块模板构建器

/// 把「平常不需要暴露内部的算法」封装成可折叠模块组（连接器节点模式，Blender Group In/Out）
///
/// 模块 = module 节点：params.moduleInputs/moduleOutputs 声明组端口（折叠后只见口子+备注），
/// subgraph 内 moduleInput/moduleOutput 连接器节点对应端口（展开后编辑内部连线）。
/// 迁移器用它把状态机拆成 2 个模板组：
/// - 「识别状态机」：轻点识别（漂移计算 + 计时 + 10 条转移链 + 6 个状态变量）→ 输出 phase/脉冲
/// - 「冻结管理」：信号增量追踪 + 边界冻结/反向解冻（lastTriggerVal/frozen/freezeDir）
/// 另提供独立「漂移检测」模板供用户自行搭建其他算法。
public enum TimelineModuleTemplates {

    // MARK: - 公共模板

    /// 识别状态机模块（识别算法内部全部封装：漂移/计时/转移链/状态变量）
    /// 输入：down/up/touching/pathIndex/normX/normY/now → 输出：phase/holdingPulse/exitPulse
    public static func stateMachine(tapMaxDuration: Double, tapMaxDrift: Float,
                                    tapMaxGap: Double, holdMinDuration: Double) -> NodeConfig {
        let g = TimelineMigrator.GraphBuilder()
        let phaseVar = TimelineMigrator.varRef(g, key: "phase", initial: TimelineMigrator.Phase.idle.rawValue, x: 120, y: 0, title: "状态")
        let pathIndexVar = TimelineMigrator.varRef(g, key: "pathIndex", initial: -1, x: 120, y: 80, title: "手指ID")
        let startTimeVar = TimelineMigrator.varRef(g, key: "startTime", initialFloat: 0, x: 120, y: 160, title: "按下时刻")
        let startPosXVar = TimelineMigrator.varRef(g, key: "startPosX", initialFloat: 0, x: 120, y: 240, title: "按下X")
        let startPosYVar = TimelineMigrator.varRef(g, key: "startPosY", initialFloat: 0, x: 120, y: 320, title: "按下Y")
        let endTimeVar = TimelineMigrator.varRef(g, key: "endTime", initialFloat: 0, x: 120, y: 400, title: "抬起时刻")

        // 输入连接器（组口子）
        let downIn = inConn(g, "down", y: 40)
        let upIn = inConn(g, "up", y: 110)
        let touchingIn = inConn(g, "touching", y: 180)
        let pathIndexIn = inConn(g, "pathIndex", y: 250)
        let normXIn = inConn(g, "normX", y: 320)
        let normYIn = inConn(g, "normY", y: 390)
        let nowIn = inConn(g, "now", y: 460)

        // 漂移计算：drift = |Δx| + |Δy| > tapMaxDrift
        let dxRaw = g.node(.arith, NodeParams(arithOp: .sub), x: 300, y: 320, title: "Δx")
        g.edge(normXIn, "value", dxRaw, "a")
        g.edge(startPosXVar, "value", dxRaw, "b")
        let dx = g.node(.abs, x: 390, y: 320, title: "|Δx|")
        g.edge(dxRaw, "result", dx, "value")
        let dyRaw = g.node(.arith, NodeParams(arithOp: .sub), x: 300, y: 390, title: "Δy")
        g.edge(normYIn, "value", dyRaw, "a")
        g.edge(startPosYVar, "value", dyRaw, "b")
        let dy = g.node(.abs, x: 390, y: 390, title: "|Δy|")
        g.edge(dyRaw, "result", dy, "value")
        let drift = g.node(.arith, NodeParams(arithOp: .add), x: 470, y: 350, title: "漂移")
        g.edge(dx, "result", drift, "a")
        g.edge(dy, "result", drift, "b")
        let driftTooBig = g.node(.compare, NodeParams(comparator: .gt, threshold: tapMaxDrift), x: 560, y: 350, title: "漂移过大?")
        g.edge(drift, "result", driftTooBig, "a")
        let notDrift = g.node(.not, x: 650, y: 350, title: "未漂移")
        g.edge(driftTooBig, "result", notDrift, "value")

        // 计时：按下时长 / 抬起间隔 / 保持时长（enterPulse 重置）
        let firstDownElapsed = g.node(.elapsed, x: 300, y: 460, title: "按下时长")
        g.edge(downIn, "value", firstDownElapsed, "trigger")
        let gapElapsed = g.node(.elapsed, x: 390, y: 460, title: "抬起间隔")
        g.edge(upIn, "value", gapElapsed, "trigger")
        let holdElapsed = g.node(.elapsed, x: 470, y: 460, title: "保持时长")
        let notTouching = g.node(.not, x: 300, y: 180, title: "手指离开")
        g.edge(touchingIn, "value", notTouching, "value")

        // 时长阈值
        let durationCmp = g.node(.compare, NodeParams(comparator: .gt, threshold: Float(tapMaxDuration)), x: 560, y: 460, title: "按下超时?")
        g.edge(firstDownElapsed, "result", durationCmp, "a")
        let gapCmp = g.node(.compare, NodeParams(comparator: .lt, threshold: Float(tapMaxGap)), x: 560, y: 520, title: "间隔内?")
        g.edge(gapElapsed, "result", gapCmp, "a")
        let gapTimeout = g.node(.compare, NodeParams(comparator: .gt, threshold: Float(tapMaxGap)), x: 560, y: 580, title: "间隔超时?")
        g.edge(gapElapsed, "result", gapTimeout, "a")
        let holdCmp = g.node(.compare, NodeParams(comparator: .gt, threshold: Float(holdMinDuration)), x: 560, y: 640, title: "保持够久?")
        g.edge(holdElapsed, "result", holdCmp, "a")

        // 10 条转移链（状态变量只留在模块内）
        TimelineMigrator.transition(g, phaseVar: phaseVar, from: .idle, to: .firstTapDown,
            extraConds: [TimelineMigrator.port(downIn, "value")],
            writes: [(pathIndexVar, TimelineMigrator.port(pathIndexIn, "value")),
                     (startTimeVar, TimelineMigrator.port(nowIn, "value")),
                     (startPosXVar, TimelineMigrator.port(normXIn, "value")),
                     (startPosYVar, TimelineMigrator.port(normYIn, "value"))],
            x: 700, y: 0, title: "首次按下")
        TimelineMigrator.transition(g, phaseVar: phaseVar, from: .firstTapDown, to: .firstTapUp,
            extraConds: [TimelineMigrator.port(upIn, "value")],
            writes: [(endTimeVar, TimelineMigrator.port(nowIn, "value"))],
            x: 700, y: 140, title: "轻点抬起")
        TimelineMigrator.transition(g, phaseVar: phaseVar, from: .firstTapDown, to: .cooldown,
            extraConds: [TimelineMigrator.port(driftTooBig, "result")],
            x: 700, y: 280, title: "滑动取消")
        TimelineMigrator.transition(g, phaseVar: phaseVar, from: .firstTapDown, to: .cooldown,
            extraConds: [TimelineMigrator.port(touchingIn, "value"), TimelineMigrator.port(durationCmp, "result")],
            x: 700, y: 420, title: "按下超时")
        let t4Pulse = TimelineMigrator.transition(g, phaseVar: phaseVar, from: .firstTapUp, to: .secondTapDown,
            extraConds: [TimelineMigrator.port(downIn, "value"), TimelineMigrator.port(gapCmp, "result")],
            writes: [(pathIndexVar, TimelineMigrator.port(pathIndexIn, "value")),
                     (startTimeVar, TimelineMigrator.port(nowIn, "value")),
                     (startPosXVar, TimelineMigrator.port(normXIn, "value")),
                     (startPosYVar, TimelineMigrator.port(normYIn, "value"))],
            x: 700, y: 560, title: "第二次按下", pulse: true)
        if let t4Pulse {
            g.edge(t4Pulse.nodeID, t4Pulse.portName, holdElapsed, "trigger")
        }
        TimelineMigrator.transition(g, phaseVar: phaseVar, from: .firstTapUp, to: .idle,
            extraConds: [TimelineMigrator.port(gapTimeout, "result")],
            x: 700, y: 700, title: "间隔超时")
        let t6Pulse = TimelineMigrator.transition(g, phaseVar: phaseVar, from: .secondTapDown, to: .holding,
            extraConds: [TimelineMigrator.port(touchingIn, "value"), TimelineMigrator.port(holdCmp, "result"),
                         TimelineMigrator.port(notDrift, "result")],
            x: 700, y: 840, title: "进入保持", pulse: true)
        TimelineMigrator.transition(g, phaseVar: phaseVar, from: .secondTapDown, to: .cooldown,
            extraConds: [TimelineMigrator.port(driftTooBig, "result")],
            x: 700, y: 980, title: "保持滑动取消")
        TimelineMigrator.transition(g, phaseVar: phaseVar, from: .secondTapDown, to: .idle,
            extraConds: [TimelineMigrator.port(upIn, "value")],
            x: 700, y: 1120, title: "取消抬起")
        let t9Pulse = TimelineMigrator.transition(g, phaseVar: phaseVar, from: .holding, to: .idle,
            extraConds: [TimelineMigrator.port(upIn, "value")],
            x: 700, y: 1260, title: "退出保持", pulse: true)
        TimelineMigrator.transition(g, phaseVar: phaseVar, from: .cooldown, to: .idle,
            extraConds: [TimelineMigrator.port(notTouching, "result")],
            x: 700, y: 1400, title: "冷却结束")

        // 输出连接器（组口子）
        let phaseOut = outConn(g, "phase", y: 0)
        g.edge(phaseVar, "value", phaseOut, "value")
        if let t6Pulse {
            let holdOut = outConn(g, "holdingPulse", y: 840)
            g.edge(t6Pulse.nodeID, t6Pulse.portName, holdOut, "value")
        }
        if let t9Pulse {
            let exitOut = outConn(g, "exitPulse", y: 1260)
            g.edge(t9Pulse.nodeID, t9Pulse.portName, exitOut, "value")
        }

        return makeModule(
            // down/up 来自 finger 节点的 bool 边沿（非 unit 脉冲）——类型必须匹配否则连线被类型校验删除
            inputs: [("down", .bool, false), ("up", .bool, false), ("touching", .bool, false),
                     ("pathIndex", .int, false), ("normX", .float, false), ("normY", .float, false),
                     ("now", .float, false)],
            outputs: [("phase", .int), ("holdingPulse", .unit), ("exitPulse", .unit)],
            note: "轻点识别状态机：按下/抬起/漂移/计时判断，输出状态与进入/退出保持脉冲",
            title: "识别状态机",
            subgraph: TimelineConfig(trigger: .onFirstTap, nodes: g.nodes, edges: g.edges,
                                     entryNodeIDs: g.entryCandidates))
    }

    /// 冻结管理模块（信号增量追踪 + 边界冻结/反向解冻）
    /// 输入：signal/enterPulse/boundaryPulse/holding/touching → 输出：frozen
    public static func freeze(stepNorm: Float) -> NodeConfig {
        let g = TimelineMigrator.GraphBuilder()
        let lastTriggerVar = TimelineMigrator.varRef(g, key: "lastTriggerVal", initialFloat: 0, x: 120, y: 0, title: "上次触发")
        let startRawVar = TimelineMigrator.varRef(g, key: "startRaw", initialFloat: 0, x: 120, y: 80, title: "起始信号")
        let frozenVar = TimelineMigrator.varRef(g, key: "frozen", initialBool: false, x: 120, y: 160, title: "冻结")
        let freezeDirVar = TimelineMigrator.varRef(g, key: "freezeDir", initialFloat: 0, x: 120, y: 240, title: "冻结方向")

        let signalIn = inConn(g, "signal", y: 20)
        let enterIn = inConn(g, "enterPulse", y: 90)
        let boundaryIn = inConn(g, "boundaryPulse", y: 160)
        let holdingIn = inConn(g, "holding", y: 230)
        let touchingIn = inConn(g, "touching", y: 300)
        let trueConst = TimelineMigrator.makeBool(g, true, x: 300, y: 160, title: "真")
        let falseConst = TimelineMigrator.makeBool(g, false, x: 300, y: 380, title: "假")

        // delta = signal - lastTriggerVal
        let delta = g.node(.arith, NodeParams(arithOp: .sub), x: 300, y: 20, title: "信号增量")
        g.edge(signalIn, "value", delta, "a")
        g.edge(lastTriggerVar, "value", delta, "b")
        // 进入保持：重置 startRaw + lastTriggerVal = signal（独立写链，同源配对）
        let enRaw = g.node(.branch, x: 420, y: 80, title: "写起始信号")
        g.edge(enterIn, "value", enRaw, "cond")
        g.edge(signalIn, "value", enRaw, "value")
        let enRawOut = TimelineMigrator.port(enRaw, "out1")
        g.edge(enRawOut.nodeID, enRawOut.portName, startRawVar, "trigger")
        g.edge(enRawOut.nodeID, enRawOut.portName, startRawVar, "value")
        let enLast = g.node(.branch, x: 420, y: 140, title: "写触发点")
        g.edge(enterIn, "value", enLast, "cond")
        g.edge(signalIn, "value", enLast, "value")
        let enLastOut = TimelineMigrator.port(enLast, "out1")
        g.edge(enLastOut.nodeID, enLastOut.portName, lastTriggerVar, "trigger")
        g.edge(enLastOut.nodeID, enLastOut.portName, lastTriggerVar, "value")
        // 到达边界：frozen=true + freezeDir=sign(delta)
        let signNode = g.node(.sign, x: 420, y: 20, title: "冻结方向")
        g.edge(delta, "result", signNode, "value")
        let fzWrite = g.node(.branch, x: 420, y: 200, title: "写冻结")
        g.edge(boundaryIn, "value", fzWrite, "cond")
        g.edge(trueConst, "value", fzWrite, "value")
        let fzOut = TimelineMigrator.port(fzWrite, "out1")
        g.edge(fzOut.nodeID, fzOut.portName, frozenVar, "trigger")
        g.edge(fzOut.nodeID, fzOut.portName, frozenVar, "value")
        let fdWrite = g.node(.branch, x: 420, y: 260, title: "写冻结方向")
        g.edge(boundaryIn, "value", fdWrite, "cond")
        g.edge(signNode, "result", fdWrite, "value")
        let fdOut = TimelineMigrator.port(fdWrite, "out1")
        g.edge(fdOut.nodeID, fdOut.portName, freezeDirVar, "trigger")
        g.edge(fdOut.nodeID, fdOut.portName, freezeDirVar, "value")
        // 反向滑动解冻：Δ×dir<0 且 |Δ|≥0.5×stepNorm
        let mul = g.node(.arith, NodeParams(arithOp: .mul), x: 300, y: 320, title: "方向积")
        g.edge(delta, "result", mul, "a")
        g.edge(freezeDirVar, "value", mul, "b")
        let dirCheck = g.node(.compare, NodeParams(comparator: .lt, threshold: 0), x: 390, y: 320, title: "反向?")
        g.edge(mul, "result", dirCheck, "a")
        let absDelta = g.node(.abs, x: 300, y: 400, title: "|Δ|")
        g.edge(delta, "result", absDelta, "value")
        let magCheck = g.node(.compare, NodeParams(comparator: .gte, threshold: 0.5 * stepNorm), x: 390, y: 400, title: "幅度够?")
        g.edge(absDelta, "result", magCheck, "a")
        let notFrozen = g.node(.not, x: 300, y: 480, title: "未冻结")
        g.edge(frozenVar, "value", notFrozen, "value")
        let unfreeze = TimelineMigrator.andChain(g,
            conds: [TimelineMigrator.port(holdingIn, "value"),
                    TimelineMigrator.port(frozenVar, "value"),
                    TimelineMigrator.port(touchingIn, "value"),
                    TimelineMigrator.port(dirCheck, "result"),
                    TimelineMigrator.port(magCheck, "result")],
            x: 300, y: 540)
        let ufWrite = g.node(.branch, x: 480, y: 540, title: "写解冻")
        g.edge(unfreeze.nodeID, unfreeze.portName, ufWrite, "cond")
        g.edge(falseConst, "value", ufWrite, "value")
        let ufOut = TimelineMigrator.port(ufWrite, "out1")
        g.edge(ufOut.nodeID, ufOut.portName, frozenVar, "trigger")
        g.edge(ufOut.nodeID, ufOut.portName, frozenVar, "value")
        let luWrite = g.node(.branch, x: 480, y: 620, title: "写触发点")
        g.edge(unfreeze.nodeID, unfreeze.portName, luWrite, "cond")
        g.edge(signalIn, "value", luWrite, "value")
        let luOut = TimelineMigrator.port(luWrite, "out1")
        g.edge(luOut.nodeID, luOut.portName, lastTriggerVar, "trigger")
        g.edge(luOut.nodeID, luOut.portName, lastTriggerVar, "value")

        let frozenOut = outConn(g, "frozen", y: 160)
        g.edge(frozenVar, "value", frozenOut, "value")

        return makeModule(
            inputs: [("signal", .float, false), ("enterPulse", .unit, false),
                     ("boundaryPulse", .unit, true),   // 写类：内部驱动 frozen/freezeDir 写请求（帧末延迟注入）
                     ("holding", .bool, false), ("touching", .bool, false)],
            outputs: [("frozen", .bool)],
            note: "信号增量追踪 + 边界冻结/反向滑动解冻（lastTriggerVal/frozen/freezeDir 管理）",
            title: "冻结管理",
            subgraph: TimelineConfig(trigger: .onFirstTap, nodes: g.nodes, edges: g.edges,
                                     entryNodeIDs: g.entryCandidates))
    }

    /// Force 按压保持识别模块：区域内手指 + 压力 >= 阈值持续 holdMinDuration → holding（holdingPulse）；
    /// 退出（exitPulse）：压力不足（任何位置，原始压力判定）或 滑出区域持续 0.1s（时间基准，容忍 touching 闪断）。
    /// 全程需保持压力 + 留在区域内才能滑动。
    /// 输入：pressure（**原始 zP，任何位置手指**——T4 压力退出必须任何位置都可靠）/ touching（区域内手指）/ now
    /// 输出：phase/holdingPulse/exitPulse
    public static func forcePress(pressureThreshold: Float, holdMinDuration: Double) -> NodeConfig {
        let g = TimelineMigrator.GraphBuilder()
        let phaseVar = TimelineMigrator.varRef(g, key: "phase", initial: TimelineMigrator.Phase.idle.rawValue,
                                               x: 120, y: 0, title: "状态")
        let pressStartVar = TimelineMigrator.varRef(g, key: "pressStart", initialFloat: 0,
                                                    x: 120, y: 80, title: "按压时刻")
        let prevHighVar = TimelineMigrator.varRef(g, key: "prevHigh", initialBool: false,
                                                  x: 120, y: 160, title: "上次高压")
        // 区域内手指最后一次出现时刻（T5 区域离开退出用：!touching 持续 0.1s 才算滑出区域）
        let lastTouchVar = TimelineMigrator.varRef(g, key: "lastTouchTime", initialFloat: 0,
                                                   x: 120, y: 260, title: "上次在区域")

        let pressureIn = inConn(g, "pressure", y: 40)
        let touchingIn = inConn(g, "touching", y: 110)
        let nowIn = inConn(g, "now", y: 180)

        // 压力是否足够（zPressure >= 阈值；原始压力，任何位置手指）
        let high = g.node(.compare, NodeParams(comparator: .gte, threshold: pressureThreshold), x: 300, y: 40, title: "压力足够?")
        g.edge(pressureIn, "value", high, "a")
        let notHigh = g.node(.not, x: 380, y: 40, title: "压力不足")
        g.edge(high, "result", notHigh, "value")
        // 退出阈值（迟滞 hysteresis：低于 进入阈值-0.3 才退出——按住时力度波动不会反复进出 holding）
        let low = g.node(.compare, NodeParams(comparator: .lt, threshold: pressureThreshold - 0.3),
                         x: 300, y: 480, title: "压力不足?")
        g.edge(pressureIn, "value", low, "a")
        let notPrevHigh = g.node(.not, x: 300, y: 160, title: "非上次高压")
        g.edge(prevHighVar, "value", notPrevHigh, "value")
        // 已按时长 = now - pressStart（pressStart 由"高压上升沿"记录；prevHigh 兜底防未记录时误判）
        let held = g.node(.arith, NodeParams(arithOp: .sub), x: 300, y: 240, title: "已按时长")
        g.edge(nowIn, "value", held, "a")
        g.edge(pressStartVar, "value", held, "b")
        let heldCmp = g.node(.compare, NodeParams(comparator: .gt, threshold: Float(holdMinDuration)),
                             x: 380, y: 240, title: "按够久?")
        g.edge(held, "result", heldCmp, "a")

        // 区域离开检测：touching（区域内手指存在）时每帧写 lastTouchTime=now；
        // !touching 时 lastTouchTime 冻结 → 离开时长 = now - lastTouchTime 增长 → 超 0.1s 判定滑出区域
        let touchWrite = g.node(.branch, x: 300, y: 330, title: "更新在区域时刻")
        g.edge(touchingIn, "value", touchWrite, "cond")
        g.edge(nowIn, "value", touchWrite, "value")
        let touchOut = TimelineMigrator.port(touchWrite, "out1")
        g.edge(touchOut.nodeID, touchOut.portName, lastTouchVar, "trigger")
        g.edge(touchOut.nodeID, touchOut.portName, lastTouchVar, "value")
        let notTouching = g.node(.not, x: 300, y: 410, title: "不在区域")
        g.edge(touchingIn, "value", notTouching, "value")
        let leaveDur = g.node(.arith, NodeParams(arithOp: .sub), x: 380, y: 410, title: "离开时长")
        g.edge(nowIn, "value", leaveDur, "a")
        g.edge(lastTouchVar, "value", leaveDur, "b")
        let leaveCmp = g.node(.compare, NodeParams(comparator: .gt, threshold: 0.1), x: 460, y: 410, title: "离开够久?")
        g.edge(leaveDur, "result", leaveCmp, "a")

        let trueConst = TimelineMigrator.makeBool(g, true, x: 420, y: 80, title: "真")
        let falseConst = TimelineMigrator.makeBool(g, false, x: 420, y: 160, title: "假")

        // T1: idle && 区域内手指 && 高压上升沿（high 且上次非高压）→ 记按压时刻 + prevHigh=true
        // 区域约束（touching）：手指必须在绑定区域内（且尺寸有效）才记录按压——否则整个触控板任意位置重按都会触发
        TimelineMigrator.transition(g, phaseVar: phaseVar, from: .idle, to: .idle,
            extraConds: [TimelineMigrator.port(high, "result"), TimelineMigrator.port(notPrevHigh, "result"),
                         TimelineMigrator.port(touchingIn, "value")],
            writes: [(pressStartVar, TimelineMigrator.port(nowIn, "value")),
                     (prevHighVar, TimelineMigrator.port(trueConst, "value"))],
            x: 500, y: 40, title: "按压开始")
        // T2: idle && 压力释放沿（非高压且上次高压）→ prevHigh=false
        TimelineMigrator.transition(g, phaseVar: phaseVar, from: .idle, to: .idle,
            extraConds: [TimelineMigrator.port(notHigh, "result"), TimelineMigrator.port(prevHighVar, "value")],
            writes: [(prevHighVar, TimelineMigrator.port(falseConst, "value"))],
            x: 500, y: 160, title: "压力释放")
        // T3: idle && 区域内手指 && 高压持续够久（prevHigh 兜底：pressStart 已记录）→ holding
        let t3Pulse = TimelineMigrator.transition(g, phaseVar: phaseVar, from: .idle, to: .holding,
            extraConds: [TimelineMigrator.port(high, "result"), TimelineMigrator.port(prevHighVar, "value"),
                         TimelineMigrator.port(heldCmp, "result"), TimelineMigrator.port(touchingIn, "value")],
            x: 500, y: 280, title: "进入保持", pulse: true)
        // T4: holding && 压力低于退出阈值（滞回：低于 进入阈值-0.3，任何位置）→ idle
        // （手指离开时 pressure 必为 0 → 同一路径退出；按住力度波动（1.2±0.1）不会反复进出）
        let t4Pulse = TimelineMigrator.transition(g, phaseVar: phaseVar, from: .holding, to: .idle,
            extraConds: [TimelineMigrator.port(low, "result")],
            x: 500, y: 400, title: "压力不足退出", pulse: true)
        // T5: holding && 不在区域 && 离开超时（0.1s 去抖，容忍滑动中 touching 闪断）→ idle
        let t5Pulse = TimelineMigrator.transition(g, phaseVar: phaseVar, from: .holding, to: .idle,
            extraConds: [TimelineMigrator.port(notTouching, "result"), TimelineMigrator.port(leaveCmp, "result")],
            x: 500, y: 520, title: "滑出区域退出", pulse: true)

        // 输出连接器（T4 压力退出 + T5 区域退出 共用 exitPulse——不同时触发，同端口多入边取首个有效）
        let phaseOut = outConn(g, "phase", y: 0)
        g.edge(phaseVar, "value", phaseOut, "value")
        if let t3Pulse {
            let holdOut = outConn(g, "holdingPulse", y: 280)
            g.edge(t3Pulse.nodeID, t3Pulse.portName, holdOut, "value")
        }
        let exitOut = outConn(g, "exitPulse", y: 400)
        if let t4Pulse {
            g.edge(t4Pulse.nodeID, t4Pulse.portName, exitOut, "value")
        }
        if let t5Pulse {
            g.edge(t5Pulse.nodeID, t5Pulse.portName, exitOut, "value")
        }

        return makeModule(
            inputs: [("pressure", .float, false), ("touching", .bool, false), ("now", .float, false)],
            outputs: [("phase", .int), ("holdingPulse", .unit), ("exitPulse", .unit)],
            note: "Force 按压保持：区域内+压力≥阈值持续 holdMinDuration 进入调节；压力不足或滑出区域即退出（全程保持压力才能滑动）",
            title: "Force按压识别",
            subgraph: TimelineConfig(trigger: .onFirstTap, nodes: g.nodes, edges: g.edges,
                                     entryNodeIDs: g.entryCandidates))
    }

    /// 独立漂移检测模板（可复用：Δx/Δy 距离 → 是否超阈值）
    public static func drift(tapMaxDrift: Float) -> NodeConfig {
        let g = TimelineMigrator.GraphBuilder()
        let normXIn = inConn(g, "normX", y: 0)
        let normYIn = inConn(g, "normY", y: 70)
        let startXIn = inConn(g, "startPosX", y: 140)
        let startYIn = inConn(g, "startPosY", y: 210)
        let dxRaw = g.node(.arith, NodeParams(arithOp: .sub), x: 200, y: 0, title: "Δx")
        g.edge(normXIn, "value", dxRaw, "a")
        g.edge(startXIn, "value", dxRaw, "b")
        let dx = g.node(.abs, x: 290, y: 0, title: "|Δx|")
        g.edge(dxRaw, "result", dx, "value")
        let dyRaw = g.node(.arith, NodeParams(arithOp: .sub), x: 200, y: 70, title: "Δy")
        g.edge(normYIn, "value", dyRaw, "a")
        g.edge(startYIn, "value", dyRaw, "b")
        let dy = g.node(.abs, x: 290, y: 70, title: "|Δy|")
        g.edge(dyRaw, "result", dy, "value")
        let driftSum = g.node(.arith, NodeParams(arithOp: .add), x: 380, y: 30, title: "漂移")
        g.edge(dx, "result", driftSum, "a")
        g.edge(dy, "result", driftSum, "b")
        let tooBig = g.node(.compare, NodeParams(comparator: .gt, threshold: tapMaxDrift), x: 470, y: 30, title: "漂移过大?")
        g.edge(driftSum, "result", tooBig, "a")
        let driftOut = outConn(g, "drift", y: 30)
        g.edge(driftSum, "result", driftOut, "value")
        let tooBigOut = outConn(g, "tooBig", y: 100)
        g.edge(tooBig, "result", tooBigOut, "value")

        return makeModule(
            inputs: [("normX", .float, false), ("normY", .float, false),
                     ("startPosX", .float, false), ("startPosY", .float, false)],
            outputs: [("drift", .float), ("tooBig", .bool)],
            note: "漂移检测：|Δx|+|Δy| 超过阈值输出 tooBig",
            title: "漂移检测",
            subgraph: TimelineConfig(trigger: .onFirstTap, nodes: g.nodes, edges: g.edges,
                                     entryNodeIDs: g.entryCandidates))
    }

    // MARK: - 内部辅助

    /// 组装模块节点：端口声明 + 备注 + 子图（inputs 三元组 = 名称/类型/是否写类端口）
    private static func makeModule(inputs: [(String, SocketType, Bool)], outputs: [(String, SocketType)],
                                   note: String, title: String, subgraph: TimelineConfig) -> NodeConfig {
        NodeConfig(type: .module,
                   params: NodeParams(moduleInputs: inputs.map { ModulePort(name: $0.0, type: $0.1, isWrite: $0.2) },
                                      moduleOutputs: outputs.map { ModulePort(name: $0.0, type: $0.1) },
                                      note: note),
                   x: 0, y: 0, title: title, subgraph: subgraph)
    }

    /// 子图输入连接器：组输入口子（输出注入值）
    @discardableResult
    private static func inConn(_ g: TimelineMigrator.GraphBuilder, _ name: String, y: Double) -> UUID {
        g.node(.moduleInput, NodeParams(modulePortName: name), x: 0, y: y, title: name, isEntry: true)
    }

    /// 子图输出连接器：组输出口子（收集内部值）
    @discardableResult
    private static func outConn(_ g: TimelineMigrator.GraphBuilder, _ name: String, y: Double) -> UUID {
        g.node(.moduleOutput, NodeParams(modulePortName: name), x: 1000, y: y, title: name, isEntry: true)
    }
}
