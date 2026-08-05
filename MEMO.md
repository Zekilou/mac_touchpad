# 项目备忘录

## v10.20 全面 bug 审查（2026-08-05，154 tests 通过）
用户要求"读全部代码找 bug"的一轮完整排查（引擎/模型/UI 全部读完），确认并修复 6 个 bug：
1. **事件方向重置按钮回滚错误（高）**：EventTabView 重置方向写 `.positiveDecrease`（旧默认），而 v10.19 已把默认翻转为 `.positiveIncrease`（本机 norm_y 上滑=增大）→ 用户点重置方向又反了。修复：重置改 `.positiveIncrease` + 更新 tooltip
2. **删除事件/区域重绑定失效（高）**：v4 图化后绑定在图上 EventRef/RegionRef 节点（顶层 eventID/regionID 置 nil），但 AppDelegate.requestDelete/performEventDelete/performRegionDelete 仍用顶层字段判断绑定 → 绑定检测恒 0（不弹确认）+ 删除后图上 ref 节点悬空 → 绑定手势静默失效。修复：改用 boundEventID/boundRegionID 判断 + updateNodeParams 更新图上 ref 节点重绑定
3. **holdingCount 持续 holding 恒 0（中）**：processTick 每帧重置 holdingCount 且只在"新进入"帧 +1 → 持续 holding 期间显示 0。修复：改为统计当前实际 holding 手势数
4. **eventBox 全局共享串台（中）**：单一 eventBox 被所有手势共享——两只手同时在不同边缘 holding 时，后进入手势消费前一手势的事件（调节错对象 + trackedValue 写回串台）。修复：eventBoxes 改 per-gesture 字典（key=gesture.id），effects.eventBox 每帧按当前手势设置；删除 currentEventIndex/currentGestureName 共享状态
5. **基础设置页缺手势启用开关（中）**：BasicGestureSettingsView（v10.19 新增）无 enabled Toggle（高级画布有）→ 基础设置页无法切换启用。修复：加「启用」卡片，GestureTabView 传入 enabled binding
6. **mediaKey step Slider clamp 错位（低）**：stepRange 下限 0.03125 > 默认 step 0.0125 → Slider 显示被 clamp。修复：下限改 0.01

### v10.20 续（2026-08-05，commit c0d585d / 03ff321）
7. **基础设置触觉反馈不回显（中，commit c0d585d）**：hapticRow 的 Binding get 闭包捕获 `let params` 快照，set 更新图但显示读旧快照 → 点 Stepper 值"没变"。修复：currentHaptic(title) 实时读图
8. **stop() 不清理 holding 状态（低，commit c0d585d）**：停止后残留 eventBox/wasHolding，重启续用旧状态。修复：stop 清理 eventBoxes/wasHolding/holdingCount
9. **工具箱暴露简化节点（低，commit 03ff321）**：switch（忽略 index 仅透传）与 hud（EngineEffects.showHUD 空实现）行为与名称不符 → 工具箱与右键菜单隐藏（NodePaletteView + addNodeSubmenus 两处 hidden 集合加 .switch/.hud）
10. **Force 信号源选择器可用（低，commit 03ff321）**：Force 手势滑动信号恒 normY，但基础设置页信号源 Picker 可改 → 改后下次 load 被 upgradeForcePress 静默纠正回 normY（"改不生效"困惑）。修复：isForceGesture 时禁用 Picker + 说明文字
11. **quit() 泄漏设备 CFArray（低，commit 03ff321）**：mt_scan_devices_array 的数组未释放。修复：quit 调 mt_release_devices_array
12. **误删教训**：TimelineNodeInspector.swift 承载 typedRows/nonNilRows/paramsSummary/symbolName/tintColor/category 扩展（被编辑器/画布/工具箱广泛使用），并非死文件——删除致编译失败，git checkout 恢复。教训：删文件前必须 grep 其内部符号的引用，不能只看文件名/类名
- 审查中发现但**未修**（无功能影响或用户明确决策）：①Force 压力阈值 2.0 > mactic 注释 zP 上限 1.54（用户明确指定，实测可用，若后续 Force 失灵先查此值）；②module 每次执行重建 GraphEvaluator（性能可接受）；③exitPulse/holdingPulse 模块输出声明 unit 但实际传 int 状态值（执行器只看 valid，行为一致）；④每次退出 holding 触发一次 ConfigStore.save（trackedValue 不编码，无害）；⑤ScrollWheelCatcher/DragMonitor 的 excludeRect（paletteFrame .global 屏幕坐标）与 event.locationInWindow（窗口坐标）坐标系不一致——palette 内滚动可能被画布平移拦截，修复需坐标系换算且需真机验证，未动；⑥tick 信号源用 touches.first 的 normY（非 finger.active）——多指时 first 可能是手掌，但改 finger.normY 会让 size/区域闪断中断调节（v10.11 回归），单指场景正确，保持现状

## 历史归档（2026-08-05）
- 2026-08-01 前的全部开发记录已归档至 [docs/ARCHIVE.md](docs/ARCHIVE.md)：管线规划（M1~M8 交付清单）、v6~v9 节点化演进、v1.1.0 架构变更、技术路线（MultitouchSupport.framework）、UI 布局规范、运行方式与分发构建等。
- MEMO.md 仅保留最近状态（当前架构简述 + 最近修复记录），降低认知负载。
