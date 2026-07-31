# 事件配置化重构设计

**版本**：v1.1.0
**日期**：2026-07-31
**状态**：待实现

## 目标

将当前写死的"左边缘→亮度、右边缘→音量"重构为「手势 / 事件 / 区域」三解耦的配置化架构，使新增事件、新增手势、新增区域都成为 UI 配置操作（新动作类型仍需加代码）。UI 从 2 栏变 4 栏一级 tab，手势/事件/区域各用二级 tab + 编辑模式管理。

## 背景与现状

当前 `GestureConfig` 是扁平结构，混合了触发参数、动作参数、震动参数。`GestureEngine` 用 `leftState`/`rightState` 两个固定状态机处理左右边缘，动作类型直接 `switch side` 硬编码。无法在不改代码的情况下新增手势或重新绑定动作。

## 数据模型

### 区域（RegionConfig）

```swift
struct RegionConfig: Codable, Identifiable {
    let id: UUID
    var name: String      // "左边缘"/"右边缘"/自定义
    var xMin: Float       // 归一化 0~1
    var xMax: Float       // 归一化 0~1
    var yMin: Float       // 归一化 0~1
    var yMax: Float       // 归一化 0~1
}
```

默认 2 个区域：
- 左边缘：xMin=0, xMax=0.2, yMin=0, yMax=1
- 右边缘：xMin=0.8, xMax=1, yMin=0, yMax=1

区域判断：
```swift
func isInRegion(_ r: RegionConfig, x: Float, y: Float) -> Bool {
    x >= r.xMin && x <= r.xMax && y >= r.yMin && y <= r.yMax
}
```

### 事件（EventConfig）

事件 = 数据处理 + 改变系统值 + 边界判断。震动不归事件。

```swift
enum ActionType: String, Codable, CaseIterable {
    case volume
    case brightness
}

struct EventConfig: Codable, Identifiable {
    let id: UUID
    var name: String              // "音量"/"亮度"，可重命名
    var actionType: ActionType    // .volume / .brightness
    var step: Float               // 每次变化量（原 volumeStep/brightnessStep）
    var boundaryThreshold: Float  // 边界判定阈值（归事件，因边界是系统值概念）
}
```

事件执行方法：
```swift
extension EventConfig {
    func currentValue() -> Float           // volume→getVolume, brightness→getBrightness
    func isAtBoundary(direction: Int) -> Bool  // direction>0=增大方向, <0=减小方向
    func perform(direction: Int)            // volume→volumeUp/Down, brightness→brightnessUp/Down
}
```

### 手势（GestureConfig）

手势 = 触发识别 + 所有震动反馈 + 滑动刻度 + 鼠标。持有 regionID 和 eventID 绑定。

```swift
struct GestureConfig: Codable, Identifiable {
    let id: UUID
    var name: String                  // "左侧"/"右侧"，可重命名
    var regionID: UUID                // 绑定的区域
    var eventID: UUID                 // 绑定的事件
    // 轻点/保持
    var tapMaxDuration: Double
    var tapMaxDrift: Float
    var tapMaxGap: Double
    var holdMinDuration: Double
    // 滑动
    var slideStepNorm: Float          // 原 volumeStepNorm/brightnessStepNorm 统一
    // 鼠标
    var disassociateMouse: Bool
    // 所有震动（归手势）
    var hapticEnter: Int32
    var hapticTick: Int32
    var hapticBoundary: Int32
    var boundaryHapticInterval: Int32
}
```

### 全局设置（GlobalSettings）

```swift
struct GlobalSettings: Codable {
    var frameRateLimit: Double
    var touchSizeMin: Float
    var touchSizeMax: Float
}
```

### 持久化与迁移

单文件 `config.json` 存：
```json
{
  "version": 2,
  "global": { ... },
  "regions": [ ... ],
  "gestures": [ ... ],
  "events": [ ... ]
}
```

读取时若没有 `regions`/`gestures`/`events` 键（v1 旧格式，version 缺失或=1），自动迁移：
- 从 `edgeLeftThreshold` 生成左边缘区域，`edgeRightThreshold` 生成右边缘区域
- 生成 2 个手势（左侧绑定亮度事件，右侧绑定音量事件）
- 生成 2 个事件（音量 step=volumeStep，亮度 step=brightnessStep）
- `boundaryThreshold`/`hapticEnter`/`hapticTick`/`hapticBoundary`/`boundaryHapticInterval` 从旧值复制到对应手势
- `slideStepNorm` 从 `volumeStepNorm`/`brightnessStepNorm` 复制到对应手势
- 迁移后立即保存为新格式

`default.json`（用户自定义默认）同样升级为 v2 格式，`loadDefault()` / `saveAsDefault()` / `clearUserDefault()` 逻辑不变。

## 状态机与运行时

### 状态存储

```swift
private var states: [UUID: GestureState] = [:]  // key = gesture.id
```

### 每帧处理

```swift
func processFrame(touches: [mt_touch_t]) {
    // 1. 帧限频（全局）
    // 2. 遍历所有手势配置
    for gesture in config.gestures {
        guard let region = config.regions.first(where: { $0.id == gesture.regionID }),
              let event = config.events.first(where: { $0.id == gesture.eventID }) else { continue }
        let state = states[gesture.id] ?? .idle
        processGesture(gesture, region, event, state: &states[gesture.id]!, touches: touches, now: now)
    }
    // 3. 鼠标锁定：任意手势在 holding 即锁定
}
```

### 状态机逻辑

状态枚举与现版相同（idle/firstTapDown/firstTapUp/secondTapDown/holding/cooldown），但：
- `edgeFinger` 查找用 `isInRegion(region, x:, y:)` 替代 `isInEdge(side, x:)`
- 参数从 `gesture` 读取（tapMaxDuration/tapMaxDrift/tapMaxGap/holdMinDuration/slideStepNorm/disassociateMouse）
- 进入 holding / 触发刻度时通过 `eventID` 查 `EventConfig`
- 边界交互：手势驱动震动，事件驱动判断
  - 滑动一格 → 算 direction → 问事件 `isAtBoundary(direction)`
  - 到边界 → 手势触发 `hapticBoundary` × 2 + 冻结
  - 未到 → 事件 `perform(direction)` → 手势触发 `hapticTick`
  - 进入 holding 时若事件已在边界 → 手势触发 `hapticEnter` + 事件发送一次朝边界外的媒体键唤起 HUD

### 冲突处理

**冷处理**（不主动处理）：
- 同区域多手势：各自独立状态机，不互斥。可能出现多个手势同时 holding。
- 同事件多手势绑定：允许。多个手势可能同时调用同一事件改值。
- 依赖用户配置避免冲突。未来若有问题再加互斥逻辑。

### 鼠标锁定

与现版一致：任意手势在 holding 即锁定光标，所有 holding 退出才解锁。`mouseDisassociated` + `lockedCursorPos` + 每帧 warp 逻辑保留。

## UI 结构

### 一级 tab（4 栏，纯文字标签）

```
[手势] [事件] [区域] [设置]
```

### 手势 tab

二级 tab + 编辑模式：
```
[左侧] [右侧]                    [编辑]
├─ Card: 绑定事件
│    下拉: [音量 ▼]  (选 eventID，显示事件名)
├─ Card: 触发区域
│    下拉: [左边缘 ▼]  (选 regionID，显示区域名)
├─ Card: 第一次轻点（tapMaxDuration + tapMaxDrift）
├─ Card: 两次轻点衔接（tapMaxGap）
├─ Card: 第二次轻点保持（holdMinDuration + hapticEnter）
├─ Card: 滑动调节（slideStepNorm + hapticTick）
├─ Card: 边界震动（hapticBoundary + boundaryHapticInterval）
├─ Card: 鼠标控制（disassociateMouse）
└─ Card: 触觉波形对照（只读参考表）
```

### 事件 tab

二级 tab + 编辑模式：
```
[音量] [亮度]                    [编辑]
├─ Card: 动作类型
│    SegmentedControl: [音量] [亮度]
├─ Card: 调节参数
│    step Slider
└─ Card: 边界检测
     boundaryThreshold Slider
```

### 区域 tab

二级 tab + 编辑模式：
```
[左边缘] [右边缘]                [编辑]
├─ Card: 名称（TextField）
├─ Card: 矩形坐标
│    xMin Slider 0~1 + 数值
│    xMax Slider 0~1 + 数值
│    yMin Slider 0~1 + 数值
│    yMax Slider 0~1 + 数值
└─ Card: 可视化预览
     [2:1 触控板示意图，半透明色块显示当前矩形位置和大小]
```

可视化预览：2:1 比例矩形框代表触控板，内部半透明色块显示当前区域，拖动 Slider 实时更新。

### 编辑模式交互（手势/事件/区域通用）

- 右上角「编辑」按钮切换编辑模式
- 编辑模式下：tab 标题出现「×」删除按钮（hover 显示），tab 条末尾出现「+」新增，tab 标题可双击重命名，底部出现「完成」按钮退出
- 新增项复制当前项参数，绑定关系设为第一个可用项
- 至少保留 1 项（删除最后一个时禁用「×」）
- 删除事件前检查：若有手势绑定它，弹确认「N 个手势将解绑，继续？」，确认后这些手势的 eventID 设为剩余第一个事件
- 删除区域前检查：若有手势绑定它，弹确认「N 个手势将解绑，继续？」，确认后这些手势的 regionID 设为剩余第一个区域

### 设置 tab

```
软件信息 / 触控板规格 / 启动 / 菜单栏图标 / App 图标 / 配置默认值
+ Card: 触摸数据流（frameRateLimit + touchSizeMin/Max，全局）
+ 版权声明（底部固定）
```

### 标题栏「重置全部」

重置到 `loadDefault()`（用户自定义默认），含 global + regions + gestures + events 四部分。

### 窗口尺寸

680×820（4 个 tab + 二级内容 + 编辑按钮）。

## 文件拆分

控制单文件 ≤300 行：
- `Sources/GestureEngine/Models/RegionConfig.swift` — 区域结构
- `Sources/GestureEngine/Models/EventConfig.swift` — 事件结构 + ActionType + 执行方法
- `Sources/GestureEngine/Models/GestureConfig.swift` — 手势结构
- `Sources/GestureEngine/Models/GlobalSettings.swift` — 全局设置
- `Sources/GestureEngine/Models/ConfigStore.swift` — 持久化 + 迁移 + 加载/保存
- `Sources/GestureEngine/Models/AppConfig.swift` — 顶层聚合（global + regions + gestures + events）
- `Sources/GestureEngine/GestureState.swift` — 状态枚举（从 GestureEngine 抽出）
- `Sources/GestureEngine/GestureEngine.swift` — 状态机（字典版）
- `Sources/GestureEngine/SystemControl.swift` — 系统控制（保留）
- `Sources/TouchpadGestures/App.swift` — 主 App + AppDelegate
- `Sources/TouchpadGestures/Views/` — UI 组件拆分（ConfigView / GestureTabView / EventTabView / RegionTabView / SettingsTabView / Card / HapticWaveformReference / EditableTabBar）

## 向后兼容

- v1 的 `config.json` 自动迁移到 v2，用户无感升级
- v1 的 `default.json`（若存在）也自动迁移
- 迁移后行为与 v1 一致：左边缘→亮度、右边缘→音量

## 不在本次范围

- 新动作类型（如媒体控制、窗口管理）— 需 ActionType 加 case
- 冲突互斥逻辑 — 冷处理
- 区域的圆形/多边形支持 — 仅矩形
- 区域的可视化拖拽编辑 — 仅 Slider + 预览
