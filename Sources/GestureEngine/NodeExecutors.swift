import Foundation
import mt_bridge

// MARK: - 节点执行器（数据流：输入 socket 值 → 输出 socket 值，副作用经 effects 派发）

/// 按 NodeType 分发执行逻辑（v6 数据流语义）。
/// - 端口名与 NodeTypeDef 注册表一致（如数学类 value→result、quantize value→tick）
/// - **valid 传播**：任一必需输入 invalid → 输出全 .invalid()（显式，下游可见）
/// - 副作用节点（consume/haptic/...）仅在输入有效时执行，执行后输出 result = unit（事件脉冲）
/// - branch = 路由器：cond 决定把 value 路由到 out1/out2，未选中路输出 invalid
public enum NodeExecutors {

    /// 执行单个节点
    /// - Parameters:
    ///   - node: 节点配置（type + params）
    ///   - inputs: 入边收集到的端口值（key = to.portName；含 invalid，表示上游已显式传播）
    ///   - frame: 当前帧上下文
    ///   - state: 跨节点共享状态（baseline/transform.last/debounce.last/state 节点读写）
    ///   - effects: 副作用派发
    public static func execute(node: NodeConfig,
                               inputs: [String: SocketValue],
                               frame: FrameContext,
                               state: inout StateStore,
                               effects: TimelineEffects) -> NodeExecutionResult {
        let p = node.params

        switch node.type {
        // MARK: 管道出口（收到有效 unit 脉冲 → 透传启动下游链）

        case .pipeOut:
            guard required(inputs, "trigger") != nil else { return invalidOutputs(node) }
            return output(node, .unit())

        // MARK: 识别器（系统算法封装：轻点/双击/保持时序识别，内部跨帧状态机）
        // 输入全显式（fingers + region），输出时机脉冲 + isHolding 状态

        case .recognizer:
            return runRecognizer(node, inputs: inputs, frame: frame,
                                 state: &state, effects: effects)

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
            return output(node, .float(p.constant ?? 0))

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
            guard let v = required(inputs, "value")?.value.floatValue else { return invalidOutputs(node) }
            switch p.transform ?? .delta {
            case .delta:
                let key = "transform.last.\(node.id)"
                let last = state[key]?.floatValue ?? v
                state[key] = .float(v)
                return output(node, .float(v - last))
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

        // MARK: 量化/门控

        case .quantize:
            guard let v = required(inputs, "value")?.value.floatValue else { return invalidOutputs(node) }
            let mode = p.triggerMode ?? .discrete
            guard let out = quantize(delta: v,
                                     triggerMode: mode,
                                     stepNorm: p.stepNorm ?? 0.02,
                                     sensitivity: p.sensitivity ?? 1.0,
                                     mapDirection: { frame.directionRule.mapSignalDirection($0) }) else {
                // 没到刻度 → 无产出 → tick invalid（整链冻结）
                return invalidOutputs(node)
            }
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
            // cond 优先读输入端口；无输入连线时回退 predicate（兼容迁移图）
            let cond: Bool
            if let c = inputs["cond"], c.valid {
                cond = c.value.boolValue ?? false
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

        // MARK: 副作用/反馈（输入有效才执行；执行后输出 result = unit 事件脉冲）

        case .consume:
            guard let v = required(inputs, "data"), let out = v.value.outputValue else { return invalidOutputs(node) }
            _ = effects.consume(out)
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

    // MARK: - 识别器（轻点/双击/保持 时序识别）

    /// 识别器内部跨帧状态（私有变量，按节点 id 存储）
    struct RecognizerState {
        enum Phase { case idle, firstTapDown, firstTapUp, secondTapDown, holding, cooldown }
        var phase: Phase = .idle
        var pathIndex: Int32 = -1
        var startTime: Double = 0
        var startPos: (Float, Float) = (0, 0)
        var maxDrift: Float = 0
        var endTime: Double = 0
        var startRaw: Float = 0
        var lastTriggerVal: Float = 0
        var frozen = false
        var freezeDir: Float = 0

        init(phase: Phase = .idle, pathIndex: Int32 = -1, startTime: Double = 0,
             startPos: (Float, Float) = (0, 0), maxDrift: Float = 0, endTime: Double = 0,
             startRaw: Float = 0, lastTriggerVal: Float = 0,
             frozen: Bool = false, freezeDir: Float = 0) {
            self.phase = phase
            self.pathIndex = pathIndex
            self.startTime = startTime
            self.startPos = startPos
            self.maxDrift = maxDrift
            self.endTime = endTime
            self.startRaw = startRaw
            self.lastTriggerVal = lastTriggerVal
            self.frozen = frozen
            self.freezeDir = freezeDir
        }
    }

    /// 识别器状态（跨帧私有变量；每手势一个识别器节点，id 唯一）
    private static var recognizerStates: [UUID: RecognizerState] = [:]

    /// 识别器执行：读显式输入（fingers 原始帧 + region）→ 内部状态机 → 输出时机脉冲 + isHolding
    /// 算法参数（tapMax*/holdMinDuration/source/stepNorm/touchSize*）全部在卡片内配置
    private static func runRecognizer(_ node: NodeConfig, inputs: [String: SocketValue],
                                      frame: FrameContext,
                                      state: inout StateStore,
                                      effects: TimelineEffects) -> NodeExecutionResult {
        var st = recognizerStates[node.id] ?? RecognizerState()
        defer { recognizerStates[node.id] = st }

        let p = node.params
        // 显式输入：手指原始帧 + 触发区域（数据流端口，非隐式注入）
        let touches = inputs["fingers"]?.value.fingersValue ?? []
        let region = inputs["region"]?.value.regionValue
        // 卡片内参数：尺寸过滤（防手掌）
        let sizeMin = p.touchSizeMin ?? 0.1
        let sizeMax = p.touchSizeMax ?? 1.0
        func isSizeValid(_ t: mt_touch_t) -> Bool { t.size >= sizeMin && t.size <= sizeMax }
        func inRegion(_ t: mt_touch_t) -> Bool { region?.contains(x: t.norm_x, y: t.norm_y) ?? true }
        let edgeFinger: mt_touch_t? = touches.first {
            inRegion($0) && $0.state != 0 && $0.state != 7 && isSizeValid($0)
        }
        func fingerStillThere(_ pathIdx: Int32) -> Bool {
            touches.contains { $0.pathIndex == pathIdx && $0.state != 0 && $0.state != 7 && isSizeValid($0) }
        }

        let source = p.source ?? .normY
        let stepNorm = p.stepNorm ?? 0.02
        let tapMaxDuration = p.tapMaxDuration ?? 0.20
        let tapMaxDrift = p.tapMaxDrift ?? 0.05
        let tapMaxGap = p.tapMaxGap ?? 0.30
        let holdMinDuration = p.holdMinDuration ?? 0.20

        // 输出端口：时机脉冲默认 invalid；isHolding 每帧输出当前状态
        var out: [String: SocketValue] = [
            "firstTap": .invalid(), "enterHolding": .invalid(),
            "tick": .invalid(), "exitHolding": .invalid(),
            "isHolding": .bool(st.phase == .holding),
        ]

        func drift(_ f: mt_touch_t, _ pos: (Float, Float)) -> Float {
            hypot(f.norm_x - pos.0, f.norm_y - pos.1)
        }

        switch st.phase {
        case .idle:
            if let f = edgeFinger, f.state == 1 || f.state == 3 || f.state == 4 {
                st = RecognizerState(phase: .firstTapDown, pathIndex: f.pathIndex,
                                     startTime: frame.now, startPos: (f.norm_x, f.norm_y))
            }

        case .firstTapDown:
            if !fingerStillThere(st.pathIndex) {
                if st.maxDrift > tapMaxDrift {
                    st = RecognizerState(phase: .cooldown, pathIndex: st.pathIndex)
                } else {
                    st = RecognizerState(phase: .firstTapUp, endTime: frame.now)
                }
            } else {
                if let f = edgeFinger, f.pathIndex == st.pathIndex {
                    let d = drift(f, st.startPos)
                    if d > st.maxDrift { st.maxDrift = d }
                }
                if frame.now - st.startTime > tapMaxDuration || st.maxDrift > tapMaxDrift {
                    st = RecognizerState(phase: .cooldown, pathIndex: st.pathIndex)
                }
            }

        case .firstTapUp:
            if frame.now - st.endTime > tapMaxGap {
                st = RecognizerState(phase: .idle)
            } else if let f = edgeFinger, f.state == 1 || f.state == 3 || f.state == 4 {
                out["firstTap"] = .unit()   // 第一次轻点完成
                st = RecognizerState(phase: .secondTapDown, pathIndex: f.pathIndex,
                                     startTime: frame.now, startPos: (f.norm_x, f.norm_y))
            }

        case .secondTapDown:
            if !fingerStillThere(st.pathIndex) {
                st = RecognizerState(phase: .idle)
            } else {
                if let f = edgeFinger, f.pathIndex == st.pathIndex {
                    let d = drift(f, st.startPos)
                    if d > st.maxDrift { st.maxDrift = d }
                }
                if st.maxDrift > tapMaxDrift {
                    st = RecognizerState(phase: .cooldown, pathIndex: st.pathIndex)
                } else if frame.now - st.startTime > holdMinDuration,
                          let f = edgeFinger, f.pathIndex == st.pathIndex {
                    // 进入保持：记录起始信号 + 输出 enterHolding 脉冲
                    let raw = source.extract(from: f)
                    st = RecognizerState(phase: .holding, pathIndex: f.pathIndex,
                                         startTime: frame.now, startPos: (f.norm_x, f.norm_y),
                                         startRaw: raw, lastTriggerVal: raw)
                    out["enterHolding"] = .unit()
                    out["isHolding"] = .bool(true)
                    effects.recognizerState(holding: true)
                }
            }

        case .holding:
            if !fingerStillThere(st.pathIndex) {
                out["exitHolding"] = .unit()
                out["isHolding"] = .bool(false)
                effects.recognizerState(holding: false)
                st = RecognizerState(phase: .idle)
            } else if st.frozen {
                // 冻结中：反向滑动（方向与冻结前移动相反）且幅度足够 → 解冻
                guard let f = edgeFinger, f.pathIndex == st.pathIndex else { break }
                let raw = source.extract(from: f)
                let delta = raw - st.lastTriggerVal
                if abs(delta) >= 0.5 * stepNorm, (delta >= 0) != (st.freezeDir >= 0) {
                    st.frozen = false
                    st.lastTriggerVal = raw
                    state["frozen"] = .bool(false)   // 解冻：写回变量
                }
            } else if let f = edgeFinger, f.pathIndex == st.pathIndex {
                let raw = source.extract(from: f)
                if state["frozen"]?.boolValue == true {
                    // 冻结变量已置位（边界链 set(frozen=1)）→ 进入冻结
                    st.frozen = true
                    st.freezeDir = raw >= st.lastTriggerVal ? 1 : -1
                } else {
                    out["tick"] = .unit()   // 保持中每帧脉冲 → 调节链
                    st.lastTriggerVal = raw
                }
            }

        case .cooldown:
            if !fingerStillThere(st.pathIndex) {
                st = RecognizerState(phase: .idle)
            }
        }

        return NodeExecutionResult(outputs: out)
    }

    // MARK: - 辅助

    /// 单输出节点：输出端口取注册表第一个输出名（如 result/tick/pass/trigger）
    private static func output(_ node: NodeConfig, _ v: SocketValue) -> NodeExecutionResult {
        let name = NodeTypeDef.outputSockets(of: node.type).first?.name ?? "result"
        return NodeExecutionResult(outputs: [name: v])
    }

    /// 读取必需输入：缺失或 invalid → nil（调用方输出全 invalid）
    private static func required(_ inputs: [String: SocketValue], _ port: String) -> SocketValue? {
        guard let v = inputs[port], v.valid else { return nil }
        return v
    }

    /// 必需输入无效 → 所有输出端口写 .invalid()（显式传播；无输出端口的节点返回 nil）
    private static func invalidOutputs(_ node: NodeConfig) -> NodeExecutionResult {
        let sockets = NodeTypeDef.outputSockets(of: node.type)
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
