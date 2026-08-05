# 项目备忘录

## 菜单栏「设置」闪退修复（2026-08-05，170 tests 通过）
用户报告点 menubar 菜单 Settings 闪退。排查 4 份崩溃报告（8-01/8-02/8-05），发现**两类不同崩溃**：
1. **B 类（已修）**：8-01-233400 `_swift_reportExclusivityConflict` trap——config 并发独占冲突，9776d66 已修复
2. **A 类（本次修，从 v1.0.0 就存在）**：`openSettings` 内 `objc_retain`/`objc_msgSend` SIGSEGV（8-01-231020、8-02-134145、8-05-141645、8-05-150138 同签名：NSMenuItem action → openSettings → 悬空指针）。4 份崩溃包全部**非 dist 构建**（Documents 裸二进制 / 外部卷 TouchpadGestures 2.app）
- 修复：①菜单项**显式 target=self**（不再依赖响应链解析——无窗口场景下响应链可能解析到异常对象）；②`window.delegate = self` + `windowWillClose` 置 `settingsWindow = nil`（窗口关闭后下次点击重建，避免复用失效窗口状态）
- AppDelegate 类声明加 `NSWindowDelegate`
- 包已重建（dist/ 15:5x）+ 覆盖上传 v2.0.0 release 附件
- 待提交；待用户用最新包复测


## 两会话整合（2026-08-05，170 tests 通过）
另一会话（9776d66 启动/闪退修复 + EngineLog/引擎状态/手势健康红点 + 830791d 诊断日志开关）与我方（诊断模块/语言/形态识别/双模式脚本）已在 830791d 合并提交。审查后补 3 处整合：
1. **elog 语义裂缝修复**：elog 的 EngineLog 写入门槛原只有 diagnosticMinimalTick → 改 `diagnosticMinimalTick || forceDebugLogging`——设置页「诊断日志」开关打开后"进入/退出 holding"也写入 /tmp/touchpad_run.log（与设置页文案一致）；顺带清理 guard 括号残留
2. **EngineLog.contents**：新增锁内读取全部日志内容方法（导出用）
3. **导出诊断包含 run.log**：DiagnosticsModule includeLogs 时除 engine.log（环形缓冲）外，同时导出 EngineLog 的 /tmp/touchpad_run.log 为 run.log（非空才写）——两会话日志体系统一进入诊断包
- 待提交推送


## "权限全绿但触控板无反馈"诊断增强（2026-08-05，170 tests 通过）
用户反馈：UI 正常、媒体键测试成功、权限全绿，但触控板手势无反馈。这类问题的断点（触控板数据链路/设备ID/手势被跳过）此前全部静默。落地：
1. **EngineLog.swift（新）**：诊断日志 stderr + 落盘 /tmp/touchpad_run.log（512KB 上限，超出清空；.app 环境 stderr 用户看不到，落盘后可 tail -f）
2. **设置页「触控板规格」扩展**：引擎状态（运行中 120Hz / 未运行）+ **每手势健康红点**（启用 / 绑定有效 region+event / 图可执行 GraphEvaluator 非 nil）——任一红 = 该手势被引擎静默跳过；AppDelegate.gestureHealth 计算属性
3. **设置页「诊断日志」卡片（发布版可用）**：UserDefaults "engine.debugLogging" 开关 → 立即设置 GestureEngine.forceDebugLogging/NodeExecutors.debugLogging；启动时应用持久化值
4. **triggerHaptic deviceID=0 自愈**：deviceID 为 0（offset 64 部分机型读 0 / IORegistry 时序失败）时重试 mt_device_get_id_by_index(0)，仍为 0 才跳过并记日志——震动静默失效的高频根因之一
5. GestureEngine 暴露 `isRunning`；elog/NodeExecutors.log 改走 EngineLog（保留 DEBUG DiagnosticsLog 环形缓冲）
- 排障路径：设置 → 触控板规格看引擎状态/设备 ID/手势红点 → 开诊断日志 → tail -f /tmp/touchpad_run.log 看 finger/quantize/进入 holding 数据流

## v10.22 可插拔诊断模块（2026-08-05，170 tests 通过）
用户需求：错误收集模块，用户导出诊断包手动发给开发者；**不进正式版本**。
- **方案（用户确认）**：导出诊断包文件夹（用户手动发）+ 收集越详细越好 + 收集项可配置 + 模块可插拔
- **可插拔 = `#if DEBUG` 全包裹**：`swift run`（debug）含诊断模块；`build_app.sh`（release）自动排除——nm 验证 release 二进制诊断符号为 0
- **DiagnosticsLog.swift**（GestureEngine）：环形缓冲（200 条，NSLock 线程安全）；NodeExecutors.log / GestureEngine.elog 统一接入（#if DEBUG 内，release 零开销）
- **CrashCatcher.swift**（TouchpadGestures/Diagnostics）：NSException handler（写完整堆栈）+ signal handler（ABRT/SEGV/BUS/ILL/FPE/TRAP，**async-signal-safe**：只用 open/write/close/strlen/signal/raise + 预构建字符串，崩溃时刻/路径/信号名在 install 时缓存）；崩溃日志写 Application Support/Diagnostics/crash-<时间戳>.log；写完恢复默认 handler 重抛（系统 crash reporter 也记录）
- **DiagnosticsModule.swift**：environmentText（App 版本/macOS/机型 sysctl hw.model/设备 ID/权限/语言/手势数）+ writeDiagnostics（diagnostics.txt + config.json 副本 + engine.log + crashes/ 目录）
- **设置页「诊断（开发版）」卡片**（#if DEBUG）：4 个收集项 Toggle（UserDefaults）+ 崩溃日志待导出提示 + 「导出诊断包…」（NSOpenPanel 选目录 → 生成 TouchpadGestures-Diagnostics-<时间戳> 文件夹）
- AppDelegate.applicationDidFinishLaunching 安装 CrashCatcher（#if DEBUG）
- 测试：DiagnosticsLogTests 4 个（顺序/环形滚动/清空/并发写入）；总 170 tests 全过
- 教训：NSSavePanel 没有 canChooseDirectories（那是 NSOpenPanel 的属性）——选目录用 NSOpenPanel(canChooseFiles=false, canChooseDirectories=true, canCreateDirectories=true)

## 启动/菜单栏/设置闪退修复（2026-08-05，154 tests 通过）
针对上节排查的根因落地修复（commit 待打）：
1. **statusItem 先于触控板初始化创建**：applicationDidFinishLaunching 重构为 setupStatusItem() → 权限请求 → setupTrackpad()；触控板失败不再提前 return（否则 LSUIElement 无 Dock 图标 + 无状态栏图标 = 应用隐身"双击没反应"）
2. **启动时请求输入监控权限**（原只请求辅助功能——未授权时 MTDeviceCreateList 返回空数组 → 设备扫描失败 → 隐身）；PermissionManager 加 onInputMonitoringGranted 边沿回调，授权后自动重试 setupTrackpad()（幂等，trackpadReady 标志）；菜单栏加触控板状态行 + 失败时「重试初始化」菜单项
3. **单实例保护**：ensureSingleInstance（bundleID 匹配 NSRunningApplication），已有实例 → activate 旧实例 + 退出新实例
4. **config 并发保护（"打开设置闪退"根因）**：GestureEngine.config 加 NSLock（getter/setter 锁内读写）；processTick 每帧单次快照 `let cfg = config`（避免多次 getter 之间主线程替换 config → 旧快照索引越界）；退出 holding 写回改 mutateConfig 锁内原子（按 eventID 实时重查 index，避免越界/覆盖用户最新修改）
5. **Cmd+, 不再弹空白设置窗**：TouchpadGesturesApp 加 CommandGroup(replacing: .appSettings) 把系统设置菜单项/快捷键重定向到 openSettings() 手动窗口
6. **forceDebugLogging 默认 false**（v10.16 校准残留 → 有手指时 ~20Hz stderr 日志风暴）
7. quit() 退出前 removeStatusItem
- 保留：`Settings { EmptyView() }` 场景仍存在（仅注册 app 菜单），设置窗口仍走手动 NSWindow（非 bundle 环境兼容，MEMO 历史决策）

## 启动/菜单栏/设置闪退根因排查（2026-08-05，只读分析，未改码）
用户反馈三类概率性问题：①双击 .app 没反应；②启动后菜单栏图标不出现；③菜单栏点击设置闪退。读完 App.swift / mt_bridge.c / GestureEngine / 全部 Views 后的结论：

### A. ①②同根因：applicationDidFinishLaunching 提前 return → statusItem 未创建 → 应用隐身（高置信）
- App.swift L218-241：`guard mt_init()==0` / `guard deviceCount>0` / `guard let dev` 任一失败 → 提前 return，**statusItem 在最后才创建**；LSUIElement=true 无 Dock 图标 → 进程活着但完全不可见 = "双击没反应 / 图标不出现"
- 触发路径：**未授权输入监控时 MTDeviceCreateList 返回空数组**（mactic 文档行为）→ 必走②return；启动时只 requestAccessibility()，**从未请求输入监控权限** → 新机器必现；授权发生在启动后 → 无重试 → 图标永不出现（概率性假象）
- 次要：mt_init/设备扫描/IORegistry 全主线程同步，部分机器启动假死感；桌面机无内置触控板 → 空数组
- 修复方向：statusItem 先于 MT 初始化创建；启动请求输入监控权限；MT 失败不致命（菜单显示状态+可重试）

### B. ③设置闪退：tick 线程与主线程并发写 config → 数组越界/独占访问崩溃（中置信，机制明确）
- GestureEngine.swift L215 在 **tick 队列线程**执行 `config.events[eventIndex] = b.value`（退出 holding 写回），eventIndex 是迭代前 firstIndex 快照；主线程（设置 UI 编辑/updateConfig）同时替换 config → 事件数组缩小后越界 → index out of range / exclusive access trap；用户开设置时 UI 写 config 与 tick 写回撞上概率升高
- 修复方向：config 写回统一回主线程（DispatchQueue.main.async）或串行锁；写回用 boundEventID 实时重查 index + guard

### C. 次要问题（未修）
1. `Settings { EmptyView() }` 场景 + 手动 NSWindow 双轨 → Cmd+, 弹空白设置窗（易误认为 bug/闪退）
2. `GestureEngine.forceDebugLogging = true` 默认开启（v10.16 校准残留）→ 有手指时 ~20Hz stderr 日志风暴
3. 无单实例保护 → 重复双击多实例/多图标
4. build_app.sh 打包顺序正确（先打包未签名再签名再重打包）

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
