# 项目备忘录

## 全配置化数据处理管线规划（2026-08-01）

### 设计目标
从「原始触摸数据 → 哪个字段 → 怎么处理 → 给事件传什么 → 什么时候震动」全链路配置化。
用户可以在 UI 里选择：用哪个轴的信号、怎么量化、传什么给事件、震动的时机和波形。

### 现状问题（8 项）
1. dy 大小被丢弃：引擎只传 direction: Int(±1)，滑动速度/幅度信息丢失
2. step 在 mediaKey 模式下是死字段：UI 让调但 perform 的 mediaKey 分支不读
3. 没有连续模式：只有离散刻度，无法做"dy 越大调越多"
4. 快速滑动丢刻度：帧限频丢帧后 dy 跨多个 slideStepNorm，每帧只触发 1 次
5. 边界逻辑分散：进入时 isAtAnyBoundary + postBoundaryKey 在引擎，滑动时 canDetect 也在引擎
6. frozen 无解冻路径：到边界冻结后只能等手指抬起
7. usleep(50ms) 阻塞帧处理
8. 死代码：SystemControl.adjustVolume/adjustBrightness 从未被调用

### 管线 6 个阶段

```
mt_touch_t 原始帧
  │
  ├─ [阶段1] 信号源选取（GestureConfig.signalSource）
  │   配置：从 mt_touch_t 提取哪个字段作为主信号
  │   .normY    → rawValue = f.norm_y        （默认：Y轴坐标）
  │   .normX    → rawValue = f.norm_x        （X轴坐标）
  │   .size     → rawValue = f.size          （接触面积）
  │   .pressure → rawValue = f.zPressure     （压力）
  │
  ├─ [阶段2] 信号变换（GestureConfig.transformMode）
  │   配置：怎么从 rawValue 产生变化量
  │   .delta    → delta = rawValue - lastTriggerValue  （默认：相对差值）
  │   .absolute → delta = rawValue                      （直接用绝对值，0~1映射）
  │
  ├─ [阶段3] 量化模式（GestureConfig.triggerMode）
  │   配置：怎么把 delta 转成输出
  │   .discrete:
  │     |delta| >= stepNorm ?
  │       是 → tickCount = floor(|delta| / stepNorm)
  │            direction = sign(delta) 经 directionRule 映射
  │            output = .tick(direction, count: tickCount)
  │            lastTriggerValue += tickCount * stepNorm * sign(delta)
  │       否 → 无输出
  │   .continuous:
  │     output = .continuous(delta * sensitivity)
  │     lastTriggerValue = rawValue
  │
  ├─ [阶段4] 输出传递（GestureOutput — 引擎→事件的数据合同）
  │   .tick(direction: Int, count: Int)   // 离散：值增减方向 + 跨了几个刻度
  │   .continuous(delta: Float)            // 连续：带符号的变化量（已 ×sensitivity）
  │
  ├─ [阶段5] 事件消费（EventConfig.consume(output:) → BoundaryResult）
  │   方向映射：directionRule 已在阶段3应用（positiveIncrease / positiveDecrease）
  │   执行方式 + 步长：
  │     mediaKey + .tick(dir, count)  → 发 count 次媒体键
  │     mediaKey + .continuous(delta) → 退化：delta>0 发1次up，<0 发1次down
  │     direct   + .tick(dir, count)  → current ± step * count → setVolume/Brightness
  │     direct   + .continuous(delta) → current + delta → setVolume/Brightness
  │   边界检测全封装在事件内部：
  │     执行前读 currentValue，执行后 clamp 到 [0,1]
  │     若到边界 → 返回 .hitBoundary（同时 postBoundaryKey 唤起 HUD）
  │     若已在边界且继续朝边界外 → 返回 .frozen（不执行）
  │     否则 → 返回 .normal
  │
  └─ [阶段6] 触觉反馈（HapticConfig — 在 GestureConfig 里，引擎层触发）
      触发时机（可配置开关 + 波形 + 次数 + 间隔）：
      .enter    → 进入 holding 时（默认：波形2 强click，1次）
      .tick     → 每次正常刻度调节后（默认：波形4 中tap，1次）
      .boundary → 到达边界时（默认：波形2 强click，2次，间隔50ms）
      .exit     → 退出 holding 时（新增，默认：关闭）
      引擎根据 BoundaryResult 决定触发哪个：
        .normal      → 触发 .tick
        .hitBoundary → 触发 .boundary
        .frozen      → 不触发（已冻住）
```

### 新增模型定义

#### 1. SignalSource（手势配置 — 阶段1）
```swift
/// 从 mt_touch_t 提取哪个字段作为控制信号
enum SignalSource: String, Codable, CaseIterable {
    case normY       // Y轴归一化坐标（默认）
    case normX       // X轴归一化坐标
    case size        // 接触面积
    case pressure    // Z轴压力

    /// 从 mt_touch_t 提取值
    func extract(from t: mt_touch_t) -> Float {
        switch self {
        case .normY:    return t.norm_y
        case .normX:    return t.norm_x
        case .size:     return t.size
        case .pressure: return t.zPressure
        }
    }

    var displayName: String { ... }
}
```

#### 2. TransformMode（手势配置 — 阶段2）
```swift
/// 信号变换方式
enum TransformMode: String, Codable, CaseIterable {
    case delta       // 相对于上次触发点的差值（默认）
    case absolute    // 直接用绝对值（0~1映射到目标值）
}
```

#### 3. TriggerMode（手势配置 — 阶段3）
```swift
/// 量化模式
enum TriggerMode: String, Codable, CaseIterable {
    case discrete    // 离散刻度：每达到 stepNorm 触发一次
    case continuous  // 连续比例：delta × sensitivity 直接映射
}
```

#### 4. GestureOutput（引擎→事件的数据合同 — 阶段4）
```swift
/// 手势引擎传递给事件的统一输出类型
enum GestureOutput {
    /// 离散刻度：direction=±1（已应用 directionRule），count=本次跨了几个刻度
    case tick(direction: Int, count: Int)
    /// 连续比例：带符号的变化量（已 ×sensitivity，可直接加减到系统值）
    case continuous(delta: Float)
}
```

#### 5. BoundaryResult（事件→引擎的反馈 — 阶段5）
```swift
/// 事件消费结果，告诉引擎发生了什么（用于决定震动）
enum BoundaryResult {
    case normal       // 正常调节了
    case hitBoundary  // 到达边界，已发 HUD
    case frozen       // 在边界冻结中，未执行
}
```

#### 6. HapticEvent（手势配置 — 阶段6）
```swift
/// 单个震动事件配置
struct HapticEvent: Codable, Equatable {
    var enabled: Bool        // 是否启用
    var waveform: Int32      // 波形 ID（1~16）
    var count: Int           // 发几次（默认 1）
    var intervalUs: Int32    // 多次之间的间隔（微秒，默认 50000 = 50ms）

    static let enter    = HapticEvent(enabled: true,  waveform: 2, count: 1, intervalUs: 0)
    static let tick     = HapticEvent(enabled: true,  waveform: 4, count: 1, intervalUs: 0)
    static let boundary = HapticEvent(enabled: true,  waveform: 2, count: 2, intervalUs: 50000)
    static let exit     = HapticEvent(enabled: false, waveform: 4, count: 1, intervalUs: 0)
}
```

### 配置模型变更

#### GestureConfig（新增 5 个字段，废弃 4 个 haptic 字段）
```swift
public struct GestureConfig: Codable, Identifiable, Equatable, Hashable {
    // --- 现有（不变）---
    public let id: UUID
    public var name: String
    public var regionID: UUID
    public var eventID: UUID
    // 第一次轻点
    public var tapMaxDuration: Double
    public var tapMaxDrift: Float
    // 两次轻点衔接
    public var tapMaxGap: Double
    // 第二次轻点保持
    public var holdMinDuration: Double
    // 鼠标
    public var disassociateMouse: Bool

    // --- 新增：信号处理管线 ---
    public var signalSource: SignalSource        // 默认 .normY
    public var transformMode: TransformMode      // 默认 .delta
    public var triggerMode: TriggerMode          // 默认 .discrete
    public var stepNorm: Float                   // 原 slideStepNorm 改名（默认 0.02）
    public var sensitivity: Float                // 连续模式灵敏度（默认 1.0，范围 0.1~10.0）

    // --- 新增：结构化震动配置（替代原 4 个散落字段）---
    public var hapticEnter: HapticEvent
    public var hapticTick: HapticEvent
    public var hapticBoundary: HapticEvent
    public var hapticExit: HapticEvent

    // --- 废弃（迁移到 HapticEvent）---
    // public var hapticEnter: Int32       → hapticEnter.waveform
    // public var hapticTick: Int32        → hapticTick.waveform
    // public var hapticBoundary: Int32    → hapticBoundary.waveform
    // public var boundaryHapticInterval   → hapticBoundary.intervalUs
}
```

#### EventConfig（新增 consume 方法，废弃 perform/postBoundaryKey）
```swift
public struct EventConfig: Codable, Identifiable, Equatable, Hashable {
    // --- 现有（不变）---
    public let id: UUID
    public var name: String
    public var actionType: ActionType
    public var step: Float
    public var boundaryThreshold: Float
    public var directionRule: DirectionRule    // 语义改为 positiveIncrease/positiveDecrease
    public var executionMethod: ExecutionMethod

    // --- 新增：消费管线输出 ---
    /// 消费手势输出，返回边界结果
    /// 方向映射在此方法内部完成
    public func consume(output: GestureOutput) -> BoundaryResult {
        // 1. 方向映射
        // 2. 边界预检（frozen 判定）
        // 3. 执行调节（mediaKey / direct）
        // 4. 边界后检（hitBoundary 判定 + HUD 唤起）
        // 5. 返回 BoundaryResult
    }

    // --- 废弃 ---
    // public func perform(direction: Int)       → 被 consume 替代
    // public func postBoundaryKey()             → 合并进 consume
    // public func mapSlidingDirection(dy:)      → 合并进 consume（阶段3在引擎做）
}
```

#### DirectionRule 语义更新
```swift
// 旧（Y轴专用）：
//   .upIncrease  → 上滑(norm_y减小)=增加
//   .upDecrease  → 上滑=减少
// 新（信号源无关）：
//   .positiveIncrease → 信号增大=值增加（默认）
//   .positiveDecrease → 信号增大=值减少（取反）
// 对于 normY：信号增大=下滑，所以 positiveIncrease 等价于旧的 upIncrease
```

### 引擎 holding 分支重写

```swift
case .holding(let pathIdx, let startRaw, let lastTriggerVal, let ticks, let frozen, let startValue):
    if !fingerStillThere(pathIdx) {
        // 退出 holding → 触发 hapticExit（如果 enabled）
        triggerHaptic(gesture.hapticExit)
        associateMouse()
        state = .idle
    } else if frozen {
        // frozen 状态：检查是否反向滑动解冻
        let raw = gesture.signalSource.extract(from: f)
        let delta = raw - lastTriggerVal
        let unfreezeDir = startValue <= boundaryThreshold ? +1 : -1  // 朝边界内的方向
        if event.shouldUnfreeze(delta: delta, direction: unfreezeDir) {
            state = .holding(..., frozen: false, ...)
        }
    } else if let f = edgeFinger, f.pathIndex == pathIdx {
        // 1. 提取信号
        let raw = gesture.signalSource.extract(from: f)
        // 2. 变换
        let delta = gesture.transformMode == .delta
            ? raw - lastTriggerVal
            : raw
        // 3. 量化 → GestureOutput
        guard let output = quantize(delta: delta, gesture: gesture) else { break }
        // 4. 事件消费
        let result = event.consume(output: output)
        // 5. 触觉反馈（基于 result）
        switch result {
        case .normal:      triggerHaptic(gesture.hapticTick)
        case .hitBoundary: triggerHaptic(gesture.hapticBoundary)
        case .frozen:      break
        }
        // 6. 更状态
        let newLastTrigger = computeNewLastTrigger(...)
        state = .holding(pathIdx, startRaw, newLastTrigger, ticks+1,
                         frozen: result == .hitBoundary || result == .frozen,
                         startValue: startValue)
    }
```

### 震动执行改为非阻塞
```swift
// 旧：usleep(50ms) 阻塞整个引擎
// 新：用 DispatchQueue 异步发多次震动
private func triggerHaptic(_ h: HapticEvent) {
    guard h.enabled, deviceID != 0 else { return }
    if h.count <= 1 {
        mt_actuate(deviceID, h.waveform)
    } else {
        DispatchQueue.global(qos: .userInitiated).async {
            for i in 0..<h.count {
                mt_actuate(self.deviceID, h.waveform)
                if i < h.count - 1 {
                    usleep(UInt32(h.intervalUs))
                }
            }
        }
    }
}
```

### Codable 迁移策略
- 旧 JSON 缺 signalSource/transformMode/triggerMode/sensitivity → 默认值（.normY / .delta / .discrete / 1.0）
- 旧 JSON 有 hapticEnter(Int32) → 自动转为 HapticEvent(waveform: 旧值, enabled: true)
- 旧 JSON 有 slideStepNorm → 自动映射到 stepNorm
- directionRule 值不变（.upIncrease / .upDecrease 字符串保留兼容，内部语义升级）

### UI 变更

#### 手势 tab 新增卡片
- **「信号处理」卡片**（新增）：
  - 信号源 Picker（normY/normX/size/pressure）
  - 变换方式 Picker（delta/absolute）
  - 量化模式 Segmented（离散/连续）
  - 步进间距 Slider（离散模式显示，原 slideStepNorm）
  - 灵敏度 Slider（连续模式显示，0.1~10.0）
- **「触觉反馈」卡片**（重构）：
  - 4 行（enter/tick/boundary/exit），每行：
    - Toggle（启用/禁用）
    - Stepper（波形 ID 1~16）
    - Stepper（次数 1~5）
    - Slider（间隔 0~200ms，次数>1 时显示）
    - 单项 reset 按钮

#### 事件 tab 调整
- step 在 mediaKey 模式下显示为「系统档位，不可调」（灰色禁用）
- directionRule 文案改为「信号增大→值增加 / 信号增大→值减少」

## Timeline 可视化事件图编辑器（2026-08-01 新增概念设计）

### 用户想法提炼
「以某个状态事件为时间起点（如"进入holding"），在时间轴上直观地挂不同事件/逻辑节点，能够实现不同的反馈（震动/系统值/HUD）和不同的数据处理。」

本质：把当前「硬编码线性状态机 + 6阶段顺序管线」升级为**可配置的 Timeline 事件图**。

---

### 当前配置能到什么程度（v2 线性管线，已规划）

```
状态机（硬编码顺序：idle→firstTapDown→firstTapUp→secondTapDown→holding→idle）
  ↓ 某个状态进入时（如 holding）
  触发 6 阶段线性管线（信号源→变换→量化→输出→消费→震动）
```

**配置上限**：
- 可配置：信号源（4种）、变换方式（2种）、量化模式（2种）、方向取反、执行方式（2种）、步长、边界阈值、4个震动时机各自的波形/次数/间隔
- 不可配置：状态机顺序、每个状态能触发什么分支、"A 且 B 才触发 C"这种条件组合、多反馈并行（边调音量边改鼠标加速）

---

### Timeline 概念（v3，目标：把状态机+管线都配置化）

#### 1. 核心抽象

**Timeline = 起点（TriggerEvent）+ 时间偏移 + 多个 GraphNode 有向图**

```
TriggerEvent
  └── t=0ms  ──► [EnterNode: 执行初始化（记录startY/startValue/lockMouse）]
  └── t=50ms ──► [HapticNode: 波形2 1次]                          ← hapticEnter
  └── 每帧     ──► [SignalNode: 提取normY]
                        │
                        ▼
                  [TransformNode: delta]
                        │
                        ▼
                  [QuantizeNode: discrete, step=0.02]
                        │
                        ├── 有输出 ──► [BranchNode: 非边界？]
                        │                  │
                        │                  ├─ 是 ─► [ConsumeNode: +step, direct]
                        │                  │            │
                        │                  │            ▼
                        │                  │       [HapticNode: 波形4 1次]  ← hapticTick
                        │                  │
                        │                  └─ 否 ─► [BranchNode: 首次到边界？]
                        │                               │
                        │                               ├─ 是 ─► [HapticNode: 波形2 ×2间隔50ms] ← hapticBoundary
                        │                               │        │
                        │                               │        ▼
                        │                               │   [FreezeNode: 冻结直到反向]
                        │                               │
                        │                               └─ 否 ─► [DropNode: 丢弃]
                        │
                        └── 无输出 ──► [IdleNode: pass]
```

#### 2. TriggerEvent 类型（时间起点）
```swift
enum TriggerEvent: String, Codable, CaseIterable {
    case onEnterHolding       // 进入 holding（t=0 基准，最常用）
    case onEnterFirstTapDown  // 第一次轻点按下
    case onEnterSecondTapDown // 第二次轻点按下
    case onExitHolding        // 退出 holding（手指抬起）
    case onCooldown           // 进入冷却（超时/漂移过大）
    case onTick               // holding 期间每帧（最常用作数据管线起点）
    case onBoundary           // 刚到达边界时（与 Tick 分支独立）
}
```

每个 GestureConfig 可以挂多个 Timeline（如 onEnterHolding + onTick + onExitHolding 三条独立时间线）。

#### 3. GraphNode 类型（可在 Timeline 上拖放的积木块）

按功能分 6 大类：

| 类别 | Node 类型 | 输入 | 输出 | 配置项 |
|------|-----------|------|------|--------|
| **数据源** | SignalNode | 无（从当前帧读）| Float | source: normY/normX/size/pressure/velY/velX |
| | ValueNode | 无 | Float | constant: Float（写死一个数用于测试）|
| **数学/变换** | TransformNode | Float | Float | mode: delta(fromBaseline)/absolute/derivative(=速度)/integral(=累积位移) |
| | ScaleNode | Float | Float | multiplier(默认1.0) + offset(默认0) |
| | ClampNode | Float | Float | min + max |
| | AbsNode / SignNode | Float | Float | 绝对值 / 取符号(±1) |
| **量化/门控** | QuantizeNode | Float | Tick(direction,count) or nil | mode: discrete(stepNorm) / continuous(sensitivity) |
| | GateNode | Float→Bool | Float（pass or drop）| condition: >/>=/</<=/==/!=, threshold: Float |
| | DebounceNode | any | any | minIntervalMs（防抖）|
| **条件分支** | BranchNode | 上一步输出 | 两路输出（true/false）| predicate（见下表）|
| | SwitchNode | Int(索引) | N路输出 | cases: [Node] |
| **副作用/反馈** | ConsumeNode | Tick 或 Float | BoundaryResult | action(volume/brightness) + method(mediaKey/direct) + step |
| | HapticNode | 触发信号 | 无 | waveform + count + intervalUs + async(是否不阻塞) |
| | HUDNode | Float or () | 无 | mode: boundary(发边界媒体键) / custom(发指定键一次) |
| | MouseNode | () or Float | 无 | mode: lockPosition / accelerate(新系数) / click(type) |
| | FreezeNode | 触发信号 | 无 | unfreezeCondition: reverseDelta / timeoutMs |
| | NotifyNode | 任意 | 无 | label: String（回调 onStateChange 通知 UI）|
| **流控制** | SplitNode | 1入 | 2出（复制）| 并行两个分支（如调音量同时改鼠标加速）|
| | MergeNode | 2入 | 1出(相加) | mode: sum/max/min（多条分支结果合并）|
| | BaselineNode | Float | Float | 记录基线（比如 onEnterHolding 时的 norm_y）供后续 delta 用 |
| | StateNode | Read<Write> | 读写 | key: String（跨节点存储临时变量）|

**BranchNode.predicate（条件表达式语言，简化版）**：
```swift
enum Predicate: Codable {
    case atBoundary           // 当前事件值在边界（读 currentValue）
    case notAtBoundary
    case firstTime            // 第一次到这条路径（冻结判定用）
    case positive             // 上一步输出 > 0
    case negative
    case compare(Comparator, Float)  // > threshold 等
    case and(Predicate, Predicate)
    case or(Predicate, Predicate)
    case not(Predicate)
}
enum Comparator { case gt, gte, lt, lte, eq, neq }
```

#### 4. Node 的视觉呈现（UI）

```
┌─ SignalNode ─────────────────┐
│ 信号源              [normY ▾] │ ← 下拉选配置
│ 输出：Float                   │
└──────────────────────────────┘
           │  连线 drag & drop
           ▼
┌─ QuantizeNode ───────────────┐
│ 量化模式    [离散刻度  ● 连续] │ ← Segmented
│ 步长                 0.02  ⚙︎ │ ← 弹出面板
│ 多档补偿              [on  ✓] │ ← Toggle
│ 输出：Tick(direction, count)? │
└──────────────────────────────┘
          │              │
     有输出│         无输出│
          ▼              ▼
   ┌─ BranchNode ──┐   ┌─ IdleNode ─┐
   │ 非边界?        │   │ pass       │
   │ [ 是 ] [ 否 ]  │   └────────────┘
   └───┬────────┬───┘
       │        │
       ▼        ▼
   Consume  Haptic
```

- 左侧是 **Node 工具箱面板**（分组显示 Signal/Math/Gate/Feedback 等），拖到画布新增
- 画布上 Node 之间**拖线连接**（output port → input port，类型不匹配时禁用连线）
- 每个 Node 右上角有 ⚙︎ 按钮弹出配置面板（复杂的 Predicate 用文本表达式或树状编辑器）
- 画布底部有 **T=0 时间轴刻度**：
  - onEnterHolding 触发的节点显示 0ms/50ms/200ms 位置（可左右拖改延迟）
  - onTick 节点显示 "每帧"（无时间位置，绑定循环）
  - 同时间点多个节点从上到下显示执行顺序（可上下拖调整顺序）

#### 5. 执行引擎（伪代码）

```swift
final class TimelineRuntime {
    // 单个手势的运行时状态：每个 Timeline 一个 GraphEvaluator
    var evaluators: [TriggerEvent: GraphEvaluator] = [:]
    // 跨节点共享的临时状态存储
    var stateStore: [String: AnyCodable] = [:]

    func handle(_ event: TriggerEvent, frame: FrameContext) {
        guard let eval = evaluators[event] else { return }
        // 拓扑排序：按依赖顺序执行 Node
        for node in eval.topologicalOrder {
            let inputs = eval.readInputs(of: node, from: stateStore)
            let output = node.execute(inputs: inputs, context: frame, state: &stateStore)
            eval.writeOutput(node, output, to: &stateStore)
            // 副作用（Haptic/Consume 等）在这里实际执行
            if let sideEffect = node as? SideEffectNode {
                switch sideEffect {
                case let h as HapticNode:   triggerHaptic(h.config) // async 可选
                case let c as ConsumeNode:  _ = c.action(output) // return BoundaryResult 写入 state
                default: break
                }
            }
        }
    }
}
```

关键：**纯计算节点（Signal/Transform/Quantize/Branch）是纯函数，无副作用**，在每帧同步执行且可重复；**副作用节点（Haptic/Consume/Mouse）是 Effect，异步执行且可通过 async flag 决定是否阻塞。**

#### 6. 配置模型

```swift
// Timeline 配置：单个触发事件对应的节点图
struct TimelineConfig: Codable, Identifiable {
    let id: UUID
    var trigger: TriggerEvent
    var nodes: [NodeConfig]
    var edges: [Edge]            // from: nodeID.outputPort, to: nodeID.inputPort
    var entryNodeIDs: [UUID]     // 起点（无入边的 Node）
}

struct NodeConfig: Codable, Identifiable {
    let id: UUID
    var type: NodeType           // enum，区分上面 6 大类
    var config: AnyCodable       // 各 Node 自己的参数（SignalConfig/QuantizeConfig/...）
    var position: CGPoint        // 画布坐标（x=时间轴,y=垂直顺序）
    var title: String?           // 用户自命名（可选，如"调音量主管线"）
}

struct Edge: Codable, Hashable {
    var from: PortID             // nodeID + portName("output"/"true"/"false"...)
    var to: PortID
}

// 在 GestureConfig 里挂多条时间线
public struct GestureConfig: ... {
    public var timelines: [TimelineConfig]   // 新增，替代现有的信号源/变换/震动零散字段
    // ... 轻触识别相关参数保留（tapMaxDuration/tapMaxDrift/tapMaxGap/holdMinDuration）
}
```

#### 7. 向后兼容：旧配置自动迁移为 Timeline 图

```swift
// 旧 GestureConfig（v2 signalSource=nromY + transform=delta + quantize=discrete + haptics）
// → 自动生成 3 条 Timeline：

// Timeline 1: onEnterHolding
//   BaselineNode(record: "startNormY", signal: normY)
//   BaselineNode(record: "startValue", source: currentValue(event))
//   MouseNode(mode: lockPosition)
//   HapticNode(waveform: 2, count: 1)  ← hapticEnter
//   Branch(predicate: atBoundary) → HUDNode(mode: boundary)    ← postBoundaryKey

// Timeline 2: onTick（每帧）
//   SignalNode(normY)
//     → TransformNode(mode: delta, baseline: "startNormY" 或 lastTrigger 状态)
//     → QuantizeNode(mode: discrete, step: stepNorm, compensate: true)
//     → GateNode(hasOutput)
//       → Branch(predicate: notAtBoundary, usingStart: "startValue")
//         ├ true: ConsumeNode(action, method, step) → HapticNode(tick)
//         └ false: Branch(firstTimeAtBoundary)
//                  ├ true: HapticNode(waveform:2, count:2, interval:50ms) + FreezeNode(unfreeze: reverse)
//                  └ false: Drop
//
// Timeline 3: onExitHolding
//   MouseNode(mode: unlockPosition)
//   HapticNode(exit.enabled ? waveform4 : disabled)
```

用户打开旧配置 → 看到等价的 Timeline 图，可以把它当作"模板"，在此基础上改。

---

### 当前 v2 线性管线 vs v3 Timeline 能力对照

| 能力 | v2 线性管线（已规划）| v3 Timeline 图 |
|------|-------------------------|----------------|
| 信号源可选 | normY/normX/size/pressure | 同左，且可多 SignalNode 并行（如 normY + velY 融合）|
| 数学变换 | delta/absolute 二选一 | 可级联任意个（Scale + Clamp + Derivative 自由组合）|
| 量化模式 | discrete/continuous 二选一 | 同左，且可加 Debounce、加 Gate 做复杂门控 |
| 条件分支 | 硬编码 2 层 if（边界/首次）| BranchNode/SwitchNode 任意深度嵌套，表达式语言可编程 |
| 反馈类型 | haptic + consume + HUD | haptic + consume + HUD + mouse + notify + 自定义 |
| 反馈并行 | 只有 tick+consume 串行 | SplitNode 可分两路并行（调音量的同时改鼠标加速）|
| 跨帧状态 | startY/lastTickY/frozen 写死在状态机 | StateNode key-value 任意存储 |
| 多个触发时机 | 只有 holding 内部 | 6 种 TriggerEvent 各自独立时间线 |
| 冻结/解冻 | 单一规则（反向解冻）| FreezeNode 条件可自定义（反向/超时/二者同时）|
| UI 直观性 | 卡片 + Slider | 画布拖拽 + 连线 + 高亮执行路径（执行到哪哪个节点闪烁）|
| 代码安全 | 线性逻辑简单易审计 | 纯计算纯函数+副作用隔离，执行顺序拓扑排序，支持 dry-run 测试 |

---

### 分阶段实现路线图

节点画布 UI 技术选型：**路线 C（Graphaello 第三方库）**，放弃纯 SwiftUI Canvas 自绘。
理由：Graphaello 是 SwiftUI 原生语法，开箱即用连线/端口/命中/缩放，半天集成节省 3-5 天手写 Canvas 成本。

| 阶段 | 目标 | 交付物 | 工作量 | 状态 |
|------|------|--------|--------|------|
| **M1：v2 线性管线落地** | 先把 MEMO 6 阶段线性管线写完 | Pipeline.swift + Config 迁移 + 引擎重写 + 卡片 UI | 中等（1-2天）| **✓ 已完成**（2026-08-01，swift build + 22 tests 通过）|
| **M2：Timeline 数据模型** | 定义 TimelineConfig/NodeConfig/Edge/Predicate，写迁移器（v2 GestureConfig→3条Timeline图），含 dry-run 拓扑排序验证 | Models/Timeline.swift + 迁移测试 | 中等（1天）| 待办 |
| **M3：执行引擎** | TimelineRuntime + GraphEvaluator，纯计算/副作用隔离，先实现 M1 管线等价的 ~15 个核心节点 | TimelineRuntime.swift + 节点实现 + 单测 | 大（2-3天）| 待办 |
| **M4-C：Graphaello 画布 UI** | Package.swift 加 Graphaello 依赖 → 工具箱面板 → 节点 Port 映射 → 画布拖放连线 → Inspector 弹层 | Views/TimelineCanvas/ + SPM 依赖更新 | 中等（1-2天）| 待办 |
| **M5：高级节点** | Derivative/Integral 微积分类节点、SwitchNode 多分支、MergeNode 合并、Predicate 树状编辑器 | 新增节点类型 + PredicateEditor 视图 | 中等 | 待办 |
| **M6：调试工具** | dry-run 输入回放、执行路径节点闪烁、hover 查看每节点 I/O 值 | DebugMode + TimelineDebugView | 大 | 待办 |

---

### M1 交付清单（已完成，2026-08-01）
1. 新建 `Sources/GestureEngine/Models/Pipeline.swift`：SignalSource（normY/normX/size/pressure 从 mt_touch_t 提取）, TransformMode（delta/absolute）, TriggerMode（discrete/continuous）, GestureOutput（tick/direction+count / continuous+delta）, BoundaryResult（normal/hitBoundary/frozen）, HapticEvent（enabled/waveform/count/intervalUs）
2. 改 `GestureConfig.swift`：新增 signalSource/transformMode/triggerMode/stepNorm/sensitivity 5 字段 + hapticEnter/hapticTick/hapticBoundary/hapticExit 4 个 HapticEvent；旧 slideStepNorm → stepNorm 自动改名；旧 Int32 haptic* 波形 ID → 封装为 HapticEvent(enabled:true, waveform:旧值)；新字段缺失时用默认值
3. 改 `EventConfig.swift`：新增 `consume(output:)` 作为事件消费主入口，内部完成方向映射、边界预检（frozen→跳过）、执行调节（mediaKey 多次按键 / direct 精确加减）、边界后检（hitBoundary 判定 + HUD 唤起 postBoundaryKey）、返回 BoundaryResult；DirectionRule 从 Y 轴语义升级为信号源无关的 positiveIncrease / positiveDecrease，旧 JSON upIncrease/upDecrease 自动映射；旧 API perform/isAtBoundary/mapSlidingDirection/postBoundaryKey 标记 @available(*, deprecated)
4. 改 `GestureEngine.swift`：holding 分支重写为 6 阶段管线（信号提取→变换→量化→输出→消费→震动）；triggerHaptic 改为 DispatchQueue.global().async 非阻塞执行多次震动；frozen 状态下反向滑动（delta 符号与 unfreezeDir 一致）自动解冻；GestureState 新增 startRaw 字段存储进入 holding 时的原始信号值
5. 改 `SystemControl.swift`：删除 adjustVolume/adjustBrightness 死代码，保留 volumeUp/Down + setVolume/getVolume + brightnessUp/Down + setBrightness/getBrightness
6. 改 `GestureTabView.swift`：新增「信号处理」卡片（SignalSource Picker + TransformMode Picker + TriggerMode Segmented + stepNorm Slider（离散时显示）+ sensitivity Slider（连续时显示））；重构「触觉反馈」卡片为 4 行 HapticRow（enter/tick/boundary/exit），每行含 enabled Toggle + waveform Stepper + count Stepper + intervalUs Slider（count>1 时显示）+ 单项 reset
7. 改 `EventTabView.swift`：mediaKey 模式下 step Stepper 禁用（显示"系统档位"）；directionRule Picker 文案改为「信号增大→值增加 / 信号增大→值减少」
8. 改 `HapticWaveformReference.swift`：用途列动态读取 HapticEvent.waveform 匹配
9. 测试：swift build 通过；EventConfigTests consume 各种 output×method 组合 + ConfigMigrationTests slideStepNorm→stepNorm + RegionConfigTests，共 22 tests 全通过
10. 修复：ConfigMigrationTests 中 slideStepNorm 引用改为 stepNorm

## v1.1.0 架构变更（事件配置化重构）
- 手势/事件/区域三解耦：RegionConfig(矩形坐标) + EventConfig(动作+step+边界) + GestureConfig(regionID+eventID+触发参数+所有震动)
- 状态机从 leftState/rightState 改为 `[UUID: GestureState]` 字典，每帧遍历所有手势
- UI 从 2 栏变 4 栏一级 tab（手势/事件/区域/设置）+ 二级 tab 编辑模式（增删/重命名）
- config.json v1→v2 自动迁移，行为一致
- 模型文件在 `Sources/GestureEngine/Models/`，UI 组件在 `Sources/TouchpadGestures/Views/`
- 单元测试在 `Tests/GestureEngineTests/`（13 个测试）
- **2026-08-01 v1.1.0 release 已撤销**：代码未经验证不直接发布，执行了 `gh release delete v1.1.0 --yes --cleanup-tag`
- **下一步**：用户本地编译测试通过后，再重新打 tag + 发 release

### 导航架构完全重写（2026-08-01）
- **旧架构（已废弃）**：手动 NSWindow + NSHostingView 包 ConfigView → NavigationSplitView，不是 Scene 根视图
- **新架构**：严格按照官方文档——NavigationSplitView 作为 Settings scene 的根视图
  - `Settings { ConfigView().environmentObject(appDelegate) }`
  - 系统自动管理窗口样式、sidebar 透明模糊、窗口居中
  - `openSettings()` 用 `NSApp.sendAction(Selector(("showSettingsWindow:")))`
  - Reset All 按钮改用 `.toolbar { ToolbarItem(placement: .primaryAction) }`
  - 删除 settingsWindow 变量、NSTitlebarAccessoryViewController、NSHostingView、ResetAllTitlebarButton
- **二级 tab**：官方 `Tab(value:content:label:)` API，ForEach 动态生成
  - selection 绑定 UUID?，init 时设为首项，不生成随机值
  - 删除后 `.onChange(of: count)` 验证有效性

### ActionType 扩展（2026-08-01）
- 原 ActionType 过于简略（仅 volumeUp/volumeDown/brightnessUp/brightnessDown），需扩展为多字段组合
- **新增 EventConfig 字段**：
  1. `invertDirection: Bool` — 映射方向取反开关（上滑→减、下滑→加）
  2. `executionMethod: ExecutionMethod` — 执行方式枚举
     - `mediaKey`：模拟系统媒体键（带 HUD 反馈，递增/递减）
     - `direct`：直接调用 API（精确值控制，无 HUD，支持 step 精确累加）
  3. `actionTarget: ActionTarget` — 行为目标枚举（替代原 ActionType 的 4 项合一）
     - `systemVolume`：系统音量
     - `systemBrightness`：系统亮度
     - 预留：后续可扩展为 mouseScroll / keyPress / customShortcut 等
  4. `directionRule: DirectionRule` — 方向映射规则
     - `upIncrease`：上滑=增加，下滑=减少（默认）
     - `upDecrease`：上滑=减少，下滑=增加（取反）
     - 注：方向规则= invertDirection ? upDecrease : upIncrease，二选一存储即可
- **SystemControl 扩展**：
  - 现有 `volumeUp()/volumeDown()/brightnessUp()/brightnessDown()` = mediaKey 模式（NX_SYSDEFINED 事件）
  - 新增 `setVolume(_ value: Float)` / `setBrightness(_ value: Float)` = direct 模式（CoreAudio / IOKit 精确赋值）
  - 新增 `adjustVolume(by step: Float, method: ExecutionMethod)` / `adjustBrightness(by:method:)` 统一入口
- **UI 扩展（EventTabView）**：
  - 行为目标选择器（Picker：音量/亮度/预留项）
  - 方向映射 Toggle（"上滑增加" / "上滑减少" 或 Segmented Control）
  - 执行方式 Segmented（系统媒体键 HUD / 直接 API 精确值）
  - 步长 Slider（两种模式都用 step，但 direct 模式支持更细粒度）
  - 所有新增项带单项 reset 按钮
- **配置迁移**：旧 JSON 缺字段时
  - actionType volumeUp/brightnessUp → actionTarget=.systemVolume/.systemBrightness, directionRule=.upIncrease
  - actionType volumeDown/brightnessDown → actionTarget=.systemVolume/.systemBrightness, directionRule=.upDecrease
  - executionMethod 默认 `.mediaKey`（保持旧行为一致）
  - invertDirection 根据旧 actionType 推导（down 类型= true）
- **引擎逻辑**：GestureEngine 中 holding → adjust 分支
  - 根据 `event.executionMethod` 走 mediaKey 或 direct 分支
  - 根据 `event.directionRule` 把 dy 正负映射到 +step/-step
  - 边界检测统一用 `getVolume()/getBrightness()` 当前实际值判断

## 用户问题记录（2026-07-31）
### Q1: 一级 Tab 支不支持运行时增删？
- 一级 Tab 当前实现：SwiftUI 原生 TabView，4 个 tab **硬编码**在 ConfigView 里，**不支持运行时增删**
- SettingsTabView 是「软件设置」，和业务数据无关，一般不需要动态增删
- 如果要做运行时增删，需要把一级 Tab 也改成和二级 EditableTabBar 类似的数据驱动模式（但要区分「业务可配置 tab」和「固定功能 tab」）

### Q2: 二级 Tab 能不能也用一级 Tab 的样式（SwiftUI 原生 TabView 那种分段控制风格）？
- **最终方案（2026-07-31）**：一级和二级 Tab 提到同一行，互斥展开/折叠
  1. 同一行 HStack：左 = 一级 Tab，右 = 二级 Tab，再右 = 编辑菜单按钮
  2. 默认：一级展开（显示所有 4 个 tab），二级折叠（只显示当前项 + "⋯" 指示器）
  3. 点击折叠侧 → 展开它，另一侧折叠
  4. 折叠样式：TabView 只显示一个 tab + "⋯" 指示器告诉用户还有更多项
  5. 两者都用 TabView（液态玻璃效果），frame(height: 28) 只显示 tab 条
  6. 编辑菜单（≡ 编辑 Capsule）：新增/重命名/删除，重命名用 alert 弹窗
  7. 设置 tab 无二级 tab，隐藏二级 tab 条和编辑菜单
  8. 新增文件：`CollapsibleTabBar.swift` + `ConfigView.swift`（从 App.swift 提取）
  9. 子视图改为纯内容区：移除 tab 头，接受 selectedXxxID 为 @Binding
  10. add/delete/rename 逻辑移至 ConfigView
  11. ManagedTabHeader.swift 和 EditableTabBar.swift 保留未删除

## 项目目标
通过 Apple 私有 **MultitouchSupport.framework** 读取内置触控板的多点触摸结构化数据（96 字节/手指），识别「双击边缘 + 保持 + 垂直滑动」手势，最终做成菜单栏工具（SwiftUI）。

## 关键决策
- **2026-07-31 路线变更**：放弃「纯 IOKit HID + 自逆向 vendor-defined 报告」，改为复用 **MultitouchSupport.framework 私有框架**（参考 GitHub 项目 `MatMercer/mactic` 的成熟实现）。理由：
  - mactic 已在 M3 / macOS Sequoia 上验证跑通
  - 96 字节 `MTTouch` struct 布局完全公开，含 norm_x/norm_y/size/state/pathIndex 等全部关键字段
  - 绕开 ARM64e PAC 指针认证问题（dlopen/dlsym 动态加载）
- 不追求 App Store 兼容性
- 接受机型适配成本与私有 API 风险
- 非沙盒应用

## 技术路线（MultitouchSupport.framework）

### C 桥接层（`mt_bridge.c` / `mt_bridge.h`）
1. `dlopen` 打开 `/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport`
2. `dlsym` 解析 8 个关键符号：
   - 设备：`MTDeviceCreateList`、`MTRegisterContactFrameCallback`、`MTDeviceStart`、`MTDeviceStop`
   - 触觉：`MTActuatorCreateFromDeviceID`、`MTActuatorOpen`、`MTActuatorActuate`、`MTActuatorClose`
3. 设备发现 / deviceID 获取（两种方式，优先用 B）：
   - **方案 A**：从 `MTDevice` 结构体 **offset 64** 读 64-bit deviceID（部分机型/系统下 struct 首 256 字节几乎全 0，读不到）
   - **方案 B（推荐）**：IORegistry 枚举 `AppleMultitouchDevice` / `AppleMultitouchTrackpadHIDEventDriver` 匹配 `mt-device-id` 属性，按数组 index 匹配。接口：`mt_device_get_id_by_index(index)`。更稳，跨机型通用
4. 设备生命周期：MTDeviceCreateList 返回的 CFArray 持有所有 MTDevice 对象，不 CFRetain，数组被释放 → MTDevice 被释放 → MTRegisterContactFrameCallback 会 rc=1 失败！**不要提前释放数组！
   - 新 API：`mt_scan_devices_array(&opaque)` / mt_device_at_index(array, i) / mt_release_devices_array(array)`，不再 deprecated `mt_scan_devices`
5. 静音噪点：`MTDeviceStart` 前后临时重定向 stdout/stderr → `/dev/null`
6. 向 Swift 暴露最小 C API：见头 `mt_scan_devices_array / mt_device_at_index / mt_release_devices_array / mt_device_get_id_by_index / mt_start_touch / mt_stop_touch / mt_actuate / mt_device_dump_struct(诊断用)

### MTTouch struct（96 字节/手指，来自 mactic 逆向）
| 偏移 | 类型 | 字段 | 说明 |
|------|------|------|------|
| +0 | int32 | frame | 帧计数 |
| +16 | int32 | pathIndex | 手指追踪 ID（跨帧稳定） |
| +20 | int32 | state | 触摸阶段：0=none 1=start 2=hover 3=make 4=touch 5=press 6=tap 7=lift |
| +24 | int32 | fingerID | 手指分类 |
| +32 | float | norm_x | 归一化 X 0.0~1.0 |
| +36 | float | norm_y | 归一化 Y 0.0~1.0 |
| +40 | float | vel_x | 归一化速度 X |
| +44 | float | vel_y | 归一化速度 Y |
| +48 | float | size | 瞬时压力/接触面积（~0.3 轻触 → ~1.35 重按）|
| +56 | float | angle | 接触椭圆角度 rad |
| +60 | float | majorAxis | 接触长轴 mm |
| +64 | float | minorAxis | 接触短轴 mm |
| +72 | float | abs_x | 绝对 X mm |
| +92 | float | zPressure | Z 轴压力 ~0-1.54 |

### Swift 层
1. 导入 `mt_bridge.h`（SPM 通过 C target 的 publicHeadersPath 暴露）
2. 扫描设备 → 选第一个内置触控板 → 启动触摸回调
3. 回调打印：`frame / pathIndex / state / (norm_x, norm_y) / size / zPressure`
4. 下一步：手势状态机

## 已知风险
- 私有 API：任何 macOS 更新可能改 struct 偏移或函数签名
- `MTDevice` deviceID offset=64 仅在 mactic 的 M3/Sequoia 验证，**新机器请优先用 IORegistry `mt-device-id`**
- 需授予「输入监控」权限
- IORegistry 的 device 枚举顺序未必和 MTDeviceCreateList 的数组顺序一一对应（当前按 index 粗暴匹配；若有多个设备需靠属性比对进一步校准）

## 当前进度
- [x] 创建 SwiftPM 命令行工具骨架（`TrackpadHIDTool`）—— 作为 IOKit 历史探索，可保留做参考
- [x] 新建 `mt_bridge` C target + C 桥接层
- [x] 96 字节 mt_touch_t struct 布局 + _Static_assert 验证
- [x] dlopen/dlsym MultitouchSupport 动态加载，避开 PAC 问题
- [x] MTDevice struct dump 诊断（排查 offset=64 为何读 0）
- [x] IORegistry 方案读 deviceID（通过 mt-device-id 属性）
- [x] 修复 CFArray 生命周期：不再提前 CFRelease，保证 MTDevice 对象在 touch 回调注册时存活
- [x] 修复 MTRegisterContactFrameCallback / MTDeviceStart 返回值判断（mactic 确认返回 void，不检查）
- [x] 触摸帧回调跑通：能拿到 pathIndex / state / norm_x / norm_y / size / zPressure
- [x] actuate 触觉反馈 smoke test（waveform 2 = 强 click）
- [x] 手势状态机：右侧边缘双击保持（idle → firstTapDown → firstTapUp → secondTapDown → holding → idle）
- [x] 原地轻点位移检测（TAP_MAX_DRIFT = 0.05，滑动不误触发）
- [x] cooldown 状态（超时/位移过大后等手指离开才重新开始）
- [x] holding 状态上下滑动 → 刻度震动 + 音量/亮度调整（媒体键事件触发系统 HUD）
- [x] 边界检测：到达 0%或100%时触发强震动并冻结手势
- [x] SwiftUI 菜单栏 App（`TouchpadGestures`）+ NSWindow 配置界面
- [x] 参数持久化（Codable → ~/Library/Application Support/TouchpadGestures/config.json）
- [x] 移除 MTouchTool CLI，专注菜单栏 App

## 配置参数全集（GestureConfig）
按手势执行流程从上到下分组，全部暴露到设置窗口：
1. **触摸数据流**：frameRateLimit（帧处理限频 Hz，0=不限）/ touchSizeMin（接触面积下限）/ touchSizeMax（接触面积上限，防手掌误触发）
2. **第一次轻点**：edgeRightThreshold / edgeLeftThreshold / tapMaxDuration / tapMaxDrift
3. **两次轻点衔接**：tapMaxGap
4. **第二次轻点保持**：holdMinDuration / hapticEnter
5. **滑动调节**：volumeStepNorm / volumeStep / brightnessStepNorm / brightnessStep / hapticTick
6. **边界检测**：boundaryThreshold / hapticBoundary / boundaryHapticInterval
7. **鼠标控制**：disassociateMouse（开关）

## 面积过滤（防手掌误触发）
- 使用 `mt_touch_t.size` 字段（+48，瞬时接触面积/压力综合值：~0.3 轻 → ~1.35 重）
- 手指典型范围 0.3~0.8，手掌 >1.0
- `isSizeValid(t)` 判断 `size ∈ [touchSizeMin, touchSizeMax]`，默认 [0.1, 1.0]
- 在 `processEdge` 的 `edgeFinger` 选取和 `fingerStillThere` 判断中同时应用，确保进入和持续都过滤
- 两个参数暴露在「1. 触摸数据流」卡片：下限 0~0.5，上限 0.5~2.0

## 国际化（i18n）
- 使用 `L10n.tr(zh, en)` 内联函数，根据 `Locale.preferredLanguages` 判断系统语言（zh 开头=中文）
- 不依赖 .strings 文件加载机制（SwiftPM 可执行目标对 .lproj 支持有限）
- 覆盖范围：菜单项、窗口标题、所有 Section 标题、所有配置项标签、重置按钮 tooltip、确认弹窗
- 注意：方法名必须用 `tr` 不能用 `t`（`t` 在某些 SwiftUI 上下文中会触发编译错误）

## 设置窗口交互
- 顶部 TabView 双 tab：左「手势设置」、右「软件设置」
- 每个配置项末尾有单项重置按钮（`arrow.counterclockwise.circle` 图标，borderless，hover 显示 tooltip），点击直接恢复该项默认值，不弹窗
- **全局「重置全部」按钮上浮到标题栏层级**：用 `NSTitlebarAccessoryViewController` + `NSHostingView` 包装 `ResetAllTitlebarButton`，`layoutAttribute = .trailing` 放在标题栏右侧，两 tab 共享。点击触发 `appDelegate.showResetAllAlert`（@Published），alert 绑定在 ConfigView 根层级
- 默认配置常量 `defaultConfig = GestureConfig()` / `defaultAppSettings = AppSettings()` 定义在 App.swift 顶部
- 窗口标题：`window.titleVisibility = .visible` + `titlebarAppearsTransparent = false`，防止标题被内容挤压吞掉
- 窗口居中：`window.center()`（已足够，无需手动计算屏幕中心）
- 菜单栏点击「设置...」时窗口强制前置：`NSApp.activate(ignoringOtherApps: true)` + `makeKeyAndOrderFront` + `orderFrontRegardless`（accessory 应用必需 orderFrontRegardless 才能真正置前）

## 卡片式布局规范（Card 组件）
- 用 `Card<Content: View>` 组件替代 `Form + Section`
- Card 样式：`subheadline + semibold` 标题 + `spacing: 10`，内容区 `spacing: 8`，外层 `padding: 14`，背景 `RoundedRectangle(cornerRadius: 10, .continuous)` + `quaternary.opacity(0.55)` 浅灰填充
- 外层容器：`ScrollView { VStack(alignment: .leading, spacing: 12) { ... } }`，`padding(.horizontal, 16)` + `padding(.vertical, 12)`
- 手势设置 tab：8 张卡片（1~7 流程阶段 + 8.触觉波形对照）
- 软件设置 tab：4 张卡片（软件信息 / 触控板规格 / 启动 / 菜单栏图标）+ 底部固定版权声明（Divider 分隔，居中）
- 统一行视图：`toggleRow(_:isOn:reset:)` / `stepperRow(_:value:in:reset:)`（Int32 版本，与 GestureConfig 中 haptic* 字段类型一致）
- 禁用 `Form`：Form 的 GroupBox/insetGrouped 样式与 Card 视觉冲突，统一用 ScrollView + VStack + Card 自绘

## 触觉波形对照表（HapticWaveformReference）
- 位置：手势设置 tab 最底部第 8 张卡片
- 作用：列出所有已知 waveform ID（1~16）的触感描述，并实时标注当前项目中的使用位置
- 三列布局：ID（40pt）| 触感（150pt）| 本项目用途（自适应）
- 用途标签动态生成：根据 config.hapticEnter/hapticTick/hapticBoundary 匹配，显示「进入反馈 / 滑动刻度 / 边界震动」组合，无匹配显示 "—"
- 波形数据来源：mt_bridge.h 中 mactic 探测的有效值（1 弱click / 2 强click / 3 buzz / 4-6 轻/中/强 tap / 15-16 软/强重击）
- 用户修改波形 ID 后，对照表用途列实时更新，直观看到哪个波形用在哪里

## AppSettings（软件设置，独立持久化到 appsettings.json）
- `launchAtLogin`：开机自启动，通过 `osascript` 写入 System Events 登录项（兼容非 bundle 可执行文件；.app 用 Bundle.main.bundlePath，否则用 CommandLine.arguments[0]）
- `showInDock`：在 Dock 中显示，通过 `NSApp.setActivationPolicy(.regular/.accessory)` 动态切换（移除了 TransformProcessType，统一用 setActivationPolicy）
- `menuBarIcon`：菜单栏 SF Symbol 名称（默认 "hand.tap"）
- `menuBarIconSize`：菜单栏图标尺寸 point size（默认 14，范围 10~24）
- 菜单栏图标始终显示（不允许隐藏），通过 `applyMenuBarIcon()` 用 `NSImage.SymbolConfiguration(pointSize:weight:)` 重建
- App 图标：`applyAppIcon()` 用 hand.tap SF Symbol 生成 NSImage 设置 `NSApp.applicationIconImage`（非 bundle 环境无 Assets.xcassets）

## 软件设置 tab 排版规范
- 所有项统一 `HStack { Text(标签).frame(width:150, .leading); 控件; Spacer()或数值; resetButton }`
- Toggle 用 `labelsHidden()`，文字标签放前面固定 150 宽，与 Slider/TextField 项对齐
- Section 分组：软件信息 → 触控板规格 → 启动（自启动+Dock）→ 菜单栏图标（名称+尺寸+预览）
- 版权声明固定在窗口底部（ScrollView 外），Divider 分隔，居中显示，不随内容滚动

## 鼠标锁定实现（holding 期间光标不动）
- 进入 holding 时：`CGEvent(source: nil).location` 记录当前光标位置到 `lockedCursorPos`，再 `CGAssociateMouseAndMouseCursorPosition(0)` 解除关联
- **每帧 warp**：`processFrame` 末尾，若 `isAnyHolding()` 为真且 `mouseDisassociated`，调用 `CGWarpMouseCursorPosition(lockedCursorPos)` 把光标钉回原位
- 单纯 `CGAssociateMouseAndMouseCursorPosition(0)` 无效：它只解除移动事件与光标位置的关联，触控板 HID 输入仍会移动光标。必须配合每帧 warp
- 离开 holding 时：`CGAssociateMouseAndMouseCursorPosition(1)` 恢复关联
- 受 `config.disassociateMouse` 开关控制（默认 true）

## 亮度边界检测教训
- `IODisplayGetFloatParameter` 遍历所有 `IODisplayConnect` 取最后一个可能取到外接显示器，应取第一个成功读取的
- 刻度计数法（假设固定 16 档）不可靠：`getBrightness()` 返回值不准会导致起点错误
- 正确做法：每次调节前读取当前实际值，直接用 `<= boundaryThreshold` 或 `>= 1.0 - boundaryThreshold` 判断边界
- 若 `startValue <= boundaryThreshold`（API 失效或亮度本就为 0），跳过边界检测避免误判

## 边界 HUD 反馈（进入 holding 时唤起 HUD）
- **进入 holding 时（secondTapDown → holding 转换瞬间），如果当前值在边界，立即发送朝边界外的媒体键唤起 HUD**（值不变，仅让系统显示 HUD 指示框）
  - 上边界（值 >= 1.0 - threshold）：发送 up（如 volumeUp），值不变
  - 下边界（值 <= threshold）：发送 down（如 volumeDown），值不变
- 这样用户进入 holding 立刻看到 HUD，知道当前已在边界
- **holding 状态滑动时的 atBoundary 分支**：
  - 如果进入时已在边界（`enterAtBoundary`），不再重复发送媒体键（HUD 已在进入时唤起），只做强震动+冻结
  - 如果进入时不在边界（滑动过程中才到达边界），发送媒体键唤起 HUD + 强震动 + 冻结
- `enterAtBoundary` 判断：`startValue >= 1.0 - boundaryThreshold || startValue <= boundaryThreshold`
- 完整行为矩阵：
  - 进入时在边界 + 朝边界外滑动 → 强震动 + 冻结（HUD 已在进入时唤起）
  - 进入时在边界 + 朝边界内滑动 → 正常调节 + HUD（正常发送媒体键）
  - 进入时不在边界 + 朝边界外滑动到达边界 → 发送媒体键 + 强震动 + 冻结
  - 进入时不在边界 + 朝边界内滑动 → 正常调节 + HUD

## App 图标与 Dock 显示
- **调用顺序关键**：`setActivationPolicy` 必须在 `applyAppIcon` 之前调用，否则 policy 切换会重置 app icon
- `applicationDidFinishLaunching` 中：先 `NSApp.setActivationPolicy(...)`，再 `applyAppIcon()`
- `applyDockPolicy` 中：切换 policy 后必须重新调用 `applyAppIcon()`，否则 Dock 图标被重置为默认
- **图标着色**：`applyAppIcon` 通过 `lockFocus` + `sourceAtop` 合成给 SF Symbol 填充自定义颜色
  - SF Symbol 默认是模板（isTemplate=true），系统会按上下文自动着色覆盖
  - 必须设 `isTemplate = false` 才能保留自定义颜色
  - 着色流程：创建 128×128 NSImage → lockFocus → draw 符号（sourceOver）→ 设当前色 → NSRect.fill(.sourceAtop) → unlockFocus → isTemplate=false → applicationIconImage
- `NSApp.applicationIconImage` 覆盖 Dock 图标、Mission Control 窗口缩略图图标、Cmd+Tab 图标
- 非 bundle 环境（swift run）没有 Assets.xcassets，必须运行时用 SF Symbol 生成图标

## App 图标颜色自定义（AppSettings 新增）
- 字段：`appIconColorRed` / `appIconColorGreen` / `appIconColorBlue`（Double 0~1，默认全 1 = 白色）
- 持久化在 appsettings.json
- UI 在软件设置 tab 的「App 图标」卡片：
  - 10 个预设色板（白/黑/红/橙/黄/绿/青/蓝/紫/粉），点击直接设置 RGB
  - RGB 三个 Slider 自定义颜色，实时预览
  - 单项重置按钮恢复白色
  - 预览用 SwiftUI Image + .foregroundStyle(Color(nsColor:)) 显示当前颜色的 hand.tap

## 配置默认值管理（用户自定义默认）
- 文件路径：`~/Library/Application Support/TouchpadGestures/default.json`
- `GestureConfig.saveAsDefault()`：当前配置写入 default.json
- `GestureConfig.loadDefault()`：优先从 default.json 加载，不存在则返回 GestureConfig()
- `GestureConfig.clearUserDefault()`：删除 default.json
- UI 在软件设置 tab 的「配置默认值」卡片：
  - 「保存当前为默认」按钮：调用 `config.saveAsDefault()`，弹"已保存"提示
  - 「恢复代码默认值」按钮（红色 tint）：弹确认 → `clearUserDefault()` + `config = GestureConfig()`
- 标题栏「重置全部」逻辑改为 `config = GestureConfig.loadDefault()`（优先用户默认，否则代码默认）
- 这样用户可以把调好的配置存为默认，之后重置全部就回到这个配置，而不是代码默认值

## 参考
- [MatMercer/mactic](https://github.com/MatMercer/mactic) — 本项目 C 桥接层的直接蓝本
- [implementation.md](https://github.com/MatMercer/mactic/blob/main/docs/implementation.md) — MTTouch struct 完整字段与未来修复指南

## 运行方式
```bash
cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad"
swift run TouchpadGestures
```
菜单栏 App，点击菜单栏图标可打开配置界面。首次运行在「系统设置 → 隐私与安全性 → 输入监控」里授予 Terminal 权限。

## 分发构建（scripts/build_app.sh）
- `swift build -c release` 编译 release 版本
- 组装 .app bundle：Contents/MacOS/可执行文件 + Contents/Info.plist + Contents/Resources/AppIcon.icns + Contents/PkgInfo
- Info.plist 关键字段：
  - `CFBundleIdentifier` = com.zekiwithcat.TouchpadGestures
  - `LSUIElement` = true（菜单栏 App，不在 Dock 显示）
  - `LSMinimumSystemVersion` = 12.0
  - `NSInputMonitoringUsageDescription` = 输入监控权限说明
- 图标生成：Swift 脚本渲染 SF Symbol 'hand.tap' 到 1024x1024 PNG（白色填充），sips 生成多倍率 iconset，iconutil 转 icns
- **Ad-hoc 签名**：`codesign --force --deep --sign -` 消除 "已损坏" 提示
  - 未签名 app 从网络下载会被 Gatekeeper 加 com.apple.quarantine 属性，显示 "已损坏"
  - ad-hoc 签名后仍会提示 "无法验证开发者"，用户需右键打开或执行 `xattr -cr`
- 打包：`ditto -c -k --keepParent` 生成 zip

## GitHub Release
- 仓库：https://github.com/Zekilou/mac_touchpad.git
- Release v1.0.0：https://github.com/Zekilou/mac_touchpad/releases/tag/v1.0.0
- 资源：TouchpadGestures.zip（含 .app bundle）
- 仓库描述：「macOS 菜单栏 App：双击触控板边缘 + 保持 + 上下滑动调节音量/亮度，带刻度震动反馈。基于 MultitouchSupport 私有框架。」
- README 含：功能、系统要求、下载安装、使用方法、手势流程图、配置参数表、技术实现、致谢 mactic、风险声明
- LICENSE：MIT
- Release notes 明确告知用户：解压后执行 `xattr -cr /path/to/TouchpadGestures.app` 清除 quarantine 属性

## 用户首次打开流程（重要）
1. 下载 TouchpadGestures.zip 解压
2. 若提示 "已损坏" 或 "无法验证开发者"：
   - 方法一：终端执行 `xattr -cr /path/to/TouchpadGestures.app`
   - 方法二：右键 → 打开（绕过 Gatekeeper）
3. 拖入「应用程序」文件夹
4. 首次运行在「系统设置 → 隐私与安全性 → 输入监控」授予权限
