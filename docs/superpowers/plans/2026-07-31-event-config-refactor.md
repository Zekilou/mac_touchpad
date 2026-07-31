# 事件配置化重构 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将写死的"左→亮度、右→音量"重构为「手势/事件/区域」三解耦配置化架构，UI 从 2 栏变 4 栏一级 tab + 二级 tab 编辑模式。

**Architecture:** 配置驱动。RegionConfig(xMin/xMax/yMin/yMax) 矩形对象 + EventConfig(actionType+step+boundaryThreshold) + GestureConfig(regionID+eventID+触发参数+所有震动) + GlobalSettings。状态机用 `[UUID: GestureState]` 字典管理，每帧遍历手势。v1 config.json 自动迁移。

**Tech Stack:** Swift 5.9 / SwiftUI / AppKit / MultitouchSupport.framework (私有) / SwiftPM

**Spec:** `docs/superpowers/specs/2026-07-31-event-config-refactor-design.md`

---

## 文件结构

**创建：**
- `Sources/GestureEngine/Models/RegionConfig.swift` — 区域矩形对象 + 判断方法
- `Sources/GestureEngine/Models/EventConfig.swift` — 事件 + ActionType + 执行方法
- `Sources/GestureEngine/Models/GestureConfig.swift` — 手势（新版，替换旧文件）
- `Sources/GestureEngine/Models/GlobalSettings.swift` — 全局设置
- `Sources/GestureEngine/Models/AppConfig.swift` — 顶层聚合
- `Sources/GestureEngine/Models/ConfigStore.swift` — 持久化 + 迁移
- `Sources/GestureEngine/GestureState.swift` — 状态枚举（抽出）
- `Sources/TouchpadGestures/Views/Card.swift` — 卡片组件
- `Sources/TouchpadGestures/Views/HapticWaveformReference.swift` — 波形对照
- `Sources/TouchpadGestures/Views/EditableTabBar.swift` — 可编辑二级 tab
- `Sources/TouchpadGestures/Views/RegionTabView.swift` — 区域 tab
- `Sources/TouchpadGestures/Views/EventTabView.swift` — 事件 tab
- `Sources/TouchpadGestures/Views/GestureTabView.swift` — 手势 tab
- `Sources/TouchpadGestures/Views/SettingsTabView.swift` — 设置 tab
- `Tests/GestureEngineTests/RegionConfigTests.swift`
- `Tests/GestureEngineTests/EventConfigTests.swift`
- `Tests/GestureEngineTests/ConfigMigrationTests.swift`

**修改：**
- `Sources/GestureEngine/GestureEngine.swift` — 重写状态机（字典版）
- `Sources/GestureEngine/SystemControl.swift` — 保留，加 `currentValue(for:)` 辅助
- `Sources/TouchpadGestures/App.swift` — AppDelegate 适配新配置，ConfigView 重写为 4 tab
- `Package.swift` — 加 testTarget

**删除：**
- `Sources/GestureEngine/GestureConfig.swift` — 旧扁平配置（被 Models/ 替换）

---

## Task 1: 创建 RegionConfig 模型

**Files:**
- Create: `Sources/GestureEngine/Models/RegionConfig.swift`
- Create: `Tests/GestureEngineTests/RegionConfigTests.swift`
- Modify: `Package.swift` (加 testTarget)

- [ ] **Step 1: 在 Package.swift 加 testTarget**

修改 `Package.swift`，在 `targets` 数组末尾、`GestureEngine` target 之后加：

```swift
        .testTarget(
            name: "GestureEngineTests",
            dependencies: ["GestureEngine"],
            path: "Tests/GestureEngineTests"
        ),
```

- [ ] **Step 2: 创建 RegionConfig.swift**

创建 `Sources/GestureEngine/Models/RegionConfig.swift`：

```swift
import Foundation

/// 手势生效区域（矩形对象，归一化坐标 0~1）
/// @ai: do not change field names (Codable 合同)
public struct RegionConfig: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var xMin: Float
    public var xMax: Float
    public var yMin: Float
    public var yMax: Float

    public init(id: UUID = UUID(), name: String, xMin: Float, xMax: Float, yMin: Float, yMax: Float) {
        self.id = id
        self.name = name
        self.xMin = xMin
        self.xMax = xMax
        self.yMin = yMin
        self.yMax = yMax
    }

    /// 判断归一化坐标是否在区域内
    public func contains(x: Float, y: Float) -> Bool {
        x >= xMin && x <= xMax && y >= yMin && y <= yMax
    }

    /// 默认左边缘区域
    public static let defaultLeft = RegionConfig(
        name: "左边缘", xMin: 0, xMax: 0.2, yMin: 0, yMax: 1)

    /// 默认右边缘区域
    public static let defaultRight = RegionConfig(
        name: "右边缘", xMin: 0.8, xMax: 1, yMin: 0, yMax: 1)
}
```

- [ ] **Step 3: 创建测试**

创建 `Tests/GestureEngineTests/RegionConfigTests.swift`：

```swift
import XCTest
@testable import GestureEngine

final class RegionConfigTests: XCTestCase {
    func testContains_pointInside() {
        let r = RegionConfig(name: "test", xMin: 0.1, xMax: 0.3, yMin: 0.2, yMax: 0.8)
        XCTAssertTrue(r.contains(x: 0.2, y: 0.5))
    }

    func testContains_pointOutside() {
        let r = RegionConfig(name: "test", xMin: 0.1, xMax: 0.3, yMin: 0.2, yMax: 0.8)
        XCTAssertFalse(r.contains(x: 0.5, y: 0.5))
        XCTAssertFalse(r.contains(x: 0.2, y: 0.1))
    }

    func testContains_boundary() {
        let r = RegionConfig(name: "test", xMin: 0.1, xMax: 0.3, yMin: 0.2, yMax: 0.8)
        XCTAssertTrue(r.contains(x: 0.1, y: 0.2))  // 左上角含
        XCTAssertTrue(r.contains(x: 0.3, y: 0.8))  // 右下角含
    }

    func testDefaultRegions() {
        XCTAssertEqual(RegionConfig.defaultLeft.xMin, 0)
        XCTAssertEqual(RegionConfig.defaultLeft.xMax, 0.2)
        XCTAssertEqual(RegionConfig.defaultRight.xMin, 0.8)
        XCTAssertEqual(RegionConfig.defaultRight.xMax, 1)
    }
}
```

- [ ] **Step 4: 运行测试**

Run: `cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad" && swift test --filter RegionConfigTests 2>&1 | tail -15`
Expected: 4 tests passed

- [ ] **Step 5: Commit**

```bash
cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad"
git add Sources/GestureEngine/Models/RegionConfig.swift Tests/GestureEngineTests/RegionConfigTests.swift Package.swift
git commit -m "feat(models): add RegionConfig with rectangle containment tests"
```

---

## Task 2: 创建 EventConfig 模型 + ActionType + 执行方法

**Files:**
- Create: `Sources/GestureEngine/Models/EventConfig.swift`
- Create: `Tests/GestureEngineTests/EventConfigTests.swift`

- [ ] **Step 1: 创建 EventConfig.swift**

创建 `Sources/GestureEngine/Models/EventConfig.swift`：

```swift
import Foundation

/// 事件动作类型（未来加新动作在此加 case）
/// @ai: do not remove existing cases
public enum ActionType: String, Codable, CaseIterable {
    case volume
    case brightness

    public var displayName: String {
        switch self {
        case .volume: return "音量"
        case .brightness: return "亮度"
        }
    }
}

/// 事件 = 数据处理 + 改变系统值 + 边界判断
/// 震动不归事件（归手势）
public struct EventConfig: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var actionType: ActionType
    /// 每次变化量（原 volumeStep / brightnessStep）
    public var step: Float
    /// 边界判定阈值（0~1），当前值 <= 该阈值视为已到最小，>= (1-该阈值) 视为已到最大
    public var boundaryThreshold: Float

    public init(id: UUID = UUID(), name: String, actionType: ActionType, step: Float, boundaryThreshold: Float) {
        self.id = id
        self.name = name
        self.actionType = actionType
        self.step = step
        self.boundaryThreshold = boundaryThreshold
    }

    /// 默认音量事件
    public static let defaultVolume = EventConfig(
        name: "音量", actionType: .volume, step: 0.0125, boundaryThreshold: 0.001)

    /// 默认亮度事件
    public static let defaultBrightness = EventConfig(
        name: "亮度", actionType: .brightness, step: 0.0125, boundaryThreshold: 0.001)

    /// 读取当前系统值（0~1）
    public func currentValue() -> Float {
        switch actionType {
        case .volume: return SystemControl.getVolume()
        case .brightness: return SystemControl.getBrightness()
        }
    }

    /// 判断是否在边界
    /// - Parameter direction: >0 = 增大方向, <0 = 减小方向
    /// - Returns: true 表示朝该方向已到边界
    public func isAtBoundary(direction: Int) -> Bool {
        let value = currentValue()
        if direction < 0 && value <= boundaryThreshold { return true }
        if direction > 0 && value >= 1.0 - boundaryThreshold { return true }
        return false
    }

    /// 判断当前值是否在任一边界（用于进入 holding 时唤起 HUD）
    public func isAtAnyBoundary() -> Bool {
        let value = currentValue()
        return value <= boundaryThreshold || value >= 1.0 - boundaryThreshold
    }

    /// 执行系统值改变
    /// - Parameter direction: >0 = 增大, <0 = 减小
    public func perform(direction: Int) {
        switch actionType {
        case .volume:
            if direction > 0 { SystemControl.volumeUp() }
            else { SystemControl.volumeDown() }
        case .brightness:
            if direction > 0 { SystemControl.brightnessUp() }
            else { SystemControl.brightnessDown() }
        }
    }

    /// 发送朝边界外的媒体键（用于进入 holding 时唤起 HUD，值不变）
    public func postBoundaryKey() {
        let value = currentValue()
        if value >= 1.0 - boundaryThreshold {
            perform(direction: 1)  // 已到上界，发 up（值不变）
        } else if value <= boundaryThreshold {
            perform(direction: -1)  // 已到下界，发 down（值不变）
        }
    }
}
```

- [ ] **Step 2: 创建测试**

创建 `Tests/GestureEngineTests/EventConfigTests.swift`：

```swift
import XCTest
@testable import GestureEngine

final class EventConfigTests: XCTestCase {
    func testActionTypeDisplayNames() {
        XCTAssertEqual(ActionType.volume.displayName, "音量")
        XCTAssertEqual(ActionType.brightness.displayName, "亮度")
        XCTAssertEqual(ActionType.allCases.count, 2)
    }

    func testDefaultEvents() {
        XCTAssertEqual(EventConfig.defaultVolume.actionType, .volume)
        XCTAssertEqual(EventConfig.defaultBrightness.actionType, .brightness)
        XCTAssertEqual(EventConfig.defaultVolume.step, 0.0125)
    }

    func testCodableRoundTrip() throws {
        let original = EventConfig(name: "自定义", actionType: .volume, step: 0.05, boundaryThreshold: 0.01)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EventConfig.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}
```

- [ ] **Step 3: 运行测试**

Run: `cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad" && swift test --filter EventConfigTests 2>&1 | tail -15`
Expected: 3 tests passed (注意 currentValue/isAtBoundary 依赖系统 API，不在单元测试覆盖)

- [ ] **Step 4: Commit**

```bash
cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad"
git add Sources/GestureEngine/Models/EventConfig.swift Tests/GestureEngineTests/EventConfigTests.swift
git commit -m "feat(models): add EventConfig with ActionType and boundary logic"
```

---

## Task 3: 创建 GestureConfig（新版）+ GlobalSettings

**Files:**
- Create: `Sources/GestureEngine/Models/GestureConfig.swift` (替换旧文件)
- Create: `Sources/GestureEngine/Models/GlobalSettings.swift`

- [ ] **Step 1: 删除旧 GestureConfig.swift**

```bash
rm "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad/Sources/GestureEngine/GestureConfig.swift"
```

- [ ] **Step 2: 创建新 GestureConfig.swift**

创建 `Sources/GestureEngine/Models/GestureConfig.swift`：

```swift
import Foundation

/// 手势 = 触发识别 + 所有震动反馈 + 滑动刻度 + 鼠标
/// 持有 regionID 和 eventID 绑定区域和事件
/// @ai: do not change field names (Codable 合同)
public struct GestureConfig: Codable, Identifiable, Equatable {
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
    // 滑动
    public var slideStepNorm: Float
    // 鼠标
    public var disassociateMouse: Bool
    // 所有震动（归手势）
    public var hapticEnter: Int32
    public var hapticTick: Int32
    public var hapticBoundary: Int32
    public var boundaryHapticInterval: Int32

    public init(
        id: UUID = UUID(),
        name: String,
        regionID: UUID,
        eventID: UUID,
        tapMaxDuration: Double = 0.20,
        tapMaxDrift: Float = 0.05,
        tapMaxGap: Double = 0.30,
        holdMinDuration: Double = 0.20,
        slideStepNorm: Float = 0.02,
        disassociateMouse: Bool = true,
        hapticEnter: Int32 = 2,
        hapticTick: Int32 = 4,
        hapticBoundary: Int32 = 2,
        boundaryHapticInterval: Int32 = 50000
    ) {
        self.id = id
        self.name = name
        self.regionID = regionID
        self.eventID = eventID
        self.tapMaxDuration = tapMaxDuration
        self.tapMaxDrift = tapMaxDrift
        self.tapMaxGap = tapMaxGap
        self.holdMinDuration = holdMinDuration
        self.slideStepNorm = slideStepNorm
        self.disassociateMouse = disassociateMouse
        self.hapticEnter = hapticEnter
        self.hapticTick = hapticTick
        self.hapticBoundary = hapticBoundary
        self.boundaryHapticInterval = boundaryHapticInterval
    }
}
```

- [ ] **Step 3: 创建 GlobalSettings.swift**

创建 `Sources/GestureEngine/Models/GlobalSettings.swift`：

```swift
import Foundation

/// 全局设置（不归属于任何具体手势/事件/区域）
/// @ai: do not change field names (Codable 合同)
public struct GlobalSettings: Codable, Equatable {
    /// 帧处理限频（Hz），0 = 不限频
    public var frameRateLimit: Double = 0
    /// 接触面积下限
    public var touchSizeMin: Float = 0.1
    /// 接触面积上限
    public var touchSizeMax: Float = 1.0

    public init() {}

    public static let `default` = GlobalSettings()
}
```

- [ ] **Step 4: 编译验证**

Run: `cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad" && swift build 2>&1 | tail -10`
Expected: 编译会有错误（GestureEngine.swift 和 App.swift 还引用旧 GestureConfig），记录错误但不阻塞。本任务只验证 Models 目录本身无语法错误。

- [ ] **Step 5: Commit**

```bash
cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad"
git add Sources/GestureEngine/Models/GestureConfig.swift Sources/GestureEngine/Models/GlobalSettings.swift
git commit -m "feat(models): add new GestureConfig (gesture+regionID+eventID) and GlobalSettings"
```

---

## Task 4: 创建 AppConfig + ConfigStore（含迁移）

**Files:**
- Create: `Sources/GestureEngine/Models/AppConfig.swift`
- Create: `Sources/GestureEngine/Models/ConfigStore.swift`
- Create: `Tests/GestureEngineTests/ConfigMigrationTests.swift`

- [ ] **Step 1: 创建 AppConfig.swift**

创建 `Sources/GestureEngine/Models/AppConfig.swift`：

```swift
import Foundation

/// 顶层配置聚合（v2 格式）
/// @ai: do not change field names (Codable 合同)
public struct AppConfig: Codable, Equatable {
    public var version: Int
    public var global: GlobalSettings
    public var regions: [RegionConfig]
    public var gestures: [GestureConfig]
    public var events: [EventConfig]

    public init() {
        self.version = 2
        self.global = .default
        let left = RegionConfig.defaultLeft
        let right = RegionConfig.defaultRight
        let volume = EventConfig.defaultVolume
        let brightness = EventConfig.defaultBrightness
        self.regions = [left, right]
        self.events = [volume, brightness]
        self.gestures = [
            GestureConfig(name: "左侧", regionID: left.id, eventID: brightness.id),
            GestureConfig(name: "右侧", regionID: right.id, eventID: volume.id),
        ]
    }
}
```

- [ ] **Step 2: 创建 ConfigStore.swift**

创建 `Sources/GestureEngine/Models/ConfigStore.swift`：

```swift
import Foundation

/// 配置持久化 + v1→v2 迁移
public enum ConfigStore {
    /// 用户当前配置
    public static var configURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TouchpadGestures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    /// 用户自定义默认配置
    public static var userDefaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TouchpadGestures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("default.json")
    }

    // MARK: - v1 旧格式（扁平 GestureConfig）
    /// v1 扁平配置结构，仅用于迁移解码
    private struct V1Config: Codable {
        var frameRateLimit: Double = 0
        var touchSizeMax: Float = 1.0
        var touchSizeMin: Float = 0.1
        var edgeRightThreshold: Float = 0.80
        var edgeLeftThreshold: Float = 0.20
        var tapMaxDuration: Double = 0.20
        var tapMaxDrift: Float = 0.05
        var tapMaxGap: Double = 0.30
        var holdMinDuration: Double = 0.20
        var hapticEnter: Int32 = 2
        var volumeStepNorm: Float = 0.02
        var volumeStep: Float = 0.0125
        var brightnessStepNorm: Float = 0.02
        var brightnessStep: Float = 0.0125
        var hapticTick: Int32 = 4
        var boundaryThreshold: Float = 0.001
        var hapticBoundary: Int32 = 2
        var boundaryHapticInterval: Int32 = 50000
        var disassociateMouse: Bool = true
    }

    /// 加载配置（自动迁移 v1）
    public static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL) else {
            return AppConfig()
        }
        // 先尝试 v2
        if let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return cfg
        }
        // v1 迁移
        if let v1 = try? JSONDecoder().decode(V1Config.self, from: data) {
            let migrated = migrate(v1: v1)
            try? JSONEncoder().encode(migrated).write(to: configURL, options: .atomic)
            return migrated
        }
        return AppConfig()
    }

    /// 保存配置
    public static func save(_ config: AppConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: configURL, options: .atomic)
    }

    /// v1 → v2 迁移
    public static func migrate(v1: V1Config) -> AppConfig {
        let left = RegionConfig(name: "左边缘", xMin: 0, xMax: v1.edgeLeftThreshold, yMin: 0, yMax: 1)
        let right = RegionConfig(name: "右边缘", xMin: v1.edgeRightThreshold, xMax: 1, yMin: 0, yMax: 1)
        let volume = EventConfig(name: "音量", actionType: .volume, step: v1.volumeStep, boundaryThreshold: v1.boundaryThreshold)
        let brightness = EventConfig(name: "亮度", actionType: .brightness, step: v1.brightnessStep, boundaryThreshold: v1.boundaryThreshold)
        let global = GlobalSettings(frameRateLimit: v1.frameRateLimit, touchSizeMin: v1.touchSizeMin, touchSizeMax: v1.touchSizeMax)
        let leftGesture = GestureConfig(
            name: "左侧", regionID: left.id, eventID: brightness.id,
            tapMaxDuration: v1.tapMaxDuration, tapMaxDrift: v1.tapMaxDrift,
            tapMaxGap: v1.tapMaxGap, holdMinDuration: v1.holdMinDuration,
            slideStepNorm: v1.brightnessStepNorm,
            disassociateMouse: v1.disassociateMouse,
            hapticEnter: v1.hapticEnter, hapticTick: v1.hapticTick,
            hapticBoundary: v1.hapticBoundary, boundaryHapticInterval: v1.boundaryHapticInterval)
        let rightGesture = GestureConfig(
            name: "右侧", regionID: right.id, eventID: volume.id,
            tapMaxDuration: v1.tapMaxDuration, tapMaxDrift: v1.tapMaxDrift,
            tapMaxGap: v1.tapMaxGap, holdMinDuration: v1.holdMinDuration,
            slideStepNorm: v1.volumeStepNorm,
            disassociateMouse: v1.disassociateMouse,
            hapticEnter: v1.hapticEnter, hapticTick: v1.hapticTick,
            hapticBoundary: v1.hapticBoundary, boundaryHapticInterval: v1.boundaryHapticInterval)
        return AppConfig(version: 2, global: global, regions: [left, right], gestures: [leftGesture, rightGesture], events: [volume, brightness])
    }

    // MARK: - 用户默认配置
    public static func saveAsDefault(_ config: AppConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: userDefaultURL, options: .atomic)
    }

    public static func loadDefault() -> AppConfig {
        if let data = try? Data(contentsOf: userDefaultURL),
           let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return cfg
        }
        return AppConfig()
    }

    public static func clearUserDefault() {
        try? FileManager.default.removeItem(at: userDefaultURL)
    }
}
```

- [ ] **Step 3: 创建迁移测试**

创建 `Tests/GestureEngineTests/ConfigMigrationTests.swift`：

```swift
import XCTest
@testable import GestureEngine

final class ConfigMigrationTests: XCTestCase {
    /// 构造一个 v1 格式 JSON（扁平结构，无 version/regions/gestures/events 键）
    private func makeV1JSON() throws -> Data {
        let json = """
        {"frameRateLimit":0,"touchSizeMax":1.0,"touchSizeMin":0.1,
         "edgeRightThreshold":0.85,"edgeLeftThreshold":0.15,
         "tapMaxDuration":0.2,"tapMaxDrift":0.05,"tapMaxGap":0.3,
         "holdMinDuration":0.2,"hapticEnter":2,
         "volumeStepNorm":0.025,"volumeStep":0.02,
         "brightnessStepNorm":0.018,"brightnessStep":0.015,
         "hapticTick":4,"boundaryThreshold":0.002,
         "hapticBoundary":2,"boundaryHapticInterval":60000,
         "disassociateMouse":true}
        """
        return json.data(using: .utf8)!
    }

    func testV1Migration_producesV2Structure() throws {
        let v1Data = try makeV1JSON()
        // 模拟迁移：直接 decode v1 再调 migrate
        let v1 = try JSONDecoder().decode(ConfigStore.V1Config.self, from: v1Data)
        let v2 = ConfigStore.migrate(v1: v1)

        XCTAssertEqual(v2.version, 2)
        XCTAssertEqual(v2.regions.count, 2)
        XCTAssertEqual(v2.gestures.count, 2)
        XCTAssertEqual(v2.events.count, 2)
    }

    func testV1Migration_edgeThresholdsBecameRegions() throws {
        let v1Data = try makeV1JSON()
        let v1 = try JSONDecoder().decode(ConfigStore.V1Config.self, from: v1Data)
        let v2 = ConfigStore.migrate(v1: v1)

        let left = v2.regions[0]
        XCTAssertEqual(left.xMin, 0)
        XCTAssertEqual(left.xMax, 0.15)  // edgeLeftThreshold

        let right = v2.regions[1]
        XCTAssertEqual(right.xMin, 0.85)  // edgeRightThreshold
        XCTAssertEqual(right.xMax, 1)
    }

    func testV1Migration_stepsBecameEvents() throws {
        let v1Data = try makeV1JSON()
        let v1 = try JSONDecoder().decode(ConfigStore.V1Config.self, from: v1Data)
        let v2 = ConfigStore.migrate(v1: v1)

        let volume = v2.events.first { $0.actionType == .volume }!
        XCTAssertEqual(volume.step, 0.02)  // volumeStep

        let brightness = v2.events.first { $0.actionType == .brightness }!
        XCTAssertEqual(brightness.step, 0.015)  // brightnessStep
    }

    func testV1Migration_stepNormBecameGestureSlideStep() throws {
        let v1Data = try makeV1JSON()
        let v1 = try JSONDecoder().decode(ConfigStore.V1Config.self, from: v1Data)
        let v2 = ConfigStore.migrate(v1: v1)

        // 右侧手势绑定音量事件，slideStepNorm 应来自 volumeStepNorm
        let rightGesture = v2.gestures.first { $0.name == "右侧" }!
        XCTAssertEqual(rightGesture.slideStepNorm, 0.025)  // volumeStepNorm

        let leftGesture = v2.gestures.first { $0.name == "左侧" }!
        XCTAssertEqual(leftGesture.slideStepNorm, 0.018)  // brightnessStepNorm
    }

    func testV1Migration_bindingsCorrect() throws {
        let v1Data = try makeV1JSON()
        let v1 = try JSONDecoder().decode(ConfigStore.V1Config.self, from: v1Data)
        let v2 = ConfigStore.migrate(v1: v1)

        // 左侧手势绑定亮度事件
        let leftGesture = v2.gestures.first { $0.name == "左侧" }!
        let brightness = v2.events.first { $0.actionType == .brightness }!
        XCTAssertEqual(leftGesture.eventID, brightness.id)

        // 右侧手势绑定音量事件
        let rightGesture = v2.gestures.first { $0.name == "右侧" }!
        let volume = v2.events.first { $0.actionType == .volume }!
        XCTAssertEqual(rightGesture.eventID, volume.id)
    }

    func testV2CodableRoundTrip() throws {
        let original = AppConfig()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}
```

- [ ] **Step 4: 把 V1Config 改为 internal（测试需访问）**

修改 `ConfigStore.swift` 中 `V1Config` 的访问级别：`private struct V1Config` → `struct V1Config`（去掉 private，使其 internal，测试 @testable 能访问）。

- [ ] **Step 5: 运行测试**

Run: `cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad" && swift test --filter ConfigMigrationTests 2>&1 | tail -15`
Expected: 6 tests passed

- [ ] **Step 6: Commit**

```bash
cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad"
git add Sources/GestureEngine/Models/AppConfig.swift Sources/GestureEngine/Models/ConfigStore.swift Tests/GestureEngineTests/ConfigMigrationTests.swift
git commit -m "feat(models): add AppConfig, ConfigStore with v1→v2 migration and tests"
```

---

## Task 5: 抽出 GestureState + 重写 GestureEngine

**Files:**
- Create: `Sources/GestureEngine/GestureState.swift`
- Modify: `Sources/GestureEngine/GestureEngine.swift` (完全重写)
- Modify: `Sources/GestureEngine/Models/EventConfig.swift` (postBoundaryKey 已在 Task 2)

- [ ] **Step 1: 创建 GestureState.swift**

创建 `Sources/GestureEngine/GestureState.swift`：

```swift
import Foundation

/// 单个手势的状态机
public enum GestureState: Equatable {
    case idle
    case firstTapDown(pathIndex: Int32, startTime: Double, startPos: (Float, Float), maxDrift: Float)
    case firstTapUp(pathIndex: Int32, endTime: Double)
    case secondTapDown(pathIndex: Int32, startTime: Double, startPos: (Float, Float), maxDrift: Float)
    case holding(pathIndex: Int32, startY: Float, lastTickY: Float, ticks: Int, frozen: Bool, startValue: Float)
    case cooldown(pathIndex: Int32)

    public static func == (lhs: GestureState, rhs: GestureState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.firstTapDown(let a1, let a2, _, let a4), .firstTapDown(let b1, let b2, _, let b4)):
            return a1 == b1 && a2 == b2 && a4 == b4
        case (.firstTapUp(let a1, let a2), .firstTapUp(let b1, let b2)):
            return a1 == b1 && a2 == b2
        case (.secondTapDown(let a1, let a2, _, let a4), .secondTapDown(let b1, let b2, _, let b4)):
            return a1 == b1 && a2 == b2 && a4 == b4
        case (.holding(let a1, let a2, let a3, let a4, let a5, let a6),
              .holding(let b1, let b2, let b3, let b4, let b5, let b6)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4 && a5 == b5 && a6 == b6
        case (.cooldown(let a1), .cooldown(let b1)):
            return a1 == b1
        default:
            return false
        }
    }
}
```

- [ ] **Step 2: 重写 GestureEngine.swift**

完全替换 `Sources/GestureEngine/GestureEngine.swift`：

```swift
import Foundation
import Darwin
import CoreGraphics
import AppKit
import mt_bridge

/// 手势引擎：管理多个手势的状态机（字典版，v2）
public final class GestureEngine {

    public var config: AppConfig {
        didSet { ConfigStore.save(config) }
    }
    public var deviceID: UInt64 = 0

    /// 每个手势的独立状态机，key = gesture.id
    private var states: [UUID: GestureState] = [:]

    // 鼠标关联状态
    private var mouseDisassociated = false
    private var lockedCursorPos: CGPoint = .zero

    // 帧限频
    private var lastProcessTime: Double = 0

    // 回调：手势状态变化时通知 UI
    public var onStateChange: ((String, GestureState) -> Void)?

    public init() {
        config = ConfigStore.load()
        // 初始化所有手势状态为 idle
        for gesture in config.gestures {
            states[gesture.id] = .idle
        }
    }

    // MARK: - 每帧处理

    public func processFrame(touches: [mt_touch_t]) {
        let now = ProcessInfo.processInfo.systemUptime

        if config.global.frameRateLimit > 0 {
            let interval = 1.0 / config.global.frameRateLimit
            if now - lastProcessTime < interval { return }
            lastProcessTime = now
        }

        // 遍历所有手势
        for gesture in config.gestures {
            guard let region = config.regions.first(where: { $0.id == gesture.regionID }),
                  let event = config.events.first(where: { $0.id == gesture.eventID }) else { continue }
            if states[gesture.id] == nil { states[gesture.id] = .idle }
            processGesture(gesture, region: region, event: event, state: &states[gesture.id]!, touches: touches, now: now)
        }

        // 鼠标锁定：任意手势在 holding 即锁定
        if mouseDisassociated && isAnyHolding() {
            CGWarpMouseCursorPosition(lockedCursorPos)
        } else if mouseDisassociated && !isAnyHolding() {
            CGAssociateMouseAndMouseCursorPosition(1)
            mouseDisassociated = false
        }
    }

    // MARK: - 单手势状态机

    private func processGesture(_ gesture: GestureConfig, region: RegionConfig, event: EventConfig,
                                 state: inout GestureState, touches: [mt_touch_t], now: Double) {

        // 面积过滤
        func isSizeValid(_ t: mt_touch_t) -> Bool {
            t.size >= config.global.touchSizeMin && t.size <= config.global.touchSizeMax
        }

        // 在该区域内 + 活跃 + 面积合格的手指
        let edgeFinger: mt_touch_t? = touches.first { t in
            region.contains(x: t.norm_x, y: t.norm_y) && t.state != 0 && t.state != 7 && isSizeValid(t)
        }

        func fingerStillThere(_ pathIdx: Int32) -> Bool {
            touches.contains { $0.pathIndex == pathIdx && $0.state != 0 && $0.state != 7 && isSizeValid($0) }
        }

        switch state {
        case .idle:
            if let f = edgeFinger, (f.state == 1 || f.state == 3 || f.state == 4) {
                state = .firstTapDown(pathIndex: f.pathIndex, startTime: now, startPos: (f.norm_x, f.norm_y), maxDrift: 0)
                onStateChange?(gesture.name, state)
            }

        case .firstTapDown(let pathIdx, let startTime, let startPos, var maxDrift):
            if !fingerStillThere(pathIdx) {
                if maxDrift > gesture.tapMaxDrift {
                    state = .cooldown(pathIndex: pathIdx)
                } else {
                    state = .firstTapUp(pathIndex: pathIdx, endTime: now)
                }
                onStateChange?(gesture.name, state)
            } else {
                if let f = edgeFinger, f.pathIndex == pathIdx {
                    let dx = f.norm_x - startPos.0
                    let dy = f.norm_y - startPos.1
                    let drift = (dx*dx + dy*dy).squareRoot()
                    if drift > maxDrift { maxDrift = drift }
                }
                if now - startTime > gesture.tapMaxDuration || maxDrift > gesture.tapMaxDrift {
                    state = .cooldown(pathIndex: pathIdx)
                    onStateChange?(gesture.name, state)
                }
            }

        case .firstTapUp(_, let endTime):
            if now - endTime > gesture.tapMaxGap {
                state = .idle
                onStateChange?(gesture.name, state)
            } else if let f = edgeFinger, (f.state == 1 || f.state == 3 || f.state == 4) {
                state = .secondTapDown(pathIndex: f.pathIndex, startTime: now, startPos: (f.norm_x, f.norm_y), maxDrift: 0)
                onStateChange?(gesture.name, state)
            }

        case .secondTapDown(let pathIdx, let startTime, let startPos, var maxDrift):
            if !fingerStillThere(pathIdx) {
                state = .idle
                onStateChange?(gesture.name, state)
            } else {
                if let f = edgeFinger, f.pathIndex == pathIdx {
                    let dx = f.norm_x - startPos.0
                    let dy = f.norm_y - startPos.1
                    let drift = (dx*dx + dy*dy).squareRoot()
                    if drift > maxDrift { maxDrift = drift }
                }
                if maxDrift > gesture.tapMaxDrift {
                    state = .cooldown(pathIndex: pathIdx)
                    onStateChange?(gesture.name, state)
                } else if now - startTime > gesture.holdMinDuration {
                    let startY = edgeFinger?.norm_y ?? startPos.1
                    let startVal = event.currentValue()
                    // 进入 holding 时若事件在边界，发送朝边界外的媒体键唤起 HUD
                    if event.isAtAnyBoundary() {
                        event.postBoundaryKey()
                    }
                    state = .holding(pathIndex: pathIdx, startY: startY, lastTickY: startY, ticks: 0, frozen: false, startValue: startVal)
                    if deviceID != 0 { mt_actuate(deviceID, gesture.hapticEnter) }
                    if gesture.disassociateMouse { disassociateMouse() }
                    onStateChange?(gesture.name, state)
                }
            }

        case .holding(let pathIdx, let startY, let lastTickY, let ticks, let frozen, let startValue):
            if !fingerStillThere(pathIdx) {
                associateMouse()
                state = .idle
                onStateChange?(gesture.name, state)
            } else if frozen {
                break
            } else if let f = edgeFinger, f.pathIndex == pathIdx {
                let dy = f.norm_y - lastTickY
                if abs(dy) >= gesture.slideStepNorm {
                    let direction: Int = dy > 0 ? 1 : -1
                    let canDetect = startValue > event.boundaryThreshold
                        && startValue < 1.0 - event.boundaryThreshold
                    var atBoundary = false
                    if canDetect {
                        atBoundary = event.isAtBoundary(direction: direction)
                    }

                    if atBoundary {
                        // 进入时不在边界才发媒体键（进入时在边界已发过）
                        if !event.isAtAnyBoundary() || canDetect {
                            // 滑动过程中到达边界，发一次媒体键唤起 HUD
                            event.perform(direction: direction)
                        }
                        if deviceID != 0 {
                            mt_actuate(deviceID, gesture.hapticBoundary)
                            usleep(useconds_t(gesture.boundaryHapticInterval))
                            mt_actuate(deviceID, gesture.hapticBoundary)
                        }
                        state = .holding(pathIndex: pathIdx, startY: startY, lastTickY: f.norm_y, ticks: ticks, frozen: true, startValue: startValue)
                    } else {
                        event.perform(direction: direction)
                        if deviceID != 0 { mt_actuate(deviceID, gesture.hapticTick) }
                        state = .holding(pathIndex: pathIdx, startY: startY, lastTickY: f.norm_y, ticks: ticks + 1, frozen: false, startValue: startValue)
                    }
                    onStateChange?(gesture.name, state)
                }
            }

        case .cooldown(let pathIdx):
            if !fingerStillThere(pathIdx) {
                state = .idle
                onStateChange?(gesture.name, state)
            }
        }
    }

    // MARK: - 鼠标关联

    private func disassociateMouse() {
        guard !mouseDisassociated else { return }
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
        for (_, s) in states {
            if case .holding = s { return true }
        }
        return false
    }

    public func restoreMouse() { associateMouse() }

    /// 当前活跃的手势名（用于 UI 显示）
    public var activeGestureName: String? {
        for (id, s) in states {
            if case .holding = s,
               let g = config.gestures.first(where: { $0.id == id }) {
                return g.name
            }
        }
        return nil
    }
}
```

- [ ] **Step 3: 编译验证（预期有 App.swift 错误，暂忽略）**

Run: `cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad" && swift build 2>&1 | grep -E "error:" | grep -v "App.swift" | head -10`
Expected: 无 GestureEngine 模块的 error（App.swift 的错误忽略）

- [ ] **Step 4: 运行所有测试**

Run: `cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad" && swift test 2>&1 | tail -10`
Expected: 所有测试通过

- [ ] **Step 5: Commit**

```bash
cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad"
git add Sources/GestureEngine/GestureState.swift Sources/GestureEngine/GestureEngine.swift
git commit -m "feat(engine): rewrite GestureEngine with [UUID: GestureState] dict, gesture/event/region decoupled"
```

---

## Task 6: 抽出公共 UI 组件（Card + HapticWaveformReference）

**Files:**
- Create: `Sources/TouchpadGestures/Views/Card.swift`
- Create: `Sources/TouchpadGestures/Views/HapticWaveformReference.swift`
- Modify: `Sources/TouchpadGestures/App.swift` (删除旧的 Card 和 HapticWaveformReference，临时保留其余)

- [ ] **Step 1: 创建 Card.swift**

创建 `Sources/TouchpadGestures/Views/Card.swift`：

```swift
import SwiftUI

/// 卡片容器：浅灰背景 + 圆角 + 内边距，每个分组包一个
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.55))
        )
    }
}
```

- [ ] **Step 2: 创建 HapticWaveformReference.swift**

创建 `Sources/TouchpadGestures/Views/HapticWaveformReference.swift`：

```swift
import SwiftUI
import GestureEngine

/// 触觉波形对照表
struct HapticWaveformReference: View {
    let gesture: GestureConfig

    private let waveforms: [(Int32, String, String)] = [
        (1,  "弱 click",              "Weak click"),
        (2,  "强 click (Force Touch)", "Strong click (Force Touch)"),
        (3,  "buzz 震颤",              "Buzz"),
        (4,  "轻 tap",                "Light tap"),
        (5,  "中 tap",                "Medium tap"),
        (6,  "强 tap",                "Strong tap"),
        (15, "软重击",                 "Soft hit"),
        (16, "强重击",                 "Strong hit"),
    ]

    private func usageLabel(id: Int32) -> String {
        var usages: [String] = []
        if gesture.hapticEnter == id    { usages.append(L10n.tr("进入反馈", "Enter")) }
        if gesture.hapticTick == id     { usages.append(L10n.tr("滑动刻度", "Tick")) }
        if gesture.hapticBoundary == id { usages.append(L10n.tr("边界震动", "Boundary")) }
        return usages.isEmpty ? "—" : usages.joined(separator: " / ")
    }

    var body: some View {
        HStack {
            Text(L10n.tr("ID", "ID")).frame(width: 40, alignment: .leading)
            Text(L10n.tr("触感", "Sensation")).frame(width: 150, alignment: .leading)
            Text(L10n.tr("本项目用途", "Used For")).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

        ForEach(waveforms, id: \.0) { item in
            HStack {
                Text("\(item.0)").monospacedDigit().frame(width: 40, alignment: .leading)
                Text(L10n.tr(item.1, item.2)).frame(width: 150, alignment: .leading)
                Text(usageLabel(id: item.0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad"
git add Sources/TouchpadGestures/Views/Card.swift Sources/TouchpadGestures/Views/HapticWaveformReference.swift
git commit -m "feat(views): extract Card and HapticWaveformReference to Views/"
```

---

## Task 7: 创建 EditableTabBar 组件

**Files:**
- Create: `Sources/TouchpadGestures/Views/EditableTabBar.swift`

- [ ] **Step 1: 创建 EditableTabBar.swift**

创建 `Sources/TouchpadGestures/Views/EditableTabBar.swift`：

```swift
import SwiftUI

/// 可编辑二级 tab 条：显示 tab 名 + 编辑模式下增删/重命名
/// 通用组件，手势/事件/区域 tab 共用
struct EditableTabBar<T: Identifiable & Hashable>: View {
    let items: [T]
    @Binding var selection: T?
    let nameKeyPath: KeyPath<T, String>
    @Binding var isEditing: Bool
    let onAdd: () -> Void
    let onDelete: (T) -> Void
    let onRename: (T, String) -> Void
    let canDelete: Bool  // 至少保留 1 个时为 false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { item in
                TabChip(
                    name: item[keyPath: nameKeyPath],
                    isSelected: selection == item,
                    isEditing: isEditing,
                    canDelete: canDelete,
                    onSelect: { selection = item },
                    onDelete: { onDelete(item) },
                    onRename: { newName in onRename(item, newName) }
                )
            }
            if isEditing {
                Button(action: onAdd) {
                    Image(systemName: "plus.circle")
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .help(L10n.tr("新增", "Add"))
            }
            Spacer()
            Button(isEditing ? L10n.tr("完成", "Done") : L10n.tr("编辑", "Edit")) {
                isEditing.toggle()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

private struct TabChip: View {
    let name: String
    let isSelected: Bool
    let isEditing: Bool
    let canDelete: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void

    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        if isRenaming {
            TextField("", text: $renameText, onCommit: {
                if !renameText.isEmpty { onRename(renameText) }
                isRenaming = false
            })
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
        } else {
            HStack(spacing: 2) {
                Text(name)
                    .onTapGesture(count: 2) {
                        if isEditing {
                            renameText = name
                            isRenaming = true
                        }
                    }
                if isEditing && canDelete {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.small)
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : Color.separator, lineWidth: 0.5)
            )
            .onTapGesture { onSelect() }
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad"
git add Sources/TouchpadGestures/Views/EditableTabBar.swift
git commit -m "feat(views): add EditableTabBar with edit mode (add/delete/rename)"
```

---

## Task 8: 创建 RegionTabView（含可视化预览）

**Files:**
- Create: `Sources/TouchpadGestures/Views/RegionTabView.swift`

- [ ] **Step 1: 创建 RegionTabView.swift**

创建 `Sources/TouchpadGestures/Views/RegionTabView.swift`：

```swift
import SwiftUI
import GestureEngine

/// 区域 tab：二级 tab + 编辑模式，矩形坐标 Slider + 2:1 可视化预览
struct RegionTabView: View {
    @Binding var config: AppConfig
    @State private var selectedRegionID: UUID?
    @State private var isEditing = false
    @State private var showDeleteAlert = false
    @State private var pendingDeleteRegion: RegionConfig?

    private var selectedRegion: RegionConfig? {
        config.regions.first { $0.id == selectedRegionID } ?? config.regions.first
    }

    var body: some View {
        VStack(spacing: 0) {
            EditableTabBar(
                items: config.regions,
                selection: $selectedRegionID,
                nameKeyPath: \.name,
                isEditing: $isEditing,
                onAdd: addRegion,
                onDelete: { region in
                    if config.regions.count <= 1 { return }
                    let boundCount = config.gestures.filter { $0.regionID == region.id }.count
                    if boundCount > 0 {
                        pendingDeleteRegion = region
                        showDeleteAlert = true
                    } else {
                        deleteRegion(region)
                    }
                },
                onRename: { region, newName in
                    if let idx = config.regions.firstIndex(where: { $0.id == region.id }) {
                        config.regions[idx].name = newName
                    }
                },
                canDelete: config.regions.count > 1
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let region = selectedRegion, let idx = config.regions.firstIndex(where: { $0.id == region.id }) {
                        Card(title: L10n.tr("名称", "Name")) {
                            HStack {
                                Text(L10n.tr("区域名", "Region Name")).frame(width: 150, alignment: .leading)
                                TextField("区域名", text: Binding(
                                    get: { config.regions[idx].name },
                                    set: { config.regions[idx].name = $0 }
                                ))
                                .frame(maxWidth: 200)
                                Spacer()
                            }
                        }

                        Card(title: L10n.tr("矩形坐标（归一化 0~1）", "Rectangle Coordinates (normalized 0~1)")) {
                            sliderRow(L10n.tr("xMin", "xMin"),
                                      value: Binding(get: { config.regions[idx].xMin }, set: { config.regions[idx].xMin = $0 }),
                                      minVal: 0, maxVal: 1)
                            sliderRow(L10n.tr("xMax", "xMax"),
                                      value: Binding(get: { config.regions[idx].xMax }, set: { config.regions[idx].xMax = $0 }),
                                      minVal: 0, maxVal: 1)
                            sliderRow(L10n.tr("yMin", "yMin"),
                                      value: Binding(get: { config.regions[idx].yMin }, set: { config.regions[idx].yMin = $0 }),
                                      minVal: 0, maxVal: 1)
                            sliderRow(L10n.tr("yMax", "yMax"),
                                      value: Binding(get: { config.regions[idx].yMax }, set: { config.regions[idx].yMax = $0 }),
                                      minVal: 0, maxVal: 1)
                        }

                        Card(title: L10n.tr("可视化预览", "Visual Preview")) {
                            RegionPreview(region: region)
                                .frame(maxWidth: .infinity)
                                .frame(height: 200)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .alert(L10n.tr("确认删除区域？", "Delete region?"),
               isPresented: $showDeleteAlert) {
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
            Button(L10n.tr("删除", "Delete"), role: .destructive) {
                if let region = pendingDeleteRegion { deleteRegion(region) }
            }
        } message: {
            if let region = pendingDeleteRegion {
                let count = config.gestures.filter { $0.regionID == region.id }.count
                Text(L10n.tr("\(count) 个手势将解绑并重新绑定到第一个区域。此操作不可撤销。",
                            "\(count) gesture(s) will be rebound to the first region. This cannot be undone."))
            }
        }
    }

    private func sliderRow(_ label: String, value: Binding<Float>, minVal: Float, maxVal: Float) -> some View {
        HStack {
            Text(label).frame(width: 150, alignment: .leading)
            Slider(value: value, in: minVal...maxVal)
            Text(String(format: "%.2f", value.wrappedValue))
                .monospacedDigit().frame(width: 50, alignment: .trailing)
        }
    }

    private func addRegion() {
        let newRegion = RegionConfig(name: "新区域", xMin: 0.4, xMax: 0.6, yMin: 0.4, yMax: 0.6)
        config.regions.append(newRegion)
        selectedRegionID = newRegion.id
    }

    private func deleteRegion(_ region: RegionConfig) {
        guard let firstRemaining = config.regions.first(where: { $0.id != region.id }) else { return }
        // 解绑手势，重绑到第一个剩余区域
        for i in 0..<config.gestures.count {
            if config.gestures[i].regionID == region.id {
                config.gestures[i].regionID = firstRemaining.id
            }
        }
        config.regions.removeAll { $0.id == region.id }
        if selectedRegionID == region.id {
            selectedRegionID = firstRemaining.id
        }
    }
}

/// 区域可视化预览：2:1 触控板示意图 + 半透明色块
struct RegionPreview: View {
    let region: RegionConfig

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                // 触控板外框
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.1)))

                // 区域色块
                let rectX = CGFloat(region.xMin) * w
                let rectY = CGFloat(region.yMin) * h
                let rectW = CGFloat(region.xMax - region.xMin) * w
                let rectH = CGFloat(region.yMax - region.yMin) * h
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.accentColor, lineWidth: 1)
                    )
                    .frame(width: rectW, height: rectH)
                    .offset(x: rectX, y: rectY)
            }
        }
        .aspectRatio(2, contentMode: .fit)
    }
}
```

- [ ] **Step 2: Commit**

```bash
cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad"
git add Sources/TouchpadGestures/Views/RegionTabView.swift
git commit -m "feat(views): add RegionTabView with rectangle sliders and visual preview"
```

---

## Task 9: 创建 EventTabView

**Files:**
- Create: `Sources/TouchpadGestures/Views/EventTabView.swift`

- [ ] **Step 1: 创建 EventTabView.swift**

创建 `Sources/TouchpadGestures/Views/EventTabView.swift`：

```swift
import SwiftUI
import GestureEngine

/// 事件 tab：二级 tab + 编辑模式，动作类型 + step + 边界阈值
struct EventTabView: View {
    @Binding var config: AppConfig
    @State private var selectedEventID: UUID?
    @State private var isEditing = false
    @State private var showDeleteAlert = false
    @State private var pendingDeleteEvent: EventConfig?

    private var selectedEvent: EventConfig? {
        config.events.first { $0.id == selectedEventID } ?? config.events.first
    }

    var body: some View {
        VStack(spacing: 0) {
            EditableTabBar(
                items: config.events,
                selection: $selectedEventID,
                nameKeyPath: \.name,
                isEditing: $isEditing,
                onAdd: addEvent,
                onDelete: { event in
                    if config.events.count <= 1 { return }
                    let boundCount = config.gestures.filter { $0.eventID == event.id }.count
                    if boundCount > 0 {
                        pendingDeleteEvent = event
                        showDeleteAlert = true
                    } else {
                        deleteEvent(event)
                    }
                },
                onRename: { event, newName in
                    if let idx = config.events.firstIndex(where: { $0.id == event.id }) {
                        config.events[idx].name = newName
                    }
                },
                canDelete: config.events.count > 1
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let event = selectedEvent, let idx = config.events.firstIndex(where: { $0.id == event.id }) {
                        Card(title: L10n.tr("动作类型", "Action Type")) {
                            Picker(L10n.tr("动作", "Action"), selection: Binding(
                                get: { config.events[idx].actionType },
                                set: { config.events[idx].actionType = $0 }
                            )) {
                                ForEach(ActionType.allCases, id: \.self) { type in
                                    Text(type.displayName).tag(type)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        Card(title: L10n.tr("调节参数", "Adjustment")) {
                            HStack {
                                Text(L10n.tr("每次变化量", "Step"))
                                    .frame(width: 150, alignment: .leading)
                                Slider(value: Binding(
                                    get: { Double(config.events[idx].step) },
                                    set: { config.events[idx].step = Float($0) }
                                ), in: 0.005...0.05)
                                Text(String(format: "%.1f%%", config.events[idx].step * 100))
                                    .monospacedDigit().frame(width: 50, alignment: .trailing)
                            }
                        }

                        Card(title: L10n.tr("边界检测", "Boundary Detection")) {
                            HStack {
                                Text(L10n.tr("边界判定阈值", "Boundary Threshold"))
                                    .frame(width: 150, alignment: .leading)
                                Slider(value: Binding(
                                    get: { Double(config.events[idx].boundaryThreshold) },
                                    set: { config.events[idx].boundaryThreshold = Float($0) }
                                ), in: 0.001...0.05)
                                Text(String(format: "%.3f", config.events[idx].boundaryThreshold))
                                    .monospacedDigit().frame(width: 50, alignment: .trailing)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .alert(L10n.tr("确认删除事件？", "Delete event?"),
               isPresented: $showDeleteAlert) {
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
            Button(L10n.tr("删除", "Delete"), role: .destructive) {
                if let event = pendingDeleteEvent { deleteEvent(event) }
            }
        } message: {
            if let event = pendingDeleteEvent {
                let count = config.gestures.filter { $0.eventID == event.id }.count
                Text(L10n.tr("\(count) 个手势将解绑并重新绑定到第一个事件。此操作不可撤销。",
                            "\(count) gesture(s) will be rebound to the first event. This cannot be undone."))
            }
        }
    }

    private func addEvent() {
        let newEvent = EventConfig(name: "新事件", actionType: .volume, step: 0.0125, boundaryThreshold: 0.001)
        config.events.append(newEvent)
        selectedEventID = newEvent.id
    }

    private func deleteEvent(_ event: EventConfig) {
        guard let firstRemaining = config.events.first(where: { $0.id != event.id }) else { return }
        for i in 0..<config.gestures.count {
            if config.gestures[i].eventID == event.id {
                config.gestures[i].eventID = firstRemaining.id
            }
        }
        config.events.removeAll { $0.id == event.id }
        if selectedEventID == event.id {
            selectedEventID = firstRemaining.id
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad"
git add Sources/TouchpadGestures/Views/EventTabView.swift
git commit -m "feat(views): add EventTabView with action type, step, boundary threshold"
```

---

## Task 10: 创建 GestureTabView

**Files:**
- Create: `Sources/TouchpadGestures/Views/GestureTabView.swift`

- [ ] **Step 1: 创建 GestureTabView.swift**

创建 `Sources/TouchpadGestures/Views/GestureTabView.swift`：

```swift
import SwiftUI
import GestureEngine

/// 手势 tab：二级 tab + 编辑模式，绑定事件/区域 + 触发参数 + 所有震动
struct GestureTabView: View {
    @Binding var config: AppConfig
    @State private var selectedGestureID: UUID?
    @State private var isEditing = false
    @State private var showDeleteAlert = false
    @State private var pendingDeleteGesture: GestureConfig?

    private var selectedGesture: GestureConfig? {
        config.gestures.first { $0.id == selectedGestureID } ?? config.gestures.first
    }

    var body: some View {
        VStack(spacing: 0) {
            EditableTabBar(
                items: config.gestures,
                selection: $selectedGestureID,
                nameKeyPath: \.name,
                isEditing: $isEditing,
                onAdd: addGesture,
                onDelete: { gesture in
                    if config.gestures.count <= 1 { return }
                    deleteGesture(gesture)
                },
                onRename: { gesture, newName in
                    if let idx = config.gestures.firstIndex(where: { $0.id == gesture.id }) {
                        config.gestures[idx].name = newName
                    }
                },
                canDelete: config.gestures.count > 1
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let gesture = selectedGesture, let idx = config.gestures.firstIndex(where: { $0.id == gesture.id }) {
                        // 绑定事件
                        Card(title: L10n.tr("绑定事件", "Bound Event")) {
                            HStack {
                                Text(L10n.tr("事件", "Event")).frame(width: 150, alignment: .leading)
                                Picker(L10n.tr("事件", "Event"), selection: Binding(
                                    get: { config.gestures[idx].eventID },
                                    set: { config.gestures[idx].eventID = $0 }
                                )) {
                                    ForEach(config.events) { event in
                                        Text(event.name).tag(event.id)
                                    }
                                }
                                .pickerStyle(.menu)
                                Spacer()
                            }
                        }

                        // 触发区域
                        Card(title: L10n.tr("触发区域", "Trigger Region")) {
                            HStack {
                                Text(L10n.tr("区域", "Region")).frame(width: 150, alignment: .leading)
                                Picker(L10n.tr("区域", "Region"), selection: Binding(
                                    get: { config.gestures[idx].regionID },
                                    set: { config.gestures[idx].regionID = $0 }
                                )) {
                                    ForEach(config.regions) { region in
                                        Text(region.name).tag(region.id)
                                    }
                                }
                                .pickerStyle(.menu)
                                Spacer()
                            }
                        }

                        // 第一次轻点
                        Card(title: L10n.tr("第一次轻点", "First Tap")) {
                            HStack {
                                Text(L10n.tr("最长轻点时长 (s)", "Max Tap Duration (s)"))
                                    .frame(width: 150, alignment: .leading)
                                Slider(value: Binding(
                                    get: { config.gestures[idx].tapMaxDuration },
                                    set: { config.gestures[idx].tapMaxDuration = $0 }
                                ), in: 0.1...0.5)
                                Text(String(format: "%.2f", config.gestures[idx].tapMaxDuration))
                                    .monospacedDigit().frame(width: 50, alignment: .trailing)
                            }
                            HStack {
                                Text(L10n.tr("最大位移容差", "Max Drift"))
                                    .frame(width: 150, alignment: .leading)
                                Slider(value: Binding(
                                    get: { Double(config.gestures[idx].tapMaxDrift) },
                                    set: { config.gestures[idx].tapMaxDrift = Float($0) }
                                ), in: 0.01...0.15)
                                Text(String(format: "%.3f", config.gestures[idx].tapMaxDrift))
                                    .monospacedDigit().frame(width: 50, alignment: .trailing)
                            }
                        }

                        // 两次轻点衔接
                        Card(title: L10n.tr("两次轻点衔接", "Two-Tap Gap")) {
                            HStack {
                                Text(L10n.tr("两次轻点间隔 (s)", "Tap Gap (s)"))
                                    .frame(width: 150, alignment: .leading)
                                Slider(value: Binding(
                                    get: { config.gestures[idx].tapMaxGap },
                                    set: { config.gestures[idx].tapMaxGap = $0 }
                                ), in: 0.1...0.6)
                                Text(String(format: "%.2f", config.gestures[idx].tapMaxGap))
                                    .monospacedDigit().frame(width: 50, alignment: .trailing)
                            }
                        }

                        // 第二次轻点保持
                        Card(title: L10n.tr("第二次轻点保持", "Second Tap Hold")) {
                            HStack {
                                Text(L10n.tr("保持确认时长 (s)", "Hold Confirm (s)"))
                                    .frame(width: 150, alignment: .leading)
                                Slider(value: Binding(
                                    get: { config.gestures[idx].holdMinDuration },
                                    set: { config.gestures[idx].holdMinDuration = $0 }
                                ), in: 0.1...0.5)
                                Text(String(format: "%.2f", config.gestures[idx].holdMinDuration))
                                    .monospacedDigit().frame(width: 50, alignment: .trailing)
                            }
                            HStack {
                                Text(L10n.tr("进入反馈波形", "Enter Haptic Waveform"))
                                    .frame(width: 150, alignment: .leading)
                                Stepper(value: Binding(
                                    get: { config.gestures[idx].hapticEnter },
                                    set: { config.gestures[idx].hapticEnter = $0 }
                                ), in: 1...16) {
                                    Text("\(config.gestures[idx].hapticEnter)")
                                }
                                Spacer()
                            }
                        }

                        // 滑动调节
                        Card(title: L10n.tr("滑动调节", "Slide Adjust")) {
                            HStack {
                                Text(L10n.tr("滑动刻度", "Slide Step Norm"))
                                    .frame(width: 150, alignment: .leading)
                                Slider(value: Binding(
                                    get: { Double(config.gestures[idx].slideStepNorm) },
                                    set: { config.gestures[idx].slideStepNorm = Float($0) }
                                ), in: 0.005...0.05)
                                Text(String(format: "%.3f", config.gestures[idx].slideStepNorm))
                                    .monospacedDigit().frame(width: 50, alignment: .trailing)
                            }
                            HStack {
                                Text(L10n.tr("刻度反馈波形", "Tick Haptic Waveform"))
                                    .frame(width: 150, alignment: .leading)
                                Stepper(value: Binding(
                                    get: { config.gestures[idx].hapticTick },
                                    set: { config.gestures[idx].hapticTick = $0 }
                                ), in: 1...16) {
                                    Text("\(config.gestures[idx].hapticTick)")
                                }
                                Spacer()
                            }
                        }

                        // 边界震动
                        Card(title: L10n.tr("边界震动", "Boundary Haptic")) {
                            HStack {
                                Text(L10n.tr("边界强震动波形", "Boundary Haptic Waveform"))
                                    .frame(width: 150, alignment: .leading)
                                Stepper(value: Binding(
                                    get: { config.gestures[idx].hapticBoundary },
                                    set: { config.gestures[idx].hapticBoundary = $0 }
                                ), in: 1...16) {
                                    Text("\(config.gestures[idx].hapticBoundary)")
                                }
                                Spacer()
                            }
                            HStack {
                                Text(L10n.tr("边界震动间隔 (ms)", "Boundary Haptic Interval (ms)"))
                                    .frame(width: 150, alignment: .leading)
                                Slider(value: Binding(
                                    get: { Double(config.gestures[idx].boundaryHapticInterval) / 1000.0 },
                                    set: { config.gestures[idx].boundaryHapticInterval = Int32($0 * 1000) }
                                ), in: 10...200)
                                Text(String(format: "%.0f", Double(config.gestures[idx].boundaryHapticInterval) / 1000.0))
                                    .monospacedDigit().frame(width: 50, alignment: .trailing)
                            }
                        }

                        // 鼠标控制
                        Card(title: L10n.tr("鼠标控制", "Mouse Control")) {
                            HStack {
                                Text(L10n.tr("进入 holding 时解除鼠标关联", "Disassociate mouse on holding"))
                                    .frame(width: 150, alignment: .leading)
                                Toggle("", isOn: Binding(
                                    get: { config.gestures[idx].disassociateMouse },
                                    set: { config.gestures[idx].disassociateMouse = $0 }
                                )).labelsHidden()
                                Spacer()
                            }
                        }

                        // 触觉波形对照
                        Card(title: L10n.tr("触觉波形对照", "Haptic Waveform Reference")) {
                            HapticWaveformReference(gesture: config.gestures[idx])
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private func addGesture() {
        guard let firstRegion = config.regions.first,
              let firstEvent = config.events.first else { return }
        let newGesture = GestureConfig(name: "新手势", regionID: firstRegion.id, eventID: firstEvent.id)
        config.gestures.append(newGesture)
        selectedGestureID = newGesture.id
    }

    private func deleteGesture(_ gesture: GestureConfig) {
        config.gestures.removeAll { $0.id == gesture.id }
        if selectedGestureID == gesture.id {
            selectedGestureID = config.gestures.first?.id
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad"
git add Sources/TouchpadGestures/Views/GestureTabView.swift
git commit -m "feat(views): add GestureTabView with event/region binding and all gesture params"
```

---

## Task 11: 创建 SettingsTabView

**Files:**
- Create: `Sources/TouchpadGestures/Views/SettingsTabView.swift`

- [ ] **Step 1: 创建 SettingsTabView.swift**

创建 `Sources/TouchpadGestures/Views/SettingsTabView.swift`：

```swift
import SwiftUI
import GestureEngine

/// 设置 tab：全局触摸数据流 + 软件信息 + 触控板规格 + 启动 + 菜单栏图标 + App 图标 + 配置默认值 + 版权
struct SettingsTabView: View {
    @Binding var config: AppConfig
    @ObservedObject var appDelegate: AppDelegate
    @State private var showRestoreFactoryAlert = false
    @State private var showSavedAsDefault = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // 全局触摸数据流
                    Card(title: L10n.tr("触摸数据流", "Touch Data Stream")) {
                        HStack {
                            Text(L10n.tr("帧处理限频 (Hz)", "Frame Rate Limit (Hz)"))
                                .frame(width: 150, alignment: .leading)
                            Slider(value: $config.global.frameRateLimit, in: 0...240)
                            Text(config.global.frameRateLimit < 1 ? L10n.tr("不限", "off") : String(format: "%.0f", config.global.frameRateLimit))
                                .monospacedDigit().frame(width: 50, alignment: .trailing)
                        }
                        HStack {
                            Text(L10n.tr("接触面积下限", "Touch Size Min"))
                                .frame(width: 150, alignment: .leading)
                            Slider(value: $config.global.touchSizeMin, in: 0...0.5)
                            Text(String(format: "%.2f", config.global.touchSizeMin))
                                .monospacedDigit().frame(width: 50, alignment: .trailing)
                        }
                        HStack {
                            Text(L10n.tr("接触面积上限", "Touch Size Max"))
                                .frame(width: 150, alignment: .leading)
                            Slider(value: $config.global.touchSizeMax, in: 0.5...2.0)
                            Text(String(format: "%.2f", config.global.touchSizeMax))
                                .monospacedDigit().frame(width: 50, alignment: .trailing)
                        }
                    }

                    // 软件信息
                    Card(title: L10n.tr("软件信息", "App Info")) {
                        HStack {
                            Text(L10n.tr("名称", "Name")).frame(width: 150, alignment: .leading)
                            Text("Touchpad Gestures")
                            Spacer()
                        }
                        HStack {
                            Text(L10n.tr("版本", "Version")).frame(width: 150, alignment: .leading)
                            Text("\(appDelegate.appVersion) (\(appDelegate.appBuild))").monospacedDigit()
                            Spacer()
                        }
                    }

                    // 触控板规格
                    Card(title: L10n.tr("触控板规格", "Trackpad Spec")) {
                        HStack {
                            Text(L10n.tr("检测到的设备数", "Detected Devices")).frame(width: 150, alignment: .leading)
                            Text("\(appDelegate.trackpadDeviceCount)").monospacedDigit()
                            Spacer()
                        }
                        HStack {
                            Text(L10n.tr("设备 ID", "Device ID")).frame(width: 150, alignment: .leading)
                            Text(String(format: "%llu", appDelegate.trackpadDeviceID)).monospacedDigit().textSelection(.enabled)
                            Spacer()
                        }
                    }

                    // 启动
                    Card(title: L10n.tr("启动", "Startup")) {
                        HStack {
                            Text(L10n.tr("登录时自动启动", "Launch at login")).frame(width: 150, alignment: .leading)
                            Toggle("", isOn: Binding(
                                get: { appDelegate.appSettings.launchAtLogin },
                                set: { newVal in
                                    appDelegate.appSettings.launchAtLogin = newVal
                                    appDelegate.setLaunchAtLogin(newVal)
                                }
                            )).labelsHidden()
                            Spacer()
                        }
                        HStack {
                            Text(L10n.tr("在 Dock 中显示", "Show in Dock")).frame(width: 150, alignment: .leading)
                            Toggle("", isOn: Binding(
                                get: { appDelegate.appSettings.showInDock },
                                set: { newVal in
                                    appDelegate.appSettings.showInDock = newVal
                                    appDelegate.applyDockPolicy()
                                }
                            )).labelsHidden()
                            Spacer()
                        }
                    }

                    // 菜单栏图标
                    Card(title: L10n.tr("菜单栏图标", "Menu Bar Icon")) {
                        HStack {
                            Text(L10n.tr("图标 (SF Symbol)", "Icon (SF Symbol)")).frame(width: 150, alignment: .leading)
                            TextField("hand.tap", text: Binding(
                                get: { appDelegate.appSettings.menuBarIcon },
                                set: { newVal in
                                    appDelegate.appSettings.menuBarIcon = newVal
                                    appDelegate.applyMenuBarIcon()
                                }
                            ))
                            .frame(maxWidth: 200)
                            Spacer()
                        }
                        HStack {
                            Text(L10n.tr("图标尺寸", "Icon Size")).frame(width: 150, alignment: .leading)
                            Slider(value: Binding(
                                get: { appDelegate.appSettings.menuBarIconSize },
                                set: { newVal in
                                    appDelegate.appSettings.menuBarIconSize = newVal
                                    appDelegate.applyMenuBarIcon()
                                }
                            ), in: 10...24)
                            Text(String(format: "%.0f", appDelegate.appSettings.menuBarIconSize))
                                .monospacedDigit().frame(width: 50, alignment: .trailing)
                        }
                    }

                    // App 图标
                    Card(title: L10n.tr("App 图标", "App Icon")) {
                        HStack {
                            Text(L10n.tr("颜色", "Color")).frame(width: 150, alignment: .leading)
                            ForEach([
                                (NSColor.white, "白"), (NSColor.black, "黑"),
                                (NSColor.systemRed, "红"), (NSColor.systemOrange, "橙"),
                                (NSColor.systemYellow, "黄"), (NSColor.systemGreen, "绿"),
                                (NSColor.systemCyan, "青"), (NSColor.systemBlue, "蓝"),
                                (NSColor.systemPurple, "紫"), (NSColor.systemPink, "粉"),
                            ], id: \.1) { color, _ in
                                Circle()
                                    .fill(Color(nsColor: color))
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().stroke(.separator, lineWidth: 0.5))
                                    .onTapGesture {
                                        appDelegate.appSettings.appIconColorRed = color.redComponent
                                        appDelegate.appSettings.appIconColorGreen = color.greenComponent
                                        appDelegate.appSettings.appIconColorBlue = color.blueComponent
                                        appDelegate.applyAppIcon()
                                    }
                            }
                            Spacer()
                        }
                    }

                    // 配置默认值
                    Card(title: L10n.tr("配置默认值", "Config Defaults")) {
                        HStack {
                            Button(L10n.tr("保存当前为默认", "Save as Default")) {
                                ConfigStore.saveAsDefault(config)
                                showSavedAsDefault = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Spacer()
                        }
                        HStack {
                            Button(L10n.tr("恢复代码默认值", "Restore Factory Defaults")) {
                                showRestoreFactoryAlert = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.red)
                            Spacer()
                        }
                        Text(L10n.tr("「保存为默认」后，重置全部将恢复到此配置；「恢复代码默认值」会清除自定义默认。",
                                    "After 'Save as Default', 'Reset All' restores to this config; 'Restore Factory Defaults' clears the custom default."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            // 底部固定版权声明
            Divider()
            VStack(alignment: .center, spacing: 2) {
                Text("Copyright © 2026 @zekiwithcat")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(L10n.tr("基于 Apple MultitouchSupport 私有框架，仅用于个人使用。",
                            "Built on Apple MultitouchSupport private framework, for personal use only."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.tr("借鉴 MatMercer/mactic 项目（MIT License）。",
                            "Inspired by MatMercer/mactic (MIT License)."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .alert(L10n.tr("确认恢复代码默认值？", "Restore factory defaults?"),
               isPresented: $showRestoreFactoryAlert) {
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
            Button(L10n.tr("恢复", "Restore"), role: .destructive) {
                ConfigStore.clearUserDefault()
                config = AppConfig()
            }
        } message: {
            Text(L10n.tr("将清除自定义默认配置并恢复到代码默认值，此操作不可撤销。",
                        "This clears the custom default and restores to factory defaults. This cannot be undone."))
        }
        .alert(L10n.tr("已保存为默认", "Saved as Default"),
               isPresented: $showSavedAsDefault) {
            Button(L10n.tr("好", "OK"), role: .cancel) {}
        } message: {
            Text(L10n.tr("当前配置已保存为默认，重置全部时将恢复到此配置。",
                        "Current config saved as default. 'Reset All' will restore to this."))
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad"
git add Sources/TouchpadGestures/Views/SettingsTabView.swift
git commit -m "feat(views): add SettingsTabView with global settings, app info, icon, defaults"
```

---

## Task 12: 重写 App.swift（AppDelegate 适配 + ConfigView 4 tab）

**Files:**
- Modify: `Sources/TouchpadGestures/App.swift` (完全重写，删除旧 Card/HapticWaveformReference/ConfigView)

- [ ] **Step 1: 完全重写 App.swift**

完全替换 `Sources/TouchpadGestures/App.swift` 内容为：

```swift
import SwiftUI
import GestureEngine
import mt_bridge
import CoreGraphics

// MARK: - 国际化工具

enum L10n {
    static let isChinese: Bool = {
        Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    }()
    static func tr(_ zh: String, _ en: String) -> String { isChinese ? zh : en }
}

// MARK: - 软件设置

struct AppSettings: Codable, Equatable {
    var launchAtLogin: Bool = false
    var showInDock: Bool = false
    var menuBarIcon: String = "hand.tap"
    var menuBarIconSize: CGFloat = 14
    var appIconColorRed: Double = 1.0
    var appIconColorGreen: Double = 1.0
    var appIconColorBlue: Double = 1.0

    init() {}

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TouchpadGestures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("appsettings.json")
    }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return s
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}

@main
struct TouchpadGesturesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let engine = GestureEngine()
    @Published var appSettings: AppSettings {
        didSet { appSettings.save() }
    }
    @Published var showResetAllAlert = false
    private var touchArrayPtr: UnsafeMutableRawPointer? = nil
    private var deviceCount: Int32 = 0
    private var firstDev: mt_device_t? = nil
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    override init() {
        appSettings = AppSettings.load()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(appSettings.showInDock ? .regular : .accessory)
        applyAppIcon()

        guard mt_init() == 0 else {
            print("[ERROR] mt_init 失败")
            return
        }

        deviceCount = mt_scan_devices_array(&touchArrayPtr)
        guard deviceCount > 0, let arr = touchArrayPtr else {
            print("[ERROR] 未找到 multitouch 设备")
            return
        }

        firstDev = mt_device_at_index(arr, 0)
        guard let dev = firstDev else { return }

        let idOffset = mt_device_get_id(dev)
        let idIOReg = mt_device_get_id_by_index(0)
        engine.deviceID = idIOReg != 0 ? idIOReg : idOffset

        let ctxPtr = Unmanaged.passUnretained(self).toOpaque()
        mt_start_touch(dev, touchCallback, ctxPtr)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyMenuBarIcon()

        let menu = NSMenu()
        menu.addItem(withTitle: "Touchpad Gestures", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr("设置...", "Settings..."), action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr("退出", "Quit"), action: #selector(quit), keyEquivalent: "q")
        statusItem?.menu = menu
    }

    func applyMenuBarIcon() {
        guard let button = statusItem?.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: appSettings.menuBarIconSize, weight: .regular)
        let name = appSettings.menuBarIcon.isEmpty ? "hand.tap" : appSettings.menuBarIcon
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Touchpad Gestures")?
            .withSymbolConfiguration(config)
    }

    func applyAppIcon() {
        let config = NSImage.SymbolConfiguration(pointSize: 96, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "hand.tap", accessibilityDescription: "Touchpad Gestures")?
            .withSymbolConfiguration(config) else { return }

        let size = NSSize(width: 128, height: 128)
        let colored = NSImage(size: size)
        colored.lockFocus()
        let drawRect = NSRect(
            x: (size.width - symbol.size.width) / 2,
            y: (size.height - symbol.size.height) / 2,
            width: symbol.size.width, height: symbol.size.height)
        symbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        let iconColor = NSColor(calibratedRed: appSettings.appIconColorRed,
                                green: appSettings.appIconColorGreen,
                                blue: appSettings.appIconColorBlue, alpha: 1.0)
        iconColor.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        colored.unlockFocus()
        colored.isTemplate = false
        NSApp.applicationIconImage = colored
    }

    func applyDockPolicy() {
        NSApp.setActivationPolicy(appSettings.showInDock ? .regular : .accessory)
        applyAppIcon()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let path: String
        if Bundle.main.bundleURL.pathExtension == "app" {
            path = Bundle.main.bundlePath
        } else {
            path = CommandLine.arguments[0]
        }
        let name = (path as NSString).lastPathComponent
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        if enabled {
            task.arguments = ["-e",
                "tell application \"System Events\" to make login item at end with properties {path:\"\(path)\",hidden:false}"]
        } else {
            task.arguments = ["-e",
                "tell application \"System Events\" to delete login item \"\(name)\""]
        }
        try? task.run()
    }

    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0" }
    var appBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1" }
    var trackpadDeviceID: UInt64 { engine.deviceID }
    var trackpadDeviceCount: Int32 { deviceCount }

    @objc func openSettings() {
        if settingsWindow == nil {
            let hostingView = NSHostingView(rootView: ConfigView(config: engine.config)
                .environmentObject(self))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 820),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = L10n.tr("Touchpad Gestures 设置", "Touchpad Gestures Settings")
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.contentView = hostingView

            let titlebarView = NSHostingView(rootView:
                ResetAllTitlebarButton { [weak self] in
                    self?.showResetAllAlert = true
                })
            titlebarView.frame.size = NSSize(width: 110, height: 28)
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = titlebarView
            accessory.layoutAttribute = .trailing
            window.addTitlebarAccessoryViewController(accessory)

            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    @objc func quit() {
        engine.restoreMouse()
        if let dev = firstDev { mt_stop_touch(dev) }
        mt_shutdown()
        NSApp.terminate(nil)
    }

    func updateConfig(_ config: AppConfig) {
        engine.config = config
    }
}

// MARK: - 触摸回调

private let touchCallback: @convention(c) (
    _ dev: UnsafeMutableRawPointer?,
    _ touches: UnsafePointer<mt_touch_t>?,
    _ n: Int32, _ timestamp: Double, _ frame: Int32,
    _ userData: UnsafeMutableRawPointer?
) -> Void = { _, touches, n, _, _, userData in
    guard let userData = userData else { return }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    var touchArray: [mt_touch_t] = []
    if let touches = touches, n > 0 {
        for i in 0..<Int(n) { touchArray.append(touches[i]) }
    }
    delegate.engine.processFrame(touches: touchArray)
}

// MARK: - ConfigView（4 栏一级 tab）

struct ConfigView: View {
    @State var config: AppConfig
    @EnvironmentObject var appDelegate: AppDelegate

    var body: some View {
        TabView {
            GestureTabView(config: $config)
                .tabItem { Text(L10n.tr("手势", "Gestures")) }

            EventTabView(config: $config)
                .tabItem { Text(L10n.tr("事件", "Events")) }

            RegionTabView(config: $config)
                .tabItem { Text(L10n.tr("区域", "Regions")) }

            SettingsTabView(config: $config, appDelegate: appDelegate)
                .tabItem { Text(L10n.tr("设置", "Settings")) }
        }
        .frame(width: 660, height: 780)
        .onChange(of: config) { newConfig in
            appDelegate.updateConfig(newConfig)
        }
        .alert(L10n.tr("确认重置全部配置？", "Reset all settings?"),
               isPresented: $appDelegate.showResetAllAlert) {
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
            Button(L10n.tr("重置", "Reset"), role: .destructive) {
                config = ConfigStore.loadDefault()
            }
        } message: {
            Text(L10n.tr("所有配置将恢复为默认值，此操作不可撤销。",
                        "All settings will be restored to defaults. This cannot be undone."))
        }
    }
}

// MARK: - 标题栏全局重置按钮

struct ResetAllTitlebarButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(L10n.tr("重置全部", "Reset All"), systemImage: "arrow.counterclockwise")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(L10n.tr("重置所有手势配置为默认值", "Reset all gesture settings to defaults"))
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad" && swift build 2>&1 | tail -20`
Expected: Build complete（可能有少量 warning，无 error）

- [ ] **Step 3: 运行所有测试**

Run: `cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad" && swift test 2>&1 | tail -10`
Expected: 所有测试通过

- [ ] **Step 4: Commit**

```bash
cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad"
git add Sources/TouchpadGestures/App.swift
git commit -m "feat(app): rewrite App.swift with 4-tab ConfigView, AppDelegate uses AppConfig"
```

---

## Task 13: 全量编译验证 + 手动测试

**Files:** 无修改

- [ ] **Step 1: 全量编译**

Run: `cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad" && swift build 2>&1 | tail -10`
Expected: Build complete

- [ ] **Step 2: 全量测试**

Run: `cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad" && swift test 2>&1 | tail -10`
Expected: All tests passed

- [ ] **Step 3: 手动运行测试**

Run: `cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad" && swift run TouchpadGestures &`

手动验证：
1. 菜单栏出现 hand.tap 图标
2. 点击「设置...」打开窗口
3. 4 个一级 tab：手势 / 事件 / 区域 / 设置
4. 手势 tab：二级 tab「左侧」「右侧」，编辑模式可增删重命名
5. 事件 tab：二级 tab「音量」「亮度」，动作类型 SegmentedControl
6. 区域 tab：二级 tab「左边缘」「右边缘」，矩形坐标 Slider + 可视化预览
7. 设置 tab：触摸数据流 + 软件信息 + 启动 + 菜单栏图标 + App 图标 + 配置默认值 + 版权
8. 右侧双击保持上下滑动 → 调音量 + HUD + 刻度震动
9. 左侧双击保持上下滑动 → 调亮度 + HUD + 刻度震动
10. 到边界 → 强震动 + 冻结
11. 标题栏「重置全部」→ 弹窗确认 → 重置到默认
12. 旧 config.json（若存在）自动迁移，行为一致

- [ ] **Step 4: 停止运行**

```bash
kill %1 2>/dev/null || true
```

- [ ] **Step 5: Commit**

```bash
cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad"
git add -A
git commit -m "chore: v1.1.0 event config refactor complete - verified build and tests"
```

---

## Task 14: 更新构建脚本版本号 + 发布

**Files:**
- Modify: `scripts/build_app.sh`
- Modify: `README.md`

- [ ] **Step 1: 更新 build_app.sh 版本号**

修改 `scripts/build_app.sh`：
- `VERSION="1.0.0"` → `VERSION="1.1.0"`
- `BUILD_NUM="1"` → `BUILD_NUM="1"`

- [ ] **Step 2: 更新 README.md（如需）**

Run: 检查 README 是否需要更新版本号引用。主要更新 Releases 链接描述。

- [ ] **Step 3: 重新构建 .app**

Run: `cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad" && rm -rf dist && ./scripts/build_app.sh 2>&1 | tail -10`
Expected: Build complete + zip 生成

- [ ] **Step 4: 推送 + 创建 v1.1.0 release**

```bash
cd "/Users/zekiwithcat/Documents/Obsidian Vault/mac_touchpad"
git add -A
git commit -m "release: v1.1.0 event config refactor"
git push
gh release create v1.1.0 dist/TouchpadGestures.zip --title "v1.1.0 — 事件配置化重构" --notes "..."
```

- [ ] **Step 5: 更新 MEMO.md**

记录 v1.1.0 架构变更到项目备忘录。
