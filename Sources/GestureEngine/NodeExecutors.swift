import Foundation
import mt_bridge

// MARK: - 节点执行器（数据流：输入 socket 值 → 输出 socket 值，副作用经 effects 派发）

/// 按 NodeType 分发执行逻辑（v6 数据流语义）。
/// - 端口名与 NodeTypeDef 注册表一致（如数学类 value→result、quantize value→tick）
/// - **valid 传播**：任一必需输入 invalid → 输出全 .invalid()（显式，下游可见）
/// - 副作用节点（consume/haptic/...）仅在输入有效时执行，执行后输出 result = unit（事件脉冲）
/// - branch = 路由器：cond 决定把 value 路由到 out1/out2，未选中路输出 invalid
public enum NodeExecutors {

    /// 诊断日志开关（GestureEngine 诊断模式开启；stderr + /tmp/touchpad_run.log，实证数据流断点）
    public static var debugLogging = false
    private static func log(_ msg: String) {
        #if DEBUG
        DiagnosticsLog.log(msg)   // 可插拔诊断：环形缓冲（导出诊断包用）
        #endif
        guard debugLogging else { return }
        EngineLog.append("[ENGINE] \(msg)")
    }

    /// 执行单个节点
    /// - Parameters:
    ///   - node: 节点配置（type + params）
    ///   - inputs: 入边收集到的端口值（key = to.portName；含 invalid，表示上游已显式传播）
    ///   - frame: 当前帧上下文
    ///   - state: 跨节点共享状态（baseline/transform.last/debounce.last/state 节点读写）
    ///   - effects: 副作用派发
    ///   - writePass: 模块帧末延迟重跑（注入写类输入端口，抑制副作用，只收集写请求）
    public static func execute(node: NodeConfig,
                               inputs: [String: SocketValue],
                               frame: FrameContext,
                               state: inout StateStore,
                               effects: TimelineEffects,
                               writePass: Bool = false) -> NodeExecutionResult {
        let p = node.params

        switch node.type {
        // MARK: 管道出口（收到有效 unit 脉冲 → 透传启动下游链）

        case .pipeOut:
            guard required(inputs, "trigger") != nil else { return invalidOutputs(node) }
            return output(node, .unit())

        // MARK: 识别器（废弃兼容：v8 状态机已拆到图上，节点无执行逻辑）
        /// 旧配置 decode 后保留节点但不执行（输出全 invalid，链冻结）
        case .recognizer:
            return invalidOutputs(node)

        // MARK: 变量（帧首读/帧尾写，连线引用）

        /// varRef：输出 state[key] 当前值（无存储值时回退卡片 initial）；trigger 有效时记录写请求（帧尾统一生效）
        /// 关键：**有写请求时输出仍读 state 旧值**（摩尔语义：输出 = 当前状态，写值帧尾 flush 后才对下一帧可见）——
        /// 否则模块子图写延迟 flush 后，varRef 输出端口已暴露新值（如进入 holding 帧 phaseVar 输出 4），
        /// 主图当帧读到新状态 → tick 链瞬间激活 → 进 holding 同帧误调节
        case .varRef:
            let key = p.key ?? "var"
            // 写请求（帧尾统一生效）：trigger + value 均有效
            let writeValue: NodeValue?
            if inputs["trigger"]?.valid == true, let v = inputs["value"], v.valid {
                writeValue = v.value
            } else {
                writeValue = nil
            }
            // 读：输出当前存储值；无值回退卡片初始值（int/bool/float）；再无值输出 invalid
            let current: SocketValue
            if let v = state[key] {
                current = SocketValue(valid: true, value: v)
            } else if let i = p.initial {
                current = .int(i)
            } else if let b = p.initialBool {
                current = .bool(b)
            } else if let f = p.initialFloat {
                current = .float(f)
            } else {
                current = .invalid()
            }
            if let w = writeValue {
                return NodeExecutionResult(outputs: ["value": current], writes: [(key, w)])
            }
            return NodeExecutionResult(outputs: ["value": current])

        // MARK: 手指事件检测（替代 recognizer 物理层）

        /// finger：输入原始帧 → 按下/抬起脉冲 + 存在状态 + 手指信号
        /// 卡片内参数：touchSizeMin/Max（面积过滤）、region（可省略，区域数据从输入读）
        case .finger:
            return runFinger(node, inputs: inputs, frame: frame)

        // MARK: 数据源

        /// 唯一数据源：触控板多变量输出 + 原始帧 fingers（给识别器）
        /// 纯输出无输入——数据从 FrameContext.rawSignals/touches 读取
        case .touchData:
            var outputs: [String: SocketValue] = [:]
            for s in SignalSource.allCases {
                outputs[s.rawValue] = .float(frame.rawSignals[s] ?? 0)
            }
            outputs["fingers"] = .fingers(frame.touches)
            return NodeExecutionResult(outputs: outputs)
        case .value:
            if let i = p.constantInt { return output(node, .int(i)) }
            if let b = p.constantBool { return output(node, .bool(b)) }
            return output(node, .float(p.constant ?? 0))
        // 边界状态源：当前事件值在哪个边界（-1 下 / 0 无 / +1 上）+ 是否在边界
        case .boundaryState:
            return NodeExecutionResult(outputs: [
                "side": .float(Float(frame.boundarySide)),
                "atBoundary": .bool(frame.boundarySide != 0),
            ])

        // 区域引用：输出 region 数据（给识别器；数据从 FrameContext 注入，卡片内 regionID 关联）
        case .region:
            guard let region = frame.region else { return invalidOutputs(node) }
            return output(node, .region(region))
        // 事件引用：纯参数承载（无执行逻辑）
        case .event:
            return .init()

        // 批注组：纯结构节点（无执行逻辑）
        case .group:
            return .init()

        // MARK: 数学/变换（value:float → result:float）

        case .transform:
            guard let v = required(inputs, "value")?.value.floatValue else {
                // 输入无效（门控关闭/手指离开）→ 清空基线：下次接触用新值建基线，
                // 否则跨滑动残留旧基线 → 接触瞬间产生假 delta（消费跨滑动累积位移）
                state["transform.last.\(node.id)"] = nil
                return invalidOutputs(node)
            }
            switch p.transform ?? .delta {
            case .delta:
                let key = "transform.last.\(node.id)"
                let last = state[key]?.floatValue ?? v
                state[key] = .float(v)
                let d = v - last
                if abs(d) > 1e-6 { log("transform[\(node.title)] in=\(v) last=\(last) delta=\(d)") }
                return output(node, .float(d))
            case .absolute:
                return output(node, .float(v - (state["startRaw"]?.floatValue ?? 0)))
            }
        case .scale:
            guard let v = required(inputs, "value")?.value.floatValue else { return invalidOutputs(node) }
            return output(node, .float(v * (p.multiplier ?? 1) + (p.offset ?? 0)))
        case .clamp:
            guard let v = required(inputs, "value")?.value.floatValue else { return invalidOutputs(node) }
            return output(node, .float(min(max(v, p.min ?? 0), p.max ?? 1)))
        case .abs:
            guard let v = required(inputs, "value")?.value.floatValue else { return invalidOutputs(node) }
            return output(node, .float(abs(v)))
        case .sign:
            guard let v = required(inputs, "value")?.value.floatValue else { return invalidOutputs(node) }
            return output(node, .float(v >= 0 ? 1 : -1))

        // MARK: 比较/运算/时间

        /// compare：a 与 b 比较 → bool；b 缺省用卡片内 threshold 常量
        case .compare:
            let a: NodeValue
            if let v = inputs["a"], v.valid { a = v.value } else { return invalidOutputs(node) }
            let b: NodeValue
            if let v = inputs["b"], v.valid {
                b = v.value
            } else if let thr = p.threshold {
                b = .float(thr)
            } else if let initVal = p.initial {
                b = .int(initVal)
            } else {
                return invalidOutputs(node)
            }
            guard let result = compareValues(a, b, p.comparator ?? .eq) else { return invalidOutputs(node) }
            return output(node, .bool(result))

        /// arith：a ± × ÷ b（卡片内选择运算）
        case .arith:
            guard let a = required(inputs, "a")?.value.floatValue,
                  let b = required(inputs, "b")?.value.floatValue else { return invalidOutputs(node) }
            switch p.arithOp ?? .add {
            case .add: return output(node, .float(a + b))
            case .sub: return output(node, .float(a - b))
            case .mul: return output(node, .float(a * b))
            case .div: return output(node, b == 0 ? .float(0) : .float(a / b))
            }

        /// not：bool 取反
        case .not:
            guard let v = required(inputs, "value")?.value.boolValue else { return invalidOutputs(node) }
            return output(node, .bool(!v))

        /// now：输出当前时间（秒）
        case .now:
            return output(node, .float(Float(frame.now)))

        /// elapsed：trigger 重置计时起点，输出距上次 trigger 的经过时长
        case .elapsed:
            let key = "elapsed.\(node.id)"
            // 只在"事件触发"时重置：unit 脉冲（valid 即触发）或 bool true 边沿；
            // bool(false) 是有效数据但表示"未触发"，绝不能重置（否则计时恒 0 → 超时判定全部失效）
            if let t = inputs["trigger"], t.valid, isTriggerEvent(t.value) {
                state[key] = .float(Float(frame.now))
            }
            let start = state[key]?.floatValue ?? Float(frame.now)
            return output(node, .float(Float(frame.now) - start))

        /// accumulate：跨帧累积/取 max/min（value 每帧合并；trigger 重置）。
        /// 输入无效（门控关闭/手指离开）→ 清空累积，与 quantize/transform 一致——残留累积会在下次接触时产生假输出
        case .accumulate:
            guard let v = required(inputs, "value")?.value.floatValue else {
                state["accumulate.\(node.id)"] = nil
                return invalidOutputs(node)
            }
            let key = "accumulate.\(node.id)"
            if inputs["trigger"]?.valid == true {
                state[key] = .float(v)
                return output(node, .float(v))
            }
            let prev = state[key]?.floatValue ?? v
            let merged: Float
            switch p.accMode ?? .sum {
            case .sum: merged = prev + v
            case .max: merged = max(prev, v)
            case .min: merged = min(prev, v)
            }
            state[key] = .float(merged)
            return output(node, .float(merged))

        // MARK: 量化/门控

        case .quantize:
            guard let v = required(inputs, "value")?.value.floatValue else {
                // 门控关闭（手指离开）→ 清空累积：否则下次接触残留旧位移 → 假 tick
                state["quantize.accum.\(node.id)"] = nil
                return invalidOutputs(node)
            }
            let mode = p.triggerMode ?? .discrete
            let stepNorm = p.stepNorm ?? 0.02
            let key = "quantize.accum.\(node.id)"
            // 跨帧累积（discrete 关键）：滑动中每帧位移常 < stepNorm，若每帧独立量化则
            // 慢速连续滑动永不 tick（v8 图化重构退化 bug）。累积位移 + 触发后扣减 + 余量保留，
            // 与 v1 引擎 lastTriggerValue += tickCount×stepNorm 语义一致。
            let acc = (state[key]?.floatValue ?? 0) + v
            if mode == .continuous {
                let sens = p.sensitivity ?? 1.0
                guard abs(acc * sens) > 1e-6 else { return invalidOutputs(node) }
                let scaled = acc * sens
                let sign: Float = Float(frame.directionRule.mapSignalDirection(acc))
                state[key] = .float(0)   // continuous 不累积（每帧直接消费）
                let out = GestureOutput.continuous(delta: sign * abs(scaled))
                log("quantize[\(node.title)] in=\(v) -> \(out)")
                return output(node, .output(out))
            }
            let absAcc = abs(acc)
            let eps = max(stepNorm * 0.005, 1e-5)
            guard absAcc >= stepNorm - eps, stepNorm > 0 else {
                state[key] = .float(acc)   // 未到刻度：余量保留，下一帧继续累积
                if abs(acc) > 1e-6 { log("quantize[\(node.title)] acc=\(acc) -> 未达刻度") }
                return invalidOutputs(node)
            }
            let tickCount = Int(floor((absAcc + eps) / stepNorm))
            guard tickCount >= 1 else {
                state[key] = .float(acc)
                return invalidOutputs(node)
            }
            let sign: Float = acc >= 0 ? 1 : -1
            state[key] = .float(acc - Float(tickCount) * stepNorm * sign)   // 扣减已消费刻度，余量保留
            let direction = frame.directionRule.mapSignalDirection(acc)
            let out = GestureOutput.tick(direction: direction, count: tickCount)
            log("quantize[\(node.title)] acc=\(acc) -> \(out)")
            return output(node, .output(out))
        case .gate:
            guard let v = required(inputs, "value")?.value.floatValue else { return invalidOutputs(node) }
            let pass = compare(v, p.comparator ?? .gte, p.threshold ?? 0)
            return output(node, .bool(pass))
        case .debounce:
            guard required(inputs, "trigger") != nil else { return invalidOutputs(node) }
            let key = "debounce.last.\(node.id)"
            let last = state[key]?.floatValue ?? -.infinity
            let nowF = Float(frame.now)
            guard nowF - last >= Float(p.minIntervalMs ?? 0) / 1000 else { return invalidOutputs(node) }
            state[key] = .float(nowF)
            return output(node, .unit())

        // MARK: 条件分支：路由器（cond 选路，value 路由到 out1/out2，未选中路 invalid）

        case .branch:
            guard let valueV = required(inputs, "value") else { return invalidOutputs(node) }
            // cond 优先读输入端口；有效但非 bool（unit/output 脉冲）→ 视为 true；无输入连线时回退 predicate
            let cond: Bool
            if let c = inputs["cond"], c.valid {
                cond = c.value.boolValue ?? true
            } else if let predicate = p.predicate {
                cond = PredicateEvaluator.evaluate(predicate, input: valueV.value,
                                                   frame: frame, state: &state, nodeID: node.id)
            } else {
                cond = false
            }
            if cond {
                return NodeExecutionResult(outputs: ["out1": valueV, "out2": .invalid()])
            } else {
                return NodeExecutionResult(outputs: ["out1": .invalid(), "out2": valueV])
            }
        case .`switch`:
            // 简化：透传 value → result（多路选择后续完善）
            guard let v = required(inputs, "value") else { return invalidOutputs(node) }
            return output(node, v)

        // MARK: 模块（可折叠子图：统一输入/输出端口 + 内部节点图）

        /// module：收集组输入端口值 → 注入内部 moduleInput 连接器 → 执行子图 → 收集 moduleOutput 值 → 组输出
        /// 子图与主图共享 state（varRef 跨层一致）与 effects（副作用派发）
        /// 写类输入端口（ModulePort.isWrite）第一遍跳过注入（内部不触发写），
        /// 由 GraphEvaluator 帧末 writePass 重跑注入——避免「模块输出→tick 链→写类输入」同帧环
        case .module:
            guard let sub = node.subgraph,
                  let subEval = GraphEvaluator(timeline: sub) else { return invalidOutputs(node) }
            var injected: [UUID: [String: SocketValue]] = [:]
            for n in sub.nodes where n.type == .moduleInput {
                let portName = n.params.modulePortName ?? "value"
                if let port = node.params.moduleInputs?.first(where: { $0.name == portName }),
                   port.isWrite, !writePass {
                    continue
                }
                injected[n.id] = ["value": inputs[portName] ?? .invalid()]
            }
            // writePass：帧末延迟重跑，抑制副作用（只收集写请求，不重复派发）
            let eff: TimelineEffects = writePass ? SilentEffects() : effects
            // deferFlush：子图写请求（phase/frozen 等）延迟到主图帧尾统一 flush——
            // 否则子图立即 flush 会让主图后续节点本帧读到"新状态"（进入 holding 同帧 tick 就激活 → 瞬间误调节）
            let subWrites = subEval.evaluate(frame: frame, state: &state, effects: eff,
                                             entryIDs: nil, injected: injected, deferFlush: true)
            var outs: [String: SocketValue] = [:]
            for n in sub.nodes where n.type == .moduleOutput {
                let portName = n.params.modulePortName ?? "result"
                outs[portName] = subEval.inputValue(of: n.id, port: "value") ?? .invalid()
            }
            return NodeExecutionResult(outputs: outs,
                                       writes: subWrites.map { ($0.key, $0.value) })

        /// moduleInput/moduleOutput 连接器：无执行输出——值由 module 注入（injected 预置 portValues）/收集（inputValue）
        /// 返回无输出避免覆盖 injected；主图单独执行时下游读不到 → invalid（合理）
        case .moduleInput, .moduleOutput:
            return NodeExecutionResult()

        // MARK: 副作用/反馈（输入有效才执行；执行后输出 result = unit 事件脉冲）

        case .consume:
            guard let v = required(inputs, "data"), let out = v.value.outputValue else { return invalidOutputs(node) }
            let result = effects.consume(out)
            log("consume[\(node.title)] \(out) -> \(result)")
            return output(node, .unit())
        case .haptic:
            guard required(inputs, "trigger") != nil else { return invalidOutputs(node) }
            effects.triggerHaptic(waveform: p.waveform ?? 0,
                                  count: p.count ?? 1,
                                  intervalUs: p.intervalUs ?? 0,
                                  async: p.async ?? true)
            return output(node, .unit())
        case .hud:
            guard required(inputs, "data") != nil else { return invalidOutputs(node) }
            effects.showHUD(direction: (p.step ?? 0) >= 0 ? 1 : -1)
            return output(node, .unit())
        case .mouse:
            guard required(inputs, "trigger") != nil else { return invalidOutputs(node) }
            switch p.mouseMode ?? .lockPosition {
            case .lockPosition:   effects.lockMouse()
            case .unlockPosition: effects.unlockMouse()
            }
            return output(node, .unit())
        case .freeze:
            guard required(inputs, "trigger") != nil else { return invalidOutputs(node) }
            effects.freeze()
            return output(node, .unit())
        case .notify:
            guard required(inputs, "trigger") != nil else { return invalidOutputs(node) }
            effects.notify(label: p.label ?? "")
            return output(node, .unit())

        // MARK: 变量操作（外部状态变量 + 通用操作，替代专有行为卡片）

        /// set：trigger 脉冲时把 value 写入 state[key]（如 cursorLocked=1）
        case .set:
            guard required(inputs, "trigger") != nil,
                  let v = required(inputs, "value") else { return invalidOutputs(node) }
            state[p.key ?? "var"] = v.value
            return output(node, .unit())
        /// toggle：trigger 脉冲时对 state[key] 取反（bool）
        case .toggle:
            guard required(inputs, "trigger") != nil else { return invalidOutputs(node) }
            let key = p.key ?? "var"
            let current = state[key]?.boolValue ?? false
            state[key] = .bool(!current)
            return output(node, .unit())

        // MARK: 流控制

        case .split:
            guard let v = required(inputs, "value") else { return invalidOutputs(node) }
            return NodeExecutionResult(outputs: ["out1": v, "out2": v])
        case .merge:
            guard let a = required(inputs, "input1")?.value.floatValue,
                  let b = required(inputs, "input2")?.value.floatValue else { return invalidOutputs(node) }
            switch p.mergeMode ?? .sum {
            case .sum: return output(node, .float(a + b))
            case .max: return output(node, .float(max(a, b)))
            case .min: return output(node, .float(min(a, b)))
            }
        case .baseline:
            // 触发有效时记录当前帧信号源（trigger:unit 输入；记录到 state[key]）
            guard inputs["trigger"]?.valid == true else { return invalidOutputs(node) }
            let src = p.source ?? .normY
            guard let v = frame.rawSignals[src] else { return invalidOutputs(node) }
            state[p.key ?? "baseline"] = .float(v)
            return output(node, .float(v))
        case .state:
            let key = p.key ?? "state"
            if let v = inputs["value"], v.valid {
                state[key] = v.value
                return output(node, v)
            }
            // 读：有值 → 有效；无值 → invalid
            return output(node, state[key].map { SocketValue(valid: true, value: $0) } ?? .invalid())
        }
    }

    // MARK: - 手指事件检测

    /// 手指事件节点跨帧状态（记录上一帧是否有手指，用于按下/抬起边沿检测）
    private static var fingerStates: [UUID: Bool] = [:]
    /// 触控板最后一次有手指的时间戳（抬起判定容错：MT 回调在滑动中有采样间歇，
    /// 帧可能短暂无手指数据——用"持续无手指 100ms"判定抬起，采样间隙不会误触发退出）
    private static var fingerLastPresent: [UUID: Double] = [:]
    /// up 满足锁存（抬起边沿化）：up 只在"持续无手指 >100ms"的首次满足帧触发一次，
    /// 之后保持 false 直到重新有手指——否则 up 是持续 true（持续无手指时每帧都成立），
    /// 会持续重置间隔计时（gapElapsed）导致间隔超时永不触发、holding 退出链每帧重复激活
    private static var upSatisfied: [UUID: Bool] = [:]
    /// 上一帧"触控板有手指"（present 边沿日志用）
    private static var fingerPresent: [UUID: Bool] = [:]
    /// 实时压力日志节流（Force 阈值校准：有手指时 ~20Hz 输出 zP/state，tail -f 实时看）
    /// 全局共享（4 个手势的 finger 节点同帧执行，只打一次）
    private static var forceLogLast: Double = -.infinity

    /// 清空跨帧静态状态（finger 边沿检测；测试/重置用）
    public static func resetRuntime() {
        fingerStates.removeAll(keepingCapacity: true)
        fingerLastPresent.removeAll(keepingCapacity: true)
        upSatisfied.removeAll(keepingCapacity: true)
        fingerPresent.removeAll(keepingCapacity: true)
        forceLogLast = -.infinity
    }

    /// finger：输入原始帧 → 按下/抬起边沿脉冲 + 存在状态 + 手指信号 + 身份
    /// 卡片内参数：touchSizeMin/Max（面积过滤）；region 输入可选（区域过滤）
    private static func runFinger(_ node: NodeConfig, inputs: [String: SocketValue],
                                  frame: FrameContext) -> NodeExecutionResult {
        let p = node.params
        let touches = inputs["fingers"]?.value.fingersValue ?? []
        let region = inputs["region"]?.value.regionValue
        let sizeMin = p.touchSizeMin ?? 0.1
        let sizeMax = p.touchSizeMax ?? 1.0
        // 手掌过滤（v10.21）：palmFilter=false 时只按下限过滤（重压/手掌也会进入识别）；
        // 默认 true 保持原行为（size 超上限视为手掌排除）
        let palmFilter = p.palmFilter ?? true
        func isSizeValid(_ t: mt_touch_t) -> Bool {
            palmFilter ? (t.size >= sizeMin && t.size <= sizeMax) : t.size >= sizeMin
        }
        func inRegion(_ t: mt_touch_t) -> Bool { region?.contains(x: t.norm_x, y: t.norm_y) ?? true }
        // 在区域内、尺寸有效、非 lift/None 的手指（按下/存在状态用——过滤手掌/区域外）
        let active = touches.first {
            $0.state != 0 && $0.state != 7 && isSizeValid($0) && inRegion($0)
        }
        let touching = active != nil
        // 触控板上是否还有手指（原始帧，不过滤 size/region）：抬起判定用——
        // 滑动调节时 size（压力）波动/区域边界抖动会让 touching 闪断，若用 touching 判抬起会误退出 holding；
        // 只要手指还在触控板上（state 非 none/lift）就不算抬起
        let rawPresent = touches.contains { $0.state != 0 && $0.state != 7 }
        if rawPresent {
            fingerLastPresent[node.id] = frame.now
        }
        let prev = fingerStates[node.id] ?? false
        fingerStates[node.id] = touching
        let down = touching && !prev
        // up：触控板持续无手指 >100ms 才判定抬起（时间基准，不依赖帧率）——
        // 滑动中 MT 采样间歇（帧短暂无手指数据）不会误退出；真抬起 100ms 后退出，无感
        // 边沿化：只在首次满足帧触发一次（upSatisfied 锁存），否则持续 true 会重置间隔计时；
        // +1e-6 容差：浮点累加误差（如 0.70-0.60 = 0.10000000000000009）会提前 1 帧误触发
        // 快照陈旧兜底（staleEmpty）：MT 离开后若回调完全停止且最后快照无手指——200ms 无新回调即抬起。
        // **关键（v10.11 修复）：快照陈旧但快照里还有手指 → 不判抬起**——MT 在采样间歇/暂停报告时
        // 快照会短暂"停住"（停在有手指），若此时判抬起会在滑动中误退出 holding（用户核心痛点）；
        // 日志实证手指离开时 MT 必回调空帧/state=0 残留 → 快照终会变无手指，走 100ms 主分支
        let lastPresent = fingerLastPresent[node.id] ?? frame.now
        let staleEmpty = frame.wallNow - frame.touchTimestamp > 0.2 && !rawPresent
        let satisfied = staleEmpty || (!rawPresent && (frame.now - lastPresent) > 0.1 + 1e-6)
        let up = satisfied && !(upSatisfied[node.id] ?? false)
        upSatisfied[node.id] = satisfied

        var out: [String: SocketValue] = [
            "touchDown": down ? .unit() : .invalid(),
            "touchUp": up ? .unit() : .invalid(),
            "down": .bool(down),
            "up": .bool(up),
            "touching": .bool(touching),
            "present": .bool(rawPresent),
            "normY": .invalid(), "normX": .invalid(),
            "pathIndex": .invalid(), "pressure": .invalid(),
        ]
        if let f = active {
            out["normY"] = .float(f.norm_y)
            out["normX"] = .float(f.norm_x)
            out["pathIndex"] = .int(f.pathIndex)
            out["pressure"] = .float(f.zPressure)
        }
        // 诊断日志：存在/接触状态变化（实证滑动中是否闪断）
        let prevPresent = fingerPresent[node.id] ?? false
        fingerPresent[node.id] = rawPresent
        if rawPresent != prevPresent || touching != prev {
            let sz = active?.size ?? -1
            let y = active?.norm_y ?? -1
            let pr = active?.zPressure ?? -1
            let st = active?.state ?? -1
            log("finger[\(node.title)] present=\(rawPresent) touching=\(touching) n=\(touches.count) " +
                "size=\(String(format: "%.3f", sz)) y=\(String(format: "%.3f", y)) " +
                "zP=\(String(format: "%.3f", pr)) state=\(st)")
        }
        // 实时压力等级（~20Hz，有手指时周期输出 zP/state——Force 阈值校准用；tail -f 日志实时看）
        // 全局节流：4 个手势的 finger 节点同帧执行，只打一次
        // **用 active（区域内+尺寸有效 = 用户手指）而非 touches.first**——touches.first 可能是手掌（zP 虚高 1.1~1.3）
        if rawPresent, frame.now - forceLogLast > 0.05 {
            forceLogLast = frame.now
            let pr = active?.zPressure ?? -1
            let st = active?.state ?? -1
            log("forceLevel zP=\(String(format: "%.3f", pr)) state=\(st) n=\(touches.count)")
        }
        return NodeExecutionResult(outputs: out)
    }

    // MARK: - 辅助

    /// 单输出节点：输出端口取注册表第一个输出名（如 result/tick/pass/trigger）
    private static func output(_ node: NodeConfig, _ v: SocketValue) -> NodeExecutionResult {
        let name = NodeTypeDef.outputSockets(of: node).first?.name ?? "result"
        return NodeExecutionResult(outputs: [name: v])
    }

    /// 读取必需输入：缺失或 invalid → nil（调用方输出全 invalid）
    private static func required(_ inputs: [String: SocketValue], _ port: String) -> SocketValue? {
        guard let v = inputs[port], v.valid else { return nil }
        return v
    }

    /// 事件触发判定（与 branch.cond 语义一致）：
    /// - unit/output 脉冲 = 触发；int/float（转移链 out1 传目标状态值）有效即触发（脉冲语义）
    /// - bool 仅 true 触发——bool(false) 是有效数据但表示"未触发"（down/up 边沿的静默帧），
    ///   绝不能当触发（否则 elapsed 计时被每帧重置 → 超时判定全部失效）
    private static func isTriggerEvent(_ v: NodeValue) -> Bool {
        switch v {
        case .unit, .output, .int, .float: return true
        case .bool(let b): return b
        default: return false
        }
    }

    /// 必需输入无效 → 所有输出端口写 .invalid()（显式传播；无输出端口的节点返回 nil）
    private static func invalidOutputs(_ node: NodeConfig) -> NodeExecutionResult {
        let sockets = NodeTypeDef.outputSockets(of: node)
        guard !sockets.isEmpty else { return .init() }
        return NodeExecutionResult(outputs: Dictionary(uniqueKeysWithValues: sockets.map { ($0.name, SocketValue.invalid()) }))
    }

    private static func compare(_ v: Float, _ cmp: Comparator, _ thr: Float) -> Bool {
        switch cmp {
        case .gt:  return v > thr
        case .gte: return v >= thr
        case .lt:  return v < thr
        case .lte: return v <= thr
        case .eq:  return v == thr
        case .neq: return v != thr
        }
    }

    /// 通用比较（int/float/bool 值）：类型不一致返回 nil（无法比较）
    private static func compareValues(_ a: NodeValue, _ b: NodeValue, _ cmp: Comparator) -> Bool? {
        switch (a, b) {
        case (.int(let x), .int(let y)):
            return compareInt(x, y, cmp)
        case (.float(let x), .float(let y)):
            return compare(x, cmp, y)
        case (.float(let x), .int(let y)):
            return compare(x, cmp, Float(y))
        case (.int(let x), .float(let y)):
            return compare(Float(x), cmp, y)
        case (.bool(let x), .bool(let y)):
            switch cmp {
            case .eq:  return x == y
            case .neq: return x != y
            default:   return nil
            }
        default:
            return nil
        }
    }

    private static func compareInt(_ x: Int32, _ y: Int32, _ cmp: Comparator) -> Bool {
        switch cmp {
        case .gt:  return x > y
        case .gte: return x >= y
        case .lt:  return x < y
        case .lte: return x <= y
        case .eq:  return x == y
        case .neq: return x != y
        }
    }
}

// MARK: - Predicate 求值

public enum PredicateEvaluator {
    public static func evaluate(_ predicate: Predicate,
                                input: NodeValue,
                                frame: FrameContext,
                                state: inout StateStore,
                                nodeID: UUID) -> Bool {
        switch predicate {
        case .atBoundary:    return frame.isAtBoundary
        case .notAtBoundary: return !frame.isAtBoundary
        case .firstTime:
            let key = "firstTime.\(nodeID)"
            let first = state[key] == nil
            state[key] = .bool(false)
            return first
        case .positive: return input.floatValue.map { $0 > 0 } ?? false
        case .negative: return input.floatValue.map { $0 < 0 } ?? false
        case .compare(let cmp, let thr):
            guard let v = input.floatValue else { return false }
            switch cmp {
            case .gt:  return v > thr
            case .gte: return v >= thr
            case .lt:  return v < thr
            case .lte: return v <= thr
            case .eq:  return v == thr
            case .neq: return v != thr
            }
        case .and(let l, let r):
            return evaluate(l, input: input, frame: frame, state: &state, nodeID: nodeID)
                && evaluate(r, input: input, frame: frame, state: &state, nodeID: nodeID)
        case .or(let l, let r):
            return evaluate(l, input: input, frame: frame, state: &state, nodeID: nodeID)
                || evaluate(r, input: input, frame: frame, state: &state, nodeID: nodeID)
        case .not(let inner):
            return !evaluate(inner, input: input, frame: frame, state: &state, nodeID: nodeID)
        }
    }
}
