import Foundation

// MARK: - 节点执行器（纯函数：输入 → 输出，副作用经 effects 派发）

/// 按 NodeType 分发执行逻辑。
/// 约定：输入端口默认 "input"（merge 用 "input1"/"input2"），输出端口 "output"
///       （split 用 "output1"/"output2"）；branch 不写端口值，只返回 branchResult。
public enum NodeExecutors {

    /// 执行单个节点
    /// - Parameters:
    ///   - node: 节点配置（type + params）
    ///   - inputs: 入边收集到的值，key = to.portName
    ///   - frame: 当前帧上下文
    ///   - state: 跨节点共享状态（baseline/transform.last/debounce.last/state 节点读写）
    ///   - effects: 副作用派发
    /// - Returns: 执行结果（nil outputs = 无输出，后续节点不激活）
    public static func execute(node: NodeConfig,
                               inputs: [String: NodeValue],
                               frame: FrameContext,
                               state: inout StateStore,
                               effects: TimelineEffects) -> NodeExecutionResult {
        let p = node.params

        switch node.type {
        // MARK: 数据源
        case .signal:
            return result(.float(frame.rawSignals[p.source ?? .normY] ?? 0))
        case .value:
            return result(.float(p.constant ?? 0))

        // MARK: 数学/变换
        case .transform:
            guard let v = inputs["input"]?.floatValue else { return .init() }
            switch p.transform ?? .delta {
            case .delta:
                let key = "transform.last.\(node.id)"
                let last = state[key]?.floatValue ?? v
                state[key] = .float(v)
                return result(.float(v - last))
            case .absolute:
                return result(.float(v - (state["startRaw"]?.floatValue ?? 0)))
            }
        case .scale:
            guard let v = inputs["input"]?.floatValue else { return .init() }
            return result(.float(v * (p.multiplier ?? 1) + (p.offset ?? 0)))
        case .clamp:
            guard let v = inputs["input"]?.floatValue else { return .init() }
            return result(.float(min(max(v, p.min ?? 0), p.max ?? 1)))
        case .abs:
            guard let v = inputs["input"]?.floatValue else { return .init() }
            return result(.float(abs(v)))
        case .sign:
            guard let v = inputs["input"]?.floatValue else { return .init() }
            return result(.float(v >= 0 ? 1 : -1))

        // MARK: 量化/门控
        case .quantize:
            guard let delta = inputs["input"]?.floatValue else { return .init() }
            let mode = p.triggerMode ?? .discrete
            guard let out = quantize(delta: delta,
                                     triggerMode: mode,
                                     stepNorm: p.stepNorm ?? 0.02,
                                     sensitivity: p.sensitivity ?? 1.0,
                                     mapDirection: { frame.directionRule.mapSignalDirection($0) }) else {
                return .init()
            }
            return result(.output(out))
        case .gate:
            guard let v = inputs["input"]?.floatValue else { return .init() }
            let pass = compare(v, p.comparator ?? .gte, p.threshold ?? 0)
            return pass ? result(.float(v)) : .init()
        case .debounce:
            guard let v = inputs["input"], (p.minIntervalMs ?? 0) > 0 else {
                return inputs["input"].map { result($0) } ?? .init()
            }
            let key = "debounce.last.\(node.id)"
            let last = state[key]?.floatValue ?? -.infinity
            let nowF = Float(frame.now)
            guard nowF - last >= Float(p.minIntervalMs ?? 0) / 1000 else { return .init() }
            state[key] = .float(nowF)
            return result(v)

        // MARK: 条件分支
        case .branch:
            guard let predicate = p.predicate else { return .init() }
            let input = inputs["input"] ?? .unit
            let value = PredicateEvaluator.evaluate(predicate,
                                                    input: input,
                                                    frame: frame,
                                                    state: &state,
                                                    nodeID: node.id)
            // 输入透传到 true/false 端口（激活由 GraphEvaluator 按 branchResult 决定）
            return NodeExecutionResult(outputs: ["true": input, "false": input],
                                       branchResult: value)
        case .`switch`:
            // 简化：把 input 的 float 值取整作为索引写入 caseN 端口（未连接的 case 跳过）
            guard let v = inputs["input"]?.floatValue else { return .init() }
            let index = Int(v)
            var outputs: [String: NodeValue] = [:]
            for i in 0..<8 where i == index { outputs["case\(i)"] = .float(v) }
            return NodeExecutionResult(outputs: outputs.isEmpty ? nil : outputs)

        // MARK: 副作用/反馈（执行后写 .unit 输出，支持后续节点串联激活）
        case .consume:
            guard let out = inputs["input"]?.outputValue else { return .init() }
            _ = effects.consume(out)
            return unit()
        case .haptic:
            effects.triggerHaptic(waveform: p.waveform ?? 0,
                                  count: p.count ?? 1,
                                  intervalUs: p.intervalUs ?? 0,
                                  async: p.async ?? true)
            return unit()
        case .hud:
            effects.showHUD(direction: (p.step ?? 0) >= 0 ? 1 : -1)
            return unit()
        case .mouse:
            switch p.mouseMode ?? .lockPosition {
            case .lockPosition:   effects.lockMouse()
            case .unlockPosition: effects.unlockMouse()
            }
            return unit()
        case .freeze:
            effects.freeze()
            return unit()
        case .notify:
            effects.notify(label: p.label ?? "")
            return unit()

        // MARK: 流控制
        case .split:
            guard let v = inputs["input"] else { return .init() }
            return NodeExecutionResult(outputs: ["output1": v, "output2": v])
        case .merge:
            guard let a = inputs["input1"]?.floatValue, let b = inputs["input2"]?.floatValue else { return .init() }
            switch p.mergeMode ?? .sum {
            case .sum: return result(.float(a + b))
            case .max: return result(.float(max(a, b)))
            case .min: return result(.float(min(a, b)))
            }
        case .baseline:
            // 无输入时从 frame 读信号源（如 enter timeline 的 baseline 节点）
            let v = inputs["input"]?.floatValue
                ?? (p.source.map { frame.rawSignals[$0] })
                ?? nil
            guard let v else { return .init() }
            state[p.key ?? "baseline"] = .float(v)
            return result(.float(v))
        case .state:
            let key = p.key ?? "state"
            if let v = inputs["input"] {
                state[key] = v
                return result(v)
            }
            return result(state[key] ?? .unit)
        }
    }

    // MARK: - 辅助

    private static func result(_ v: NodeValue) -> NodeExecutionResult {
        NodeExecutionResult(outputs: ["output": v])
    }

    /// 副作用节点标准输出：写 .unit 使后续节点可激活
    private static func unit() -> NodeExecutionResult {
        NodeExecutionResult(outputs: ["output": .unit])
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
