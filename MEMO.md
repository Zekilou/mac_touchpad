# 项目备忘录

## v2.1.1 发布记录（2026-10-19）

**主题**：错误自动上报 + 主动反馈（小版本：仅新增上报通道，无手势行为变更）。

版本号 `2.1.0 → 2.1.1`：最右位递增（补丁号），因为本次只新增诊断/上报能力，
手势识别、调节逻辑、配置格式均未变。

- 契约：`docs/debug-upload-contract.md`（端点 `debug.zeki.casa/touchpad-gestures/v1/report`）
- 上报模块：`Sources/TouchpadGestures/Diagnostics/`（正式版常驻，非 DEBUG 独占）
- 测试：`Tests/ReportTests/` 40 个用例（含真实 HTTP 往返）
- 本地验收：`swift run ReportProbe 8787`
- 实测：`kill -SEGV` 后下次启动正确弹出崩溃报告窗口


### 实现细节

把「诊断模块只在开发版」改成**正式版常驻的上报通道**，并按项目作用域隔离。

### 决策
- **进正式版**：崩溃是最需要知道的信息。旧的 `#if DEBUG` 全包裹取消，
  `Diagnostics/` 下模块 release/dev 都编译；区别只在 `scope.channel`（`release` / `dev`）。
- **绝不上传静默**：任何一条报告都要用户在弹窗里点「发送」。这是硬约束，不提供关闭项。
- **作用域**：`debug.zeki.casa` 会接多个软件的上报，**项目名进 URL 路径第一段**：
  `POST https://debug.zeki.casa/touchpad-gestures/v1/report`，
  同时冗余到 `X-Debug-Scope` 头与 body 的 `scope.project`。未知前缀直接拒绝。
- **契约从简**：单个 JSON 文档，没有 multipart。数据的最终读者是人，`jq` 能看即可。
  契约见 `docs/debug-upload-contract.md`，示例见 `docs/sample-report.json`。

### 新增结构（`Sources/TouchpadGestures/Diagnostics/`）
| 文件 | 职责 |
|---|---|
| `ReportScope.swift` | 端点 / scope / token / 限额 / 目录常量（含测试用 override） |
| `ErrorReport.swift` | 契约数据模型、ISO8601 编解码、SHA256 稳定指纹 |
| `DiagnosticsCollector.swift` | 环境快照、日志/崩溃采集、脱敏、组装文档 |
| `ReportUploader.swift` | URLRequest 构造、状态码映射、重试、drafts/outbox 队列 |
| `ReportCenter.swift` | 订阅引擎事件、按指纹聚合、去重、延迟弹窗、上传编排 |
| `CrashCatcher.swift` | 会话标记、NSException/signal handler、面包屑 |
| `ReportWindowController.swift` | 非激活 NSPanel（不抢焦点，不打断手势） |
| `DiagnosticsExporter.swift` | 诊断包导出（不想联网时的替代路径） |

`Sources/GestureEngine/DiagnosticsBus.swift`：引擎侧结构化事件总线（正式版常驻），
让 `ConfigStore` / `GestureEngine` 的内部错误也能进上报链路，而不只是 App 层。

### 弹窗策略（避免打扰）
- 非激活浮动面板，不抢键盘焦点（滑音量时被抢焦点是硬伤）
- 同指纹每会话最多一次；1.5s 内连续错误合并成一次
- **手势 holding 中延后**：等手指离开 1s 后再弹
- 「稍后」保留在本地；「不再提示」仅本会话静默

### 捕获点
崩溃（signal/NSException/异常退出）、配置损坏、配置保存失败、图非法回退、
触控板 init/枚举/句柄失败、触觉设备不可用、辅助功能未授权。

### 主动上报入口
设置 →「反馈与诊断」卡片（主入口）、菜单栏「报告问题…」（设置页打不开时的逃生通道）、
触控板初始化失败时菜单里的「报告此问题…」（上下文直达）。

### 关键修复（实现过程中发现）
1. **`static let` 缓存路径**：`CrashCatcher.diagnosticsDir` 及各文件名常量原先只求值一次，
   测试 override 与换目录都不生效 → 全部改成计算属性。
2. **第二实例删掉主实例的崩溃标记**：`install()` 原先在单实例检查之前执行，
   第二实例退出时 `markCleanExit()` 会删掉正在运行那个实例的标记，真崩溃反而漏报。
   现在单实例检查优先，且只有 `crashCatcherInstalled` 才允许清标记。
3. **首次启动自报崩溃**：`install()` 先写标记再判断，会把自己刚写的标记当"上次崩溃"。
   改为先判断、再写。
4. **崩溃日志互相覆盖**：`O_TRUNC` → `O_APPEND` + pid 后缀。

### 测试
- `Tests/ReportTests/` 新增 38 个用例：指纹稳定性、脱敏、契约字段、请求头/幂等键、
  队列与过期清理、崩溃标记状态机、总线聚合与订阅、**真实 HTTP 往返**（本机 server 收包校验）。
- 验证：`swift build` / `-c release` 均通过；release 二进制含上报符号与错误码字符串。
- 全量 `swift test`：243 + 38，其中 `IdlePowerTests` 3 个失败为**改动前既有**
  （已在未改动工作树上复现，均为 400ms 采样间歇的时序用例，与本改无关）。

### 本地验收
`swift run ReportProbe 8787` → 起本地服务校验路径/头/幂等键/JSON 结构，
配合 `ReportScope.endpointOverride` 可让 App 打到本地而非线上。


## v2.1.0 发布记录（2026-10-10）

**主题**：自定义触觉波形（新功能）+ 系统性缺陷排查与修复（P0/P1/P2 共 20 项）。

版本号 `2.0.3 → 2.1.0`：中间位递增，因为本次含**新功能**（自定义波形）而非仅修复。
自 v2.0.3 起共 9 个提交，49 文件变更（+11655/−305），测试从 222 增至 **242 全绿**。

### 新功能
- **自定义触觉波形**：新增「波形」一级页，可编辑包络（类型/幅度/时长）与音调
  （类型/频率/幅度/时长/延迟）+ 力度乘法器（Light/Medium/Firm），实时预览试听。
  走私有 `MTActuationCreateFromDictionary` + waveformID 83 宿主槽位下发；
  私有符号缺失时自动回退预设波形（保证仍有震动）。

### P0（日常可触发）
- 节点拖动松手位置跳变：`commitDrag` 二次除以 zoom，缩放 ≠1 时跳 1/zoom 倍距离。
- `.toggle` 节点静默空操作：第一遍写 + 第二遍再排取反，帧尾 flush 后净效果等于原值；
  `.set` 同帧可见亦违反摩尔语义。改为统一返回写请求。
- 配置静默重置：任何读取/解码失败都返回默认配置，随后被 UI 编辑覆写回真实文件。
  现改为隔离备份 `config.corrupt-<ts>.json` + stderr 告警。
- `save` 静默吞掉编码错误：`JSONEncoder` 对 NaN 抛错，而参数框接受 `"nan"` →
  之后每次保存静默失效。现返回 Bool 并报错。
- `Int(floor(...))` 溢出崩溃：`stepNorm=1e-30` 时 `1e25` 溢出 Int → trap。
- 退出/重试永久死锁：tick 线程 `main.sync` ↔ 主线程 `tickQueue.sync`。改用
  `CGEventSource.flagsState`（任意线程安全）。
- `stop()` 竞态：清理在 tickQueue 外执行，与迟到回调并发读写同一批字典 → 内存破坏。

### P1
- 移除启动时自动 `tccutil reset`（会摧毁用户已授予的授权并循环弹窗）；改显式按钮。
- `kAXTrustedCheckOptionPrompt` 过度释放；`tccutil` 阻塞主线程。
- `build_app.sh`：`codesign ... | tail` 吞掉签名失败 → 打包未签名 app（加 `pipefail`）；
  `cd` 提前；`mktemp` 替换写死的 `/tmp` 路径。
- `n_fingers` 未钳制 → 越界读；C 侧源头钳制 + Swift 二次钳制。
- 重复节点 id 崩溃：8 处 `Dictionary(uniqueKeysWithValues:)` 遇重复 key 直接 Fatal error。
  根因修复：`TimelineConfig.sanitized()` 解码时去重 + 去悬空边（递归子图）。
- `RegionConfig` 无 `xMin<=xMax` 不变量 → 手势静默失效。新增 `normalize()`。
- 未知 `NodeType`/`Predicate` 降级改为**可见**（保留降级而非抛错：抛错会抹掉全部手势）。

### P2
- 配置写入防抖合并（300ms + 专用队列）：原先拖一个滑杆每帧同步落盘一次。
- 运行时状态淘汰：`runtimes`/`eventBoxes` 与 finger 静态字典原为只增不减。
- 文档修正：README 的 Swift 版本 badge、输入监控（实为可选）、下载物（DMG 非 zip）、
  导航表缺波形页；`.gitignore` 补 `dist/` 与运行时配置。

**验证**：`swift build` 0 error；`swift test` **242 tests / 0 failure**；
`scripts/build_app.sh` 从项目外目录跑通，产出正确签名 app + DMG。

## 功耗优化：触摸结束后引擎永久 120Hz 满耗的根因修复（2026-10-10）

**现象**：运行中的 debug 实例空载常驻 **33–52% CPU**（`top -l 8 -s 1` 连续 8 秒均 >33%），
`sample` 火焰图 100% 落在 `com.touchpad.engine.tick` 线程的 `processTick → GraphEvaluator.evaluate`
（整图求值），即**空载跳帧优化完全失效**。而进程内单元测试里同样的图空载只有 ~0.5%。

**根因（两个叠加缺陷）**：

1. **冻结快照把状态机永久钉在非 idle（主因）**。MT 回调在手指离开后**彻底停止**，
   `latestTouches` 于是**永久冻结在最后一帧**——而真实日志证明该帧常含 `state=6(tap)` /
   `state=4(touch)` / `state=1(start)` 的**残留活动手指**（活动簇收尾帧分布：`present=true
   touching=false n=2` 20 次、`present=false` 18 次、`present=true n=1` 12 次）。
   旧 `canSkipIdleEvaluation` **只看内容不看时间**，于是判定永假 → finger 节点认为"还有手指"
   → 识别状态机卡在 phase 3/4/5 回不到 0 → **120Hz 整图求值永不停止且不自愈**
   （用户唯一解法是重启 app）。进程内测试没复现，是因为测试**没有模拟"回调停止后快照冻结"**。

2. **唤醒频率未被省电收敛**。即便跳帧生效，120Hz 定时器仍在空载时持续唤醒 CPU。

**修复**（`GestureEngine.swift`）：

- `tick()` 增加**快照陈旧判定**：超过阈值无新回调 → 把该帧当**空帧**喂图。
  阈值分两档：非 holding 用 `staleTouchInterval = 0.2s`（与 finger 节点 `staleEmpty` 同源同值，
  两处对"还有没有手指"必须给出一致结论）；**holding 期间放宽到 `holdingStaleInterval = 1.0s`**
  ——这是为保住 **v10.11 的核心修复**：MT 滑动中有采样间歇（实测 holding 期间回调间隔上限仅 ~87ms），
  若按 200ms 判陈旧会在滑动中误判抬起 → 提前退出 holding（用户核心痛点）。
  真实日志验证：holding 窗口内 323 个回调间隔**最大 87ms**，1.0s 留了 >10× 余量。
- `pump()` 双路径：确认空载后进入**慢速时钟（20Hz）**并按真实墙钟整步推进 `simTime`
  （不补跑 1/120 细分步，无追赶螺旋）；`onTouchFrame` 直接 pump 并置 `pendingTouch`
  → 触摸**立刻**恢复全速（响应延迟不受省电影响）；累积不足一步时按真实 delta 推进，
  保证 `now` 严格递增、时间类节点（保持 0.2s / 间隔 0.3s）不被省电带快。
- 诊断辅助：`idleSkipDiagnosis()` / `debugPhases()` / `isClockSlowed`，
  均经 `syncOnTickQueue`（`DispatchSpecificKey` 判自身队列）读取，既避免与 tick 竞争读到半更新状态，
  也避免从 tickQueue 内调用时 `sync` 自锁死。
- `stop()` 复位 `idleSlowed/pendingTouch/tickAccum/lastWall`。
- `setClockSlowed` 用 `.now() + interval` 作 deadline：它由定时器自己的 handler 调用，
  用 `.now()` 会让定时器立刻再到期，多一次无效唤醒。

**验证**（`swift build --build-tests` 0 error；新增 `IdlePowerTests.swift` 6 项回归）：
进程内实测各收尾形态（state=6/4/1/7、双指残留、空帧）在 MT 静默后空载均回落到 **~0.2%**
（修复前同场景 **~40%**）；手指持续接触期间保持全速、触摸能立刻脱离慢速；
holding 期间 400ms 采样间歇后 phase 仍为 4（v10.11 不回归）。

**顺带修掉一个数据安全问题（重要）**：`GestureEngine.config` 的 setter 会无条件 `ConfigStore.save`，
而 `CustomWaveformTests.testWaveformParamEditTakesEffectImmediately` 构造的 `AppConfig()` 用的是
**全新随机 UUID** 却没重定向 `overrideConfigURL` → 每次跑测试都会把"测试用默认配置"写进
**用户真实的 config.json**，把手势/区域/事件 id 全部换掉（本次排查中发现用户配置已因此被覆盖过）。
修复：① 该测试补 `overrideConfigURL`；② `ConfigStore` 增加兜底 `mayPersist`
——测试进程（`XCTestConfigurationFilePath`/`XCTestBundlePath`/`XCTestCase` 任一存在）
未显式重定向时**拒绝写盘**，从机制上杜绝再次污染。已用「跑该测试前后 config.json 哈希不变」验证。

**注意**：`.build` 的 SwiftPM 锁是**全仓库共享**的，另一个会话正在跑 `swift test` 时本会话
`swift build` 会一直等待；本次用 `--scratch-path /tmp/tpg_scratch` 绕开。

**待真机复测**：单击/双击/holding/seek 全手势，确认省电改动对边界时序
（点按后 `gapTimeout` 倒计时、上抬 100ms 判定、cooldown）无影响。

## 自定义波形续查：「count 不实时生效」的定位与三个缓存缺陷（2026-10-10，220 tests 通过）

用户追加反馈：「count 参数根本就不实时起作用，感觉还有很多也是」，且限定场景为**「基础设置」页改、不生效**。

### 先纠正上一轮的不完整结论

上一轮把「整图重建冲掉波形绑定」当成了"改了不生效"的根因。本轮用**用户真实 config.json** 跑完整 `ConfigStore.load()` 做前后快照对比，结果：

```
BEFORE: 右侧/刻度震动  wf=5 count=2 intervalUs=133171
AFTER:  右侧/刻度震动  wf=5 count=2 intervalUs=133171   ← 逐字段一致，未被改写
```

**落盘层与迁移层是干净的**——`count`/`waveform` 正常保留、正常落盘。故上一轮结论只解释了"自定义波形绑定丢失"，**不解释 count 不生效**。教训：**升级函数有没有改数据，要用真实配置跑一遍 load 做前后 diff 来判定，不能只读代码推断触发条件**。

### 本轮确认的缺陷

1. **模块子图 evaluator 缓存永不失效**（`GraphEvaluator.ModuleEvaluatorCache`）：仅以 `nodeID` 为 key，子图内容变化后仍返回旧 evaluator。修复：缓存项增子图快照，精确相等才复用。（注：本用户配置的 haptic 节点在**根图**，此条属防御性修复，非本次现象主因——已如实标注，不冒充根因。）

2. **UI 与引擎的 intervalUs 默认值不一致**（`BasicGestureSettingsView` vs `NodeExecutors`）：
   - UI `grep`：`currentHaptic(title)?.intervalUs ?? 50000` → nil 时**显示 50ms**
   - 引擎：`intervalUs: p.intervalUs ?? 0` → nil 时**实际 0ms**
   - 播放循环：`if i < n - 1 && us > 0 { usleep(us) }` → us=0 **不间隔，背靠背连发**
   后果：`count>1` 且 `intervalUs=0` 时多次触发无间隔，马达合并为一次触感 → **用户调 count 手感不变**，且 UI 显示值与执行值语义不一致。这是「count 不生效」体感最直接的来源。

3. **运行版本核对**：用 `nm` 确认用户实际运行的 Xcode DerivedData 产物已含修复符号（`rebuildTimelinePreservingWaveforms`），排除"跑的是旧版本"。教训：**排查"改了不生效"先确认进程加载的到底是哪个二进制**（`ps` + `lsof`/`nm`），本仓库存在 Xcode DerivedData 与 `dist/` 两处产物，极易混淆。

### 排查方法（可复用）

- **参数消费点审计**：脚本比对 `NodeParams` 全部 54 字段在引擎侧 vs UI 侧的引用数，筛出"UI 可编辑但引擎从不读取"的字段（本轮结果：无死字段，`count` 引擎侧 95 处引用，说明链路通、问题在运行时/物理层）。
- **真实配置回归**：把用户 `config.json` 复制到临时路径，`ConfigStore.overrideConfigURL` 指向它跑 load，前后 diff 关键参数——可一次排除整条持久化/迁移链路。
- 诊断用测试文件用完即删，避免污染测试套件。

### 验证

220 tests 全绿。真机 LLDB 断点确认自定义波形走 ID 83 专用槽、四组参数下发缓冲各异、30 次连发无泄漏。

## 自定义波形：可视化编辑 + 全选择处预览（2026-10-10，213 tests 通过）

**需求**：① 波形栏左侧 + 可视化编辑波形；② 所有选择波形的地方旁边有缩略预览图。

**落地**：
- **模型** `Models/CustomWaveform.swift`：`WaveformSpec`（包络 + 音调 + 按压力度乘法器，`dictionary()` 产出 Apple 产线同构字典）、`CustomWaveform`（id/name/spec）、`WaveformPresetCatalog`（预设 1~16 参数，源自 `MTActuatorGetProductionPlist` 导出的 134KB 定义表）、`WaveformPreview`（纯函数采样，可测试）。
- **桥接** `mt_actuate_custom(deviceID, mt_waveform_t)`：按参数现场编译波形 → `MTActuationCreateFromDictionary` → `MTActuationActuate`（实测走宿主自定义槽 **waveformID 83**，与预设 1~64 互不干扰）。软解析两个私有符号，缺失返回 -1 由调用方回退预设（-2 = 参数/设备问题，不回退以免双震）。
- **引擎**：`TimelineEffects.triggerHaptic` 增 `customWaveformID`；`GestureEngine.triggerHaptic` 按 id 从 **live config** 解析 spec；`previewWaveform` 供试听（不走 30ms 节流）。
- **UI**：新增一级导航「波形」= 左波形栏（预设/自定义各带缩略图 + 新建）+ 右可视化编辑器（`InteractiveWaveformCanvas` 可**拖拽控制点**改包络/音调，另有滑块精调、按压力度档位预览、试听、另存为自定义、删除解绑）。`WaveformPickerRow` 统一「预设/自定义 + 缩略图」，接入基础设置触觉卡片与画布节点参数面板。
- **配置**：`AppConfig.customWaveforms`（自定义 Codable，旧文件缺键回退空数组）；`NodeParams.customWaveformID`（非 nil 优先于预设 waveform ID）。

**用户反馈「改了波形参数但手感不变」→ 两个独立根因（均已修复 + 回归测试）**：

1. **`upgradeForcePress` 误判导致整图重建冲掉绑定**（`GestureConfig`）：判定条件 `waveform != 3` 有两个误判来源——① 用户改用自定义波形时预设 ID 被忽略 → 恒真；② 用户**关闭**进入震动（节点删除）→ `nil != 3` 也真。结果每次 load 都判定"旧图"→ `TimelineMigrator` 整图重建 → `customWaveformID` 丢失（迁移器参数模型里没有该字段）→ 预览图变了但实际永远回退预设。修复：三条件同时成立才算旧图（节点存在 && 无自定义绑定 && 预设非 3）。**并加通用保护** `rebuildTimelinePreservingWaveforms`：快照/恢复 haptic 标题→波形 ID 绑定，**全部 5 处整图重建升级**统一走它。教训：**整图重建式迁移必须白名单式保留「迁移器不认识的新字段」，否则每次启动静默回滚用户编辑**。

2. **执行器缓存从不失效 → 编辑图后仍跑旧图**（`GestureEngine`）：`GraphEvaluator` init 时**拷贝** timeline 并预计算入边索引（其注释明写"生命周期内不可变"），而 `runtimes` 按 `gesture.id` 缓存、**只在 stop() 清理**。用户在画布/波形页改波形引用、调参数、连连线后 id 未变 → 继续执行旧图。修复：`Runtime` 增 `graph: TimelineConfig`，`runtime(for:)` 用**精确相等**（非 hashValue，避免碰撞导致少数编辑静默失效）判断重建；重建时保留 `store` 与 `wasHolding`，避免清空 baseline/transform.last 导致手感跳变。教训：**以「实体 id」为 key 缓存派生自可变数据的对象时，必须同时保存其数据快照并做变更检测**——这是"界面变了但行为不变"这类幽灵 bug 的通用温床。

**验证**：213 tests 全绿（新增 26）。真机 LLDB 断点抓 `MTActuatorSetWaveform` 确认四组不同参数下发的硬件缓冲各异（`amp 10→35` = byte1 `0a→23`；`freq 0.1/3.6kHz` = byte7 `ef/06`），且全部走 ID 83；30 次连发无泄漏。

**已知限制**：预览曲线是参数近似（Apple Default 表中 ID 1/3/5、2/4 参数重复，真实差异来自固件与机型覆盖表）；采样缓冲是内部分压缩编码，只能做"包络+音调合成"，不能播放任意 PCM。

## 空载跳帧优化：无触摸且全 idle 时跳过整图求值（2026-09-11，187 tests 通过，空载 CPU 25–28% → ~0.4%）

**目标**：上一节模块缓存修复后空载仍 ~25–28%，进一步深挖「遗留」项——`processTick` 按 120Hz 对全部启用手势整图求值，与是否有触摸无关。

**修复**（GestureEngine.swift）：
1. `tick()` 增加空载快速路径：`canSkipIdleEvaluation(touches:)` 为真时直接 `associateMouse()` 后 return，不调用 `processTick`。
2. `canSkipIdleEvaluation` 判定：**无原始活动手指**（`state != 0 && state != 7`）+ **所有已启用手势停在 idle**（`store["phase"]` 为 nil 或 0，且 `!wasHolding`）。
3. **安全不变量**：任何待处理的「时间驱动转移」（`gapTimeout` 的 `firstTapUp→idle`、上抬 100ms 检测、`staleEmpty` 200ms 兜底）都必然对应 `phase != idle`，因此 idle 时跳帧不会漏掉这些转移；一旦相位离开 idle 立即恢复逐帧求值。
4. `simTime` 仍在 `pump()` 中推进（与是否跳帧无关）→ `frame.now` 保持连续，恢复求值时不丢时间。
5. 顺手把 `processTick` 末尾的鼠标锁定块抽成 `syncCursorLock()`，跳帧路径只需 `associateMouse()` 保证 residual 锁定被释放。

**验证**：
- `swift test` **187 全过**（状态机语义无回归）。
- release 重打包、app 签名有效（`codesign -dv` 通过）。
- 空载实测：`top -l 6 -s 1 -pid` = **0.0/0.3/0.4/0.4/0.4/0.4%**；`ps` 25s CPU 时间增量 0.13s（≈0.5%）。修复前同路径基线 25–28% → **约 50–80× 降幅**。
- 残留 ~0.4% 主要是 120Hz `DispatchSourceTimer` 唤醒 + 空载判定的固定开销（非图求值）。

**注意**：`scripts/build_app.sh` 在沙箱内执行会在 DMG 步骤失败（`/dev/disk5` 受限，hdiutil 需设备访问）；`.app` 已组装+签名成功，仅 DMG 需在沙箱外补跑。

**待真机复测**：单击/双击/holding/seek 全部手势，确认跳帧在边界时序（点按后 `gapTimeout` 倒计时、上抬 100ms 判定、cooldown）下行为不变。


## 模块子图 evaluator 每帧重建 → 空载 CPU 回归修复（2026-09-11，187 tests 通过）

**现象**：新增 seek/上下边缘手势后，app 空载 CPU 飙到大盘 ~52–57%（`top`/活动监视器）。

**定位**：`sample <PID> 3` 火焰图显示 `com.touchpad.engine.tick` 主热点在 `NodeExecutors.execute` 的 `.module` 分支——**每个 module 节点每帧都 `GraphEvaluator(timeline: sub)` 重新构造子图执行器**（3s 内 `GraphEvaluator.init` 被调 464 次），每次构造都做 `TimelineGraphValidator.topologicalOrder`（拓扑校验）+ `NodeConfig` 深拷贝（`initializeWithCopy for NodeConfig` / `_platform_memmove`）。

**修复**（GraphEvaluator.swift + NodeExecutors.swift）：
1. `GraphEvaluator.init` 预计算入/出边邻接索引 `incomingByNode`/`outgoingByNode` + `nodesByID`，替换每帧对 `timeline.edges` 的 O(E) `filter`（原调用 `Timeline.incomingEdges/outgoingEdges`）；`evaluate` 内不再每帧重建 `nodesByID`。
2. 新增 `ModuleEvaluatorCache`（module 节点 UUID → 子图 `GraphEvaluator` 缓存），`GraphEvaluator` 持有实例并传入 `NodeExecutors.execute`（新增 `moduleCache` 参数）；`.module` 分支改为 `moduleCache?.evaluator(forNodeID:subgraph:) ?? GraphEvaluator(timeline: sub)`，首次构建后逐帧复用。

**验证**：`swift test` **187 全过**（语义无回归）；release 重打包。修复后空载 CPU **~25–28%**（`top -l 8 -s 1`：27.3/28.2/26.9/28.1/26.1/24.6），修复前同路径基线 52%；tick 火焰图中 `GraphEvaluator.init` / `topologicalOrder` 计数归零。

**遗留（既有设计，非本次回归）**：`GestureEngine.processTick` 按 120Hz 固定步长对**全部启用手势整图求值**（与是否有触摸无关），构成剩余 ~27% 空载开销主因。如需进一步降耗可考虑「无触摸且非 holding 时跳过图求值」，但需评估对含超时/时间类节点状态机的影响——**待定，未实施**。

## 新增媒体进度事件（seek）+ 上下边缘手势（2026-09-11，187 tests 通过）

用户要求：触控板上/下边缘横向滑动 → 控制**当前焦点 App 的媒体进度**（视频/音乐快进快退）；上边缘启用，下边缘先配置但不启用。

- **可行性结论（已调研）**：`AXUIElement`（辅助功能 API）是 Apple 公开合法 API（非私有），Keyboard Maestro / axcli / Swift Wright 等商用+开源产品在用；对原生 AppKit/SwiftUI app（QuickTime/Music/Spotify）可靠，Electron/自绘渲染 app 可能找不到滑块 → 用**方向键回退**兜底。权限**不需要新申请**，与 CGEventTap 同属已有「辅助功能」TCC 类别。
- 选择**相对映射**而非绝对：AX 写 AXSlider 的 AXValue（0~1 绝对比例）+ 找不到时发 ←/→（keyCode 123/124）相对步进。
- **ActionType** 新增 `.seek`（displayName/shortName）；`EventConfig.defaultSeek`（step 0.05、boundaryThreshold 0.001、directionRule positiveIncrease=右滑快进、executionMethod .direct）。
- **SystemControl** 新增：`findSlider`（递归 AX 树找 AXSlider，maxDepth 8 防深树卡死）+ `findSeekSlider`（按 frontmostApplication + 5s 缓存，避免每 tick 遍历 AX 树 ~10-50ms）+ `getSeekPosition() -> Float?` + `setSeekPosition(_:) -> Bool` + `seekForward()/seekBackward()`（CGEvent 方向键，复用 20ms 全局节流）；新增测试钩子 `mockSeekPosition`/`mockSetSeekOK`。
- **EventConfig.consume**：mediaKey 分支加 `.seek`（发方向键，不做 trackedValue 推进）；direct 分支加 `.seek`（AX 写值成功即信任并 return .normal，**不做边界检测**——进度由 app 自己 clamp）；`postBoundaryKeyIfNeeded` 的 seek 分支为 no-op。
- **RegionConfig** 新增 `defaultTop`（x 0.2~0.8, y 0~0.2）/ `defaultBottom`（x 0.2~0.8, y 0.8~1）。**x 限中段的原因**：左右边缘区域是全高（y 0~1），若上下边缘全宽则**四角形成面积重叠** → 同一次触摸会同时落入两个手势区域、同时调两个事件。注意：矩形平铺下相邻区域仍共享**边界线**（测度零，无法消除），测试断言的是「重叠面积为 0」而非「无共享边界点」。
- **AppConfig.init()**：regions 加 top/bottom，events 加 seek，gestures 加「上边缘」（启用，`LegacyPipelineConfig(signalSource: .normX)` 横向信号）与「下边缘」（enabled: false 预留）。
- **ConfigStore.ensureEdgeSeekGestures(&cfg)**：旧配置启动时补齐 seek 事件 + 上下边缘区域 + 两个手势（上启用/下不启用），已有同名不重复添加；在 `load()` 的 Force 补齐之后调用。
- **EventTabView**：执行方式/步长说明文字对 seek 特化（原文案说「写 CoreAudio/IOKit 寄存器」对 seek 是错的）；seek 时隐藏「边界检测」卡片（无意义）。`postBoundaryKeyOnEnterIfNeeded` 对 seek 直接 return（无系统 HUD，且进入 holding 时不必遍历 AX 树）。
- 测试：`testActionType_allCasesCount` 2 → 3 并补 seek 断言；新增 seek consume 正/反向、mock 读写钩子、defaultSeek 配置、默认区域 y 范围、默认区域**零重叠面积**、默认配置含上下边缘手势（上启用/下不启用 + normX）共 7 个。
- 验证：`swift build --disable-sandbox -c release` 成功；`swift test` **187 全过**（原 180 + 7）。
- 待真机验证：找 QuickTime/Safari(YouTube)/Spotify 播放中，上边缘横向滑动是否改变进度（找不到 AXSlider 会自动回退 ←/→）。
- 已知局限：方向键回退对 Music.app 是「上一首/下一首」而非进度（app 行为差异，非 bug）；Electron/自绘渲染 app 无 AXSlider 时走回退。

## v2.0.3 发布（2026-09-02，commit af3933d）

已发布 GitHub release `v2.0.3`：<https://github.com/Zekilou/mac_touchpad/releases/tag/v2.0.3>

- 资产：`TouchpadGestures.dmg`（1.6M，UDZO 拖入式，ad-hoc 签名，macOS 14+）

- 本次版本包含两项改动：

  1. **DMG 分发替代 zip**：build\_app.sh 打包改为 `hdiutil create -format UDZO`（内含 app + Applications 软链拖入）；删除仅 zip 分发需要的 `AppTranslocation.swift`（4 个私有 API 函数：转移检测/建议移入/目标路径/取回原始路径）+ `AppTranslocationTests.swift`（8 tests）；AppDelegate 移除 `handleTranslocationSelfHeal()`/`offerMoveToApplicationsIfNeeded()` 及 4 个相关方法；`ensureSingleInstance()` 移除为移入流程服务的 `/AppTranslocation/` 过滤。
  2. **Option+Shift 精准调节修复**：`SystemControl.postMediaKey` 合成媒体键时**不再把 modifierFlags 写死**，改为主线程读 `NSEvent.modifierFlags` | mediaMask 叠加注入——⌥⇧+滑动进入系统原生 1/4 档、Shift+音量静音、⌥+亮度精准档等全部自然恢复。

- 版本号 bump：`scripts/build_app.sh` VERSION 2.0.2 → 2.0.3（dev 同步为 2.0.3-dev）

- 提交：`af3933d`（chore(release): v2.0.3），annotated tag `v2.0.3` 已推送 main + 标签。

- 验证：`swift build` 成功；`swift test` 180 全过（原 188 - 删除的 8）；DMG 签名校验通过。

## 物理键盘 Option+Shift 精确调节修复（2026-09-02，180 tests 通过）

用户原说要加「旁路开关模拟 Option+Shift」，但实际根因是：**物理键盘上手动按 Option+Shift 同时滑触控板，精确调节不生效**。

- 根因：`SystemControl.postMediaKey` 合成 `NX_SYSDEFINED subtype=8` 媒体键事件时，把 `modifierFlags` **硬编码为** **`0xA00（keyDown）/ 0xB00（keyUp）`**（系统要求的媒体键私有掩码），直接覆盖了物理键盘当前真实的修饰符状态 → macOS 完全看不到按着 Option/Shift，自然不进入精确档位。

- 修复：每次合成事件前，在主线程读 `NSEvent.modifierFlags`（必须主线程，否则返回空集合；媒体键由 tick 线程调用，使用 `DispatchQueue.main.sync`），把真实修饰符按位或 `| mediaMask`，既保留媒体键需要的私有掩码，又叠加了物理键盘的 ⌥/⇧/⌃/⌘。所有系统原生组合（⌥⇧+音量精确 1/4 档、Shift+音量静音、⌥+亮度精确档等）在触控板触发时全部自然恢复，不需要任何开关。

- 验证：`swift build --disable-sandbox -c release` 成功（仅历史 kIOMasterPortDefault 弃用警告，与本改无关）；`swift test` 180 全过。

- 待用户真机复测：按住物理键盘 ⌥+⇧，触控板滑动调音量/亮度 → HUD 应走 1/4 格小步进（系统原生精确档）。

## 分发改为 DMG 拖入 + 移除 App Translocation 引导（2026-08-31，180 tests 通过，DMG 已打包）

用户要求：把分发方式从 zip 改成 dmg 拖入；去掉「引导拖入」相关代码（zip 分发时才需要，app 被 App Translocation 转移到随机路径才触发）。

- **build\_app.sh**：zip 打包（ditto）替换为 DMG——Ad-hoc 签名后在暂存目录放 `TouchpadGestures.app` + `Applications -> /Applications` 软链，`hdiutil create -volname TouchpadGestures -srcfolder <staging> -ov -format UDZO` 生成 `dist/TouchpadGestures.dmg`；删除旧 zip。已挂载验证：DMG 内含 app + Applications 拖入链接，codesign 有效。

- **删除** `Sources/GestureEngine/AppTranslocation.swift`（isRunningTranslocated/shouldOfferMoveToApplications/applicationsDestination/originalURLWhenTranslocated）与 `Tests/GestureEngineTests/AppTranslocationTests.swift`（8 tests）。

- **App.swift**：`applicationDidFinishLaunching` 移除 `handleTranslocationSelfHeal()`/`offerMoveToApplicationsIfNeeded()` 调用；删除 `offerMoveToApplicationsIfNeeded`/`handleTranslocationSelfHeal`/`moveToApplications`/`showMoveError` 四个方法；`ensureSingleInstance()` 移除「排除 /AppTranslocation/ 路径」过滤（原为移入流程服务）。

- 验证：`swift build --disable-sandbox -c release` 成功（仅原 onChange 弃用警告）；`swift test` 180 全过（原 188 - 8）；`build_app.sh` 产出 DMG 并挂载签名校验通过。

- 注意：DMG 拖入后 app 位于 /Applications 稳定路径，TCC 权限（辅助功能）按路径+签名匹配可跨启动保留，不再需要「建议移入」引导。

## v2.0.2 发布（2026-08-31，commit 83c9614）

已发布 GitHub release `v2.0.2`：<https://github.com/Zekilou/mac_touchpad/releases/tag/v2.0.2>

- 资产：`TouchpadGestures.zip`（ad-hoc 签名，macOS 15+）

- 修复：**App 转译自愈**（新增 AppTranslocation.swift，路径+CDHash 匹配 TCC 解决「已允许仍未授予」）、**输入监控降级为可选提示**（辅助功能为唯一必需项，启动不再弹输入监控授权窗）、**关闭设置窗口不再退出**（applicationShouldTerminateAfterLastWindowClosed→false）、**build\_app.sh 加 --disable-sandbox** + 版本号 2.0.1→2.0.2。

- 提交：`83c9614`（fix(permissions)），annotated tag `v2.0.2` 已推送 main + 标签。

## 「关闭设置窗口程序退出」修复：菜单栏 app 常驻（2026-08-31，188 tests 通过，release 已打包）

用户报「关闭设置窗口程序退出」。根因：SwiftUI `App` 生命周期默认把「最后一个窗口关闭」实现为终止应用（`applicationShouldTerminateAfterLastWindowClosed` 默认 true），而本 app 是菜单栏（LSUIElement）app、唯一窗口是手动创建的设置 NSWindow → 关闭即退出。

- **App.swift**：`AppDelegate` 新增覆盖 `applicationShouldTerminateAfterLastWindowClosed(_:) -> Bool { false }`——关闭设置窗口后进程存活（状态栏图标仍在，可从菜单再开设置/退出）。

- 验证：`swift build --disable-sandbox -c release` 成功；188 tests 全过；release 包已重建 `dist/TouchpadGestures.zip`。

- 待用户复测：打开设置 → 关闭 → app 不应退出，菜单栏图标仍在。

## 「输入监控显示未授予但软件正常」修复：降级为可选提示（2026-08-31，188 tests 通过，release 已打包）

用户报「Input Monitoring 显示未授予，但软件能正常用」。查证：app 读触控板走 `MTDeviceCreateList`（MultitouchSupport 私有框架），**不受 TCC 输入监控门控**；事件合成走 `CGEventTap` 仅被**辅助功能**门控 → app 真正必需的只有「辅助功能」，输入监控是误导项。按用户选择「降级为提示」落地：

- **PermissionManager.swift**：`autoResetAndReprompt()` 只重置「辅助功能」（不再请求输入监控）；新增 `requestRequiredPermissions()`（仅请求辅助功能）；`allGranted` 改为只看 `accessibility.isOK`；新增 `onAccessibilityGranted` 回调 + `wasAccessibilityGranted` 边沿检测（授权瞬间触发）。

- **App.swift**：启动改调 `requestRequiredPermissions()`；重试回调从 `onInputMonitoringGranted` 改为 `onAccessibilityGranted`（授权后自动重试触控板初始化，无需重启）。

- **ConfigView\.swift**：辅助功能移到权限栏顶部（唯一必需项）；输入监控改 `optionalPermRow`（状态中性色 + info 备注「不影响触控板，无需授权」）；新增 `optionalPermRow` builder。

- 验证：`swift build --disable-sandbox -c release` 成功；188 tests 全过；`build_app.sh` 打 release 包完成。

- **build\_app.sh 修正**：三处 `swift build` 加 `--disable-sandbox`——代理终端环境 SwiftPM 子进程沙箱 `sandbox-exec: Operation not permitted` 会导致打包失败；该标志对用户本机正常构建无副作用。

- 待用户复测：权限面板应显示「辅助功能」为必需、输入监控为「可选，不影响触控板」；启动不再弹输入监控授权窗。

## 权限"已允许仍未授予"落地实现：自动除转移+自愈（2026-08-31，188 tests 通过，待用户复测打包）

按用户选择（「自动除转移+自愈」「权限异常自动重置」「暂不，保持 ad-hoc」）完成，参照 Mac Mouse Fix 的 `AppTranslocationManager.m`（SecTranslocate 私有 API 自愈）与 `AccessibilityCheck.m`（tccutil 清授权再重加）：

- **AppTranslocation.swift**：新增 `originalURLWhenTranslocated(bundleURL:)`，`dlopen` Security 框架 + `dlsym` 调 `SecTranslocateIsTranslocatedURL`/`SecTranslocateCreateOriginalPathForURL`；未转移/私有 API 缺失一律回退 `nil`（优雅降级到手动引导）。

- **PermissionManager.swift**：新增 `autoResetAndReprompt()`（`tccutil reset InputMonitoring/Accessibility <bundleID>` 清旧授权 → 重新请求两权限 → 1.5s 后刷新）、`scheduleAutoResetIfNeeded()`（启动后 3s 若未全授权则自动自愈一次，每进程一次）、私有 `resetTCC(service:)`（调 `/usr/bin/tccutil`）。

- **App.swift**：`applicationDidFinishLaunching` 在 `offerMoveToApplicationsIfNeeded()` 前先 `if handleTranslocationSelfHeal() { return }`——检测到转移路径则取回原始路径 → 移入 /Applications → 去隔离 → 重启 → 退出当前实例（无感，无需用户操作）；权限请求后调 `permissionManager.scheduleAutoResetIfNeeded()`。`moveToApplications` 重构为 `moveToApplications(source:destination:)`，自愈与手动引导共用。

- **ConfigView\.swift**：权限栏新增「重置授权」按钮（权限未全绿时显示），点击调 `permManager.autoResetAndReprompt()`，带 L10n 双语。

- **AppTranslocationTests.swift**：新增 `testOriginalURLWhenTranslocated_nonTranslocatedPath_returnsNil` 验证私有 API 优雅降级。

- **约束**：ad-hoc + TCC 按「路径+CDHash」匹配是根因（见下节诊断），以上是无稳定签名下的组合规避；彻底根治仍需稳定 Developer ID 签名。`tccutil` 在助手沙盒不可执行，需用户在本机 Terminal 手动跑或点 app 内「重置授权」按钮。

- 验证：`swift build` 成功（仅原有 onChange/未用变量警告）；`swift test` 188 全过（原 187 + 新 1）。

## 开源鼠标/触控板工具如何解决「已授权仍未生效」研究（2026-08-31，只读研究未改码）

克隆 `/tmp/mac-mouse-fix` 与 `/tmp/linearmouse` 全源码核对，结论（供 TouchpadGestures 权限问题参考）：

- **A. 权限 API**：两仓库**均未使用** `IOHIDCheckAccess`/`listenEventAccess`/`InputMonitoring`（grep 无匹配）；都只依赖**辅助功能** `AXIsProcessTrustedWithOptions`，因事件拦截走 `CGEventTap`（仅被辅助功能门控）。MMF 权限在 **Helper 进程**（`Helper/AccessibilityCheck.m` `checkAccessibilityAndUpdateSystemSettings`，`kAXTrustedCheckOptionPrompt=false`）；LM 在 `LinearMouse/AccessibilityPermission.swift`（`enabled`/`prompt()`/`pollingUntilEnabled`）。

- **B. 未授权引导**：MMF 检测失败→`tccutil reset Accessibility <helperBID>` 清旧权限再重加（Ventura/Monterey 开关打不上 bug），每 0.5s 轮询授权后重启 Helper；UI 走 `AuthorizeAccessibilityView.m` + Deep Link `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`；检测「奇怪 Helper」重复副本弹 `Alerts.m` 持久提示。LM 弹 `AccessibilityPermissionWindow`，未授权则 `exit(0)`，授权后 `Application.restart()`；无「提示移 app」形式化 UI（**未找到**）。

- **C. 签名**：MMF 源码 pbxproj 主 app 与 Helper 均 `CODE_SIGN_IDENTITY="Apple Development"; CODE_SIGN_STYLE=Automatic; DEVELOPMENT_TEAM=LM5Z78756B`（**未找到** Developer ID）——源码默认开发签名，作者注释指出 2.2.0→2.2.1 由 Development 切 Developer Program 签名导致权限开关失效。LM 发布用稳定签名：`ExportOptions.plist` `developer-id`/`Developer ID Application`/`Manual`/`Team C5686NKYJ7`，`Scripts/sign-and-notarize` codesign+notary+staple，`Scripts/configure-code-signing` 优先 Developer ID→Apple Development→**ad-hoc 回退**。

- **D. Helper/launchd/SMAppService**：MMF **有** SMAppService 注册的 launch agent（`HelperServices.m` `agentServiceWithPlistName:@"sm_launchd.plist"` + `sm_launchd.plist` Label=`com.nuebling.mac-mouse-fix.helper`，内嵌 `Contents/Library/LoginItems/Mac Mouse Fix Helper.app`，RunAtLoad+KeepAlive），**无** root daemon；LM 用 `LaunchAtLogin`（SMAppService 登录项），**未找到**任何 `/Library/LaunchDaemons` 安装逻辑。

- **E. App Translocation**：两者都处理。MMF `AppTranslocationManager.m` 用 `dlopen`+`dlsym` 调 Security 私有函数 `SecTranslocateIsTranslocatedURL`/`SecTranslocateCreateOriginalPathForURL`，被转移则 `xattr -cr` 去隔离 + `open -n -a` 重启 + `terminate`（在 `AppDelegate +initialize` 先于 MessagePort 执行；注释指向 Sonoma issue #648）。LM `AppDelegate.swift` `#if !DEBUG if AppMover.moveIfNecessary() { return }`（`AppMover` 包自动搬到 /Applications，仅 release 生效）。

- **对用户项目借鉴**：ad-hoc+TCC 按「路径+CDHash」匹配是根因；成熟工具用①稳定 Developer ID 签名②SMAppService 稳定身份注册③自动去 App Translocation 组合规避。轻量替代可用 `LaunchAtLogin`，彻底解决需稳定 Developer ID（非 ad-hoc）。

## 「双击仍打开旧版/老实例重现」根因与清理（2026-08-31 晚）

用户质疑：明明开了新版，为什么又跑回老的 `TouchpadGestures 2.app`。查明真相：

- **真因 = LaunchServices 重复注册 + 残留进程**：同 bundleID `com.zekiwithcat.TouchpadGestures` 的副本散布在 `~/Downloads`、`dist`、`/Applications`、`AppTranslocation/`、`~/.Trash`，注册表里 20+ 条同 bundleID；macOS LaunchServices 习惯把启动路由到「最近注册」的副本，`open`/双击可能命中旧副本。

- **残留进程**：`TouchpadGestures 2.app` 源文件已移入废纸篓，但进程（PID 26141，PPID=1 被 launchd 托管）未退出，路径字符串仍挂 `TouchpadGestures 2.app` → 用户看到「老版」。

- **处理（仅 lsregister 取消注册 + kill，未删文件）**：①`kill` 残留老进程 ②把非 `/Applications/TouchpadGestures.app` 的全部副本从 LaunchServices `lsregister -u` 注销 ③`lsregister -f` 重新注册唯一新版 ④重启新版。

- **验证**：注册表只剩 `/Applications/TouchpadGestures.app`；运行实例 PID 27425 路径正确且稳定。

- **经验**：①ad-hoc app 多副本/多 Trash 副本会污染 LaunchServices 路由，双击"回到旧版"优先查 `lsregister -dump` + `pgrep` 残留进程 ②杀进程后再改文件才干净，先移文件后 kill 会留下挂旧 inode 的活进程。

## 权限"已允许仍显示未授予"诊断（2026-08-31 续，待用户复测）

用户报告：已在系统设置允许权限，但 app 仍显示"未授予"。查运行实例后确认根因：

- 运行中实例：`/Applications/TouchpadGestures 2.app`（PID 14662，bundleID `com.zekiwithcat.TouchpadGestures`，ad-hoc 签名，CDHash `9f4de8d0...`，无隔离属性，二进制为最新 dist 构建）

- 存在另一份旧拷贝 `~/Downloads/TouchpadGestures.app`（CDHash `54a4d55a...`，旧二进制）

- **ad-hoc 签名 app 的 TCC 按「路径 + 签名身份(CDHash)」匹配，而非仅 bundle ID** → 用户授权的是另一份拷贝，运行中的这份其实未授权 → 显示未授予。

- 用户已选择方案：「重置授权并引导重开（推荐）」。

- 已查：用户级 TCC.db 不存在；系统级 TCC.db 受 SIP 保护无法读取（需 Full Disk Access）。改用 CDHash/进程比对绕过。

- 操作：`tccutil reset InputMonitoring com.zekiwithcat.TouchpadGestures` + `tccutil reset Accessibility com.zekiwithcat.TouchpadGestures`，随后引导用户在系统设置重新授权「运行中的那份」。

- **执行受阻**：助手运行环境为沙盒，`tccutil` 返回 `Operation not permitted from sandbox`、`sudo` 被禁 → 无法代为执行。需用户在本机 Terminal 手动跑上述两条命令（用户自有 app，无需 sudo）。

## App Translocation 移入引导（2026-08-31，187 tests 通过，release 已打包）

用户报告 GitHub 下载的 v2.0.1 权限"开了开关仍显示未授予"。根因：带隔离属性从网上下载的 .app 被 macOS **App Translocation** 复制到随机只读路径（每启动路径变一次），TCC 权限（输入监控/辅助功能）按「签名身份+路径」绑定 → 授权落在随机路径上，下次启动路径已变被当成另一个 app → 显示未授予。无稳定签名下官方/生态推荐做法 = 把 app 放稳定位置（/Applications）+ 去隔离属性。

- **AppTranslocation.swift（新，GestureEngine）**：纯可测逻辑 `isRunningTranslocated`/`shouldOfferMoveToApplications`/`applicationsDestination`（判定转移、是否建议移入、目标路径）。配套 7 个测试。

- **AppDelegate 接入（App.swift）**：`applicationDidFinishLaunching` 在 `setupStatusItem()` 后调用 `offerMoveToApplicationsIfNeeded()`（弹窗文案走 L10n 双语；「不再提示」持久化 UserDefaults `appTranslocation.neverOfferMove`）。`moveToApplications()` 执行：拷贝到 /Applications → `xattr -cr` 去隔离 → `NSWorkspace.open` 启动新实例 → 0.5s 后 `quit()` 退出旧实例。

- **单实例修复**：`ensureSingleInstance()` 过滤掉路径含 `/AppTranslocation/` 的实例——否则移入后从 /Applications 重启的新实例会被旧转移实例误杀（同 bundleID）。

- `shouldOfferMoveToApplications` 宽松覆盖「非 /Applications 下的任何 .app」（含下载目录双击），`swift run` 裸二进制无 .app 后缀不误触发。

- 构建：`swift build -c release` 成功（仅原有 onChange deprecation 警告）；`./scripts/build_app.sh` 打包 dist/TouchpadGestures.zip（ad-hoc 签名，macOS 15+）。

- 待用户复测：从下载 zip 解压双击 → 应弹「建议移入应用程序」；移到后权限应跨启动保留。

## v2.0.1 发布（2026-08-29，commit 0b849c7 + aceef9b）

已发布 GitHub release `v2.0.1`：<https://github.com/Zekilou/mac_touchpad/releases/tag/v2.0.1>

- 内容：H1/H2/H3 三项高危修复（见下），180 tests 全过

- 产物：`dist/TouchpadGestures.zip`（ad-hoc 签名 .app，macOS 15+）

- 提交：`0b849c7`（fix 三项高危）+ `aceef9b`（chore 版本号→2.0.1）

- 标签：`v2.0.1`（annotated，已推送）

- 备注：build\_app.sh 依然存在「无条件多跑一次 swift build -c release」的小问题（DEV 记录），本轮未动；
  本次打包已把版本号 2.0.0→2.0.1 同步到 release/dev 分支。

## 高危修复完成（2026-08-29，180 tests 通过，debug+release 均构建成功）

应需求"开始"按优先级修复全面审视的问题。已完成 H1/H2/H3 三项高危：

- **H1 v2 迁移路由不可达**：ConfigStore.load 改为先按顶层 version 分流（<3 先走 v2/v1 迁移），不再先 decode v3 被宽松成功。已补回归测试。

- **H2 module 节点无子图 → 无限递归**：TimelineConfig 新增模型层 `subgraph(at:)`/`updatingSubgraph(at:to:)`/`ensuringModuleSubgraphs()`（public）；视图层 `currentTimeline` 改用 `timeline.subgraph(at:modulePath) ?? timeline`、`canvasBinding` 用 `timeline.updatingSubgraph(at:to:)`、`openModule` 加 guard（非 module/无子图拒绝进入）、`addNode` 对 `.module` 初始化空子图、删除旧 `timelineAt`/`updatingTimeline`；ConfigStore.load 加载时对每个手势 `ensuringModuleSubgraphs()` 补全缺失子图。新增 TimelineSubgraphNavigationTests 9 个测试。

- **H3 拖动命中区含端口行 → 无法连线**：TimelineCanvasView\.hitTestNode 命中区收窄到仅头部（headerHeight），端口行/编辑器区放行给 SwiftUI 连线手势（此前含端口行，DragMonitor 消费 mouseDown 导致只能拖节点）。**需真机验证**连线/拖动手感。

- 测试：180 tests 全过（171 原 + 9 H2 新增）；`swift build -c release` 成功（仅保留原有过时 `onChange(of:perform:)` 警告）。

## 全面审视复核（2026-08-29，170 tests 通过，只读审查未改码）

应需求"看一下项目有什么问题"重审全部核心源码。**核实结论：MEMO「全面审视」记录的问题（H1/H2/H3、M4\~M11）当前全部仍在**，无已修复项。关键确认：

- H1 v2 迁移路由不可达：ConfigStore.load L61 先 decode AppConfig 不查 version；v2 文件必被宽松 decode 成功 → GestureConfig 缺 timeline/timelines 键回退空图 L100 → 升级检查全跳过 → save 覆盖 v2 文件

- H2 module 无子图：TimelineGraphView\.addNode L239-249 不设 subgraph；openModule L102 无 guard；updatingTimeline L137 path.count==1 无条件写 subgraph=newValue → 根图自引用 → 执行期无限递归

- H3 拖动命中区含端口行：TimelineCanvasView\.hitTestNode L410-425 hitH 含 portRows，与"端口行放行给连线"注释矛盾

- M4 L10n 启动不生效：AppDelegate.init L122 赋值 appSettings 不触发 didSet

- M5 upgradeForcePress L447 waveform != 3 判定

- M6 touchSizeMax L65-68 < 1.2 无版本门控

- M7 direct 模式每 tick 双读 IOKit（EventConfig L290-304）

- M9 模块端口编辑只改声明不同步连接器（ModuleEditorView\.addPort/removePort）

- M10 RegionTabView xMin/xMax/yMin/yMax 独立 Slider 可交叉成倒置；MorphologyTabView size 上下限已限定（0...0.5 / 0.5...2.0）不会交叉

- M11 stop() L130-145 与 tick 队列无锁竞争

**本次新增问题**：

1. build\_app.sh L28-29 **无条件多跑一次** **`swift build -c release`**：dev 模式先 swift build(debug) 又编译 release；release 模式连编两次。dev 模式若 release 编译失败，set -e 会让打包整体中止（尽管 debug 产物已成功）。建议删掉 L28-29，或仅 release 模式保留一次
2. 编译仅 1 条警告：NodeValue.swift L48 `extension` 声明 mt\_touch\_t 对 Equatable 的 conformance——建议加 `@retroactive` 消除未来冲突

待修优先级仍按原建议：H1/H2/H3 → M4/M5/M6 → 其余。（截至 2026-08-29，H1/H2/H3 已修复，见顶部「高危修复完成」；下一批 M4/M5/M6 及其余待修）

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

1. **elog 语义裂缝修复**：elog 的 EngineLog 写入门槛原只有 diagnosticMinimalTick → 改 `diagnosticMinimalTick || forceDebugLogging`——设置页「诊断日志」开关打开后"进入/退出 holding"也写入 /tmp/touchpad\_run.log（与设置页文案一致）；顺带清理 guard 括号残留
2. **EngineLog.contents**：新增锁内读取全部日志内容方法（导出用）
3. **导出诊断包含 run.log**：DiagnosticsModule includeLogs 时除 engine.log（环形缓冲）外，同时导出 EngineLog 的 /tmp/touchpad\_run.log 为 run.log（非空才写）——两会话日志体系统一进入诊断包

- 待提交推送

## "权限全绿但触控板无反馈"诊断增强（2026-08-05，170 tests 通过）

用户反馈：UI 正常、媒体键测试成功、权限全绿，但触控板手势无反馈。这类问题的断点（触控板数据链路/设备ID/手势被跳过）此前全部静默。落地：

1. **EngineLog.swift（新）**：诊断日志 stderr + 落盘 /tmp/touchpad\_run.log（512KB 上限，超出清空；.app 环境 stderr 用户看不到，落盘后可 tail -f）
2. **设置页「触控板规格」扩展**：引擎状态（运行中 120Hz / 未运行）+ **每手势健康红点**（启用 / 绑定有效 region+event / 图可执行 GraphEvaluator 非 nil）——任一红 = 该手势被引擎静默跳过；AppDelegate.gestureHealth 计算属性
3. **设置页「诊断日志」卡片（发布版可用）**：UserDefaults "engine.debugLogging" 开关 → 立即设置 GestureEngine.forceDebugLogging/NodeExecutors.debugLogging；启动时应用持久化值
4. **triggerHaptic deviceID=0 自愈**：deviceID 为 0（offset 64 部分机型读 0 / IORegistry 时序失败）时重试 mt\_device\_get\_id\_by\_index(0)，仍为 0 才跳过并记日志——震动静默失效的高频根因之一
5. GestureEngine 暴露 `isRunning`；elog/NodeExecutors.log 改走 EngineLog（保留 DEBUG DiagnosticsLog 环形缓冲）

- 排障路径：设置 → 触控板规格看引擎状态/设备 ID/手势红点 → 开诊断日志 → tail -f /tmp/touchpad\_run.log 看 finger/quantize/进入 holding 数据流

## v10.22 可插拔诊断模块（2026-08-05，170 tests 通过）

用户需求：错误收集模块，用户导出诊断包手动发给开发者；**不进正式版本**。

- **方案（用户确认）**：导出诊断包文件夹（用户手动发）+ 收集越详细越好 + 收集项可配置 + 模块可插拔

- **可插拔 =** **`#if DEBUG`** **全包裹**：`swift run`（debug）含诊断模块；`build_app.sh`（release）自动排除——nm 验证 release 二进制诊断符号为 0

- **DiagnosticsLog.swift**（GestureEngine）：环形缓冲（200 条，NSLock 线程安全）；NodeExecutors.log / GestureEngine.elog 统一接入（#if DEBUG 内，release 零开销）

- **CrashCatcher.swift**（TouchpadGestures/Diagnostics）：NSException handler（写完整堆栈）+ signal handler（ABRT/SEGV/BUS/ILL/FPE/TRAP，**async-signal-safe**：只用 open/write/close/strlen/signal/raise + 预构建字符串，崩溃时刻/路径/信号名在 install 时缓存）；崩溃日志写 Application Support/Diagnostics/crash-<时间戳>.log；写完恢复默认 handler 重抛（系统 crash reporter 也记录）

- **DiagnosticsModule.swift**：environmentText（App 版本/macOS/机型 sysctl hw\.model/设备 ID/权限/语言/手势数）+ writeDiagnostics（diagnostics.txt + config.json 副本 + engine.log + crashes/ 目录）

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
6. **forceDebugLogging 默认 false**（v10.16 校准残留 → 有手指时 \~20Hz stderr 日志风暴）
7. quit() 退出前 removeStatusItem

- 保留：`Settings { EmptyView() }` 场景仍存在（仅注册 app 菜单），设置窗口仍走手动 NSWindow（非 bundle 环境兼容，MEMO 历史决策）

## 启动/菜单栏/设置闪退根因排查（2026-08-05，只读分析，未改码）

用户反馈三类概率性问题：①双击 .app 没反应；②启动后菜单栏图标不出现；③菜单栏点击设置闪退。读完 App.swift / mt\_bridge.c / GestureEngine / 全部 Views 后的结论：

### A. ①②同根因：applicationDidFinishLaunching 提前 return → statusItem 未创建 → 应用隐身（高置信）

- App.swift L218-241：`guard mt_init()==0` / `guard deviceCount>0` / `guard let dev` 任一失败 → 提前 return，**statusItem 在最后才创建**；LSUIElement=true 无 Dock 图标 → 进程活着但完全不可见 = "双击没反应 / 图标不出现"

- 触发路径：**未授权输入监控时 MTDeviceCreateList 返回空数组**（mactic 文档行为）→ 必走②return；启动时只 requestAccessibility()，**从未请求输入监控权限** → 新机器必现；授权发生在启动后 → 无重试 → 图标永不出现（概率性假象）

- 次要：mt\_init/设备扫描/IORegistry 全主线程同步，部分机器启动假死感；桌面机无内置触控板 → 空数组

- 修复方向：statusItem 先于 MT 初始化创建；启动请求输入监控权限；MT 失败不致命（菜单显示状态+可重试）

### B. ③设置闪退：tick 线程与主线程并发写 config → 数组越界/独占访问崩溃（中置信，机制明确）

- GestureEngine.swift L215 在 **tick 队列线程**执行 `config.events[eventIndex] = b.value`（退出 holding 写回），eventIndex 是迭代前 firstIndex 快照；主线程（设置 UI 编辑/updateConfig）同时替换 config → 事件数组缩小后越界 → index out of range / exclusive access trap；用户开设置时 UI 写 config 与 tick 写回撞上概率升高

- 修复方向：config 写回统一回主线程（DispatchQueue.main.async）或串行锁；写回用 boundEventID 实时重查 index + guard

### C. 次要问题（未修）

1. `Settings { EmptyView() }` 场景 + 手动 NSWindow 双轨 → Cmd+, 弹空白设置窗（易误认为 bug/闪退）
2. `GestureEngine.forceDebugLogging = true` 默认开启（v10.16 校准残留）→ 有手指时 \~20Hz stderr 日志风暴
3. 无单实例保护 → 重复双击多实例/多图标
4. build\_app.sh 打包顺序正确（先打包未签名再签名再重打包）

## v10.20 全面 bug 审查（2026-08-05，154 tests 通过）

用户要求"读全部代码找 bug"的一轮完整排查（引擎/模型/UI 全部读完），确认并修复 6 个 bug：

1. **事件方向重置按钮回滚错误（高）**：EventTabView 重置方向写 `.positiveDecrease`（旧默认），而 v10.19 已把默认翻转为 `.positiveIncrease`（本机 norm\_y 上滑=增大）→ 用户点重置方向又反了。修复：重置改 `.positiveIncrease` + 更新 tooltip
2. **删除事件/区域重绑定失效（高）**：v4 图化后绑定在图上 EventRef/RegionRef 节点（顶层 eventID/regionID 置 nil），但 AppDelegate.requestDelete/performEventDelete/performRegionDelete 仍用顶层字段判断绑定 → 绑定检测恒 0（不弹确认）+ 删除后图上 ref 节点悬空 → 绑定手势静默失效。修复：改用 boundEventID/boundRegionID 判断 + updateNodeParams 更新图上 ref 节点重绑定
3. **holdingCount 持续 holding 恒 0（中）**：processTick 每帧重置 holdingCount 且只在"新进入"帧 +1 → 持续 holding 期间显示 0。修复：改为统计当前实际 holding 手势数
4. **eventBox 全局共享串台（中）**：单一 eventBox 被所有手势共享——两只手同时在不同边缘 holding 时，后进入手势消费前一手势的事件（调节错对象 + trackedValue 写回串台）。修复：eventBoxes 改 per-gesture 字典（key=gesture.id），effects.eventBox 每帧按当前手势设置；删除 currentEventIndex/currentGestureName 共享状态
5. **基础设置页缺手势启用开关（中）**：BasicGestureSettingsView（v10.19 新增）无 enabled Toggle（高级画布有）→ 基础设置页无法切换启用。修复：加「启用」卡片，GestureTabView 传入 enabled binding
6. **mediaKey step Slider clamp 错位（低）**：stepRange 下限 0.03125 > 默认 step 0.0125 → Slider 显示被 clamp。修复：下限改 0.01

### v10.20 续（2026-08-05，commit c0d585d / 03ff321）

1. **基础设置触觉反馈不回显（中，commit c0d585d）**：hapticRow 的 Binding get 闭包捕获 `let params` 快照，set 更新图但显示读旧快照 → 点 Stepper 值"没变"。修复：currentHaptic(title) 实时读图
2. **stop() 不清理 holding 状态（低，commit c0d585d）**：停止后残留 eventBox/wasHolding，重启续用旧状态。修复：stop 清理 eventBoxes/wasHolding/holdingCount
3. **工具箱暴露简化节点（低，commit 03ff321）**：switch（忽略 index 仅透传）与 hud（EngineEffects.showHUD 空实现）行为与名称不符 → 工具箱与右键菜单隐藏（NodePaletteView + addNodeSubmenus 两处 hidden 集合加 .switch/.hud）
4. **Force 信号源选择器可用（低，commit 03ff321）**：Force 手势滑动信号恒 normY，但基础设置页信号源 Picker 可改 → 改后下次 load 被 upgradeForcePress 静默纠正回 normY（"改不生效"困惑）。修复：isForceGesture 时禁用 Picker + 说明文字
5. **quit() 泄漏设备 CFArray（低，commit 03ff321）**：mt\_scan\_devices\_array 的数组未释放。修复：quit 调 mt\_release\_devices\_array
6. **误删教训**：TimelineNodeInspector.swift 承载 typedRows/nonNilRows/paramsSummary/symbolName/tintColor/category 扩展（被编辑器/画布/工具箱广泛使用），并非死文件——删除致编译失败，git checkout 恢复。教训：删文件前必须 grep 其内部符号的引用，不能只看文件名/类名

- 审查中发现但**未修**（无功能影响或用户明确决策）：①Force 压力阈值 2.0 > mactic 注释 zP 上限 1.54（用户明确指定，实测可用，若后续 Force 失灵先查此值）；②module 每次执行重建 GraphEvaluator（性能可接受）；③exitPulse/holdingPulse 模块输出声明 unit 但实际传 int 状态值（执行器只看 valid，行为一致）；④每次退出 holding 触发一次 ConfigStore.save（trackedValue 不编码，无害）；⑤ScrollWheelCatcher/DragMonitor 的 excludeRect（paletteFrame .global 屏幕坐标）与 event.locationInWindow（窗口坐标）坐标系不一致——palette 内滚动可能被画布平移拦截，修复需坐标系换算且需真机验证，未动；⑥tick 信号源用 touches.first 的 normY（非 finger.active）——多指时 first 可能是手掌，但改 finger.normY 会让 size/区域闪断中断调节（v10.11 回归），单指场景正确，保持现状

## 历史归档（2026-08-05）

- 2026-08-01 前的全部开发记录已归档至 [docs/ARCHIVE.md](docs/ARCHIVE.md)：管线规划（M1~~M8 交付清单）、v6~~v9 节点化演进、v1.1.0 架构变更、技术路线（MultitouchSupport.framework）、UI 布局规范、运行方式与分发构建等。

- MEMO.md 仅保留最近状态（当前架构简述 + 最近修复记录），降低认知负载。

## 全面审视（2026-08-05，170 tests 通过，只读审查未改码）

引擎/模型/UI/桥接层全部读完（含两个子代理并行审查 + 关键项亲自验证）。已确认的待修问题：

### 高危（建议优先修）

1. **v2 迁移路由不可达 → v2 配置静默降级为空图并覆盖落盘**（ConfigStore.load L61 先 decode AppConfig 不查 version；AppConfig 必填键 version/global/regions/gestures/events 与 v2 文件键集合完全重合 → 任何 v2 文件必先被宽松 decode 成功 → GestureConfig 缺 timeline/timelines 键回退空图 L100 → 升级检查全跳过 → ensureBindingsInGraph 补 ref 节点后 save 覆盖用户 v2 文件，管线配置全丢）。修复：按 version(<3) 先路由 v2 分支或探测 timeline 键；补真实 v2 JSON 走 load() 的回归测试
2. **工具箱添加的 module 节点无子图 → 双击进入后编辑把根图写进子图 → 执行期无限递归栈溢出**（TimelineGraphView\.addNode L243 不设 subgraph；openModule L102 不检查；timelineAt 解析失败静默回退根图 L34-36 但面包屑显示已进模块；updatingTimeline L137 path.count==1 无条件写 subgraph = newValue → 根图自引用；NodeExecutors.module 递归 GraphEvaluator）。修复：addNode 对 .module 初始化空子图 + openModule guard + currentTimeline 解析失败不静默回退
3. **DragMonitor 拖动命中区含端口行，与"端口行放行给连线手势"注释矛盾**（TimelineCanvasView\.hitTestNode L407-425 hitH 含 portRows；DragMonitor mouseDown 命中即消费 mouseDragged）→ 端口行无法连线，只能拖节点。修复：命中区收窄到头部或跳过端口行，需真机验证

### 中危

1. **L10n 持久化语言启动不生效**（L10n.currentLanguage 唯一赋值点 = appSettings.didSet；AppDelegate.init 赋值不触发 didSet，启动无人同步 → 存 .en 重启后菜单/设置仍中文，直到再碰一次语言选择器）。修复：init 里 AppSettings.load() 后立即同步
2. **upgradeForcePress 用 waveform != 3 判定"旧图"**（GestureConfig L447/460）：用户关闭 Force 进入震动（haptic 节点缺失，nil != 3 为 true）或自定义波形 → 每次启动整图重建并强制回滚为 waveform 3。修复：区分"节点缺失=用户关闭"与"真旧结构"
3. **touchSizeMax < 1.2 无版本门控**（ConfigStore L65-68）：用户合法设置 1.0\~1.19 每次启动被改回 1.35 并落盘。修复：绑定迁移标记只修一次
4. **direct 模式每 tick 双读 IOKit/CoreAudio**（EventConfig.trackedCurrentValue + 写后 currentValue，120Hz tick 队列上 getBrightness 可阻塞数 ms）→ 调节不跟手。修复：direct 也基于 trackedValue 数学推进 + 低频校准
5. **v8/v9/v10 升级函数整图重建**（upgradeStateMachineGraph/ModularGraph/BoundarySense/ForcePress）：只保留可提取命名参数，画布自定义节点/连线/布局丢失且不可逆。修复：增量补丁或升级前备份
6. **模块端口编辑只改声明、不同步子图连接器与边**（ModuleEditorView\.addPort/rename/remove 只写 moduleInputs 声明；moduleInput/Output 连接器在工具箱/右键菜单均被隐藏 → 用户无途径补齐 → 模块接口一经编辑即静默断开）。修复：增删改时同步维护连接器或放开子图内添加
7. **区域四坐标/形态 size 上下限可交叉成倒置**（RegionTabView/MorphologyTabView 独立 Slider）→ 预览负宽 frame + 引擎过滤空集手势全失效。修复：clamp 或联动
8. **stop() 与 tick 队列无锁竞争**（GestureEngine.stop L130-144 主线程清 eventBoxes/runtimes/effects.eventBox；timer.cancel 不等正在执行的 tick handler）→ 低概率独占访问 trap。修复：清理派发到 tickQueue 或加锁

### 低危（摘录）

- EngineLog.append 每调用新建 DateFormatter + open/close FileHandle（L4 性能，120Hz 日志密集时拖慢 tick）

- DirectionRule 两处回退默认互相矛盾（缺字段 .positiveIncrease vs 未知值 .positiveDecrease）

- ensureBindingsInGraph 双源状态：图上 ref 节点存在但参数 nil 时顶层字段永不回填/清理

- EventConfig 合成 Equatable 含非 Codable 的 trackedValue → consume 后相等性误判

- hud/freeze/notify 空实现 + set 节点与 GraphEvaluator 第二遍重复写 state（NodeExecutors.set 直接写 state 而 evaluator 也收集写请求 → 同帧双写，语义一致无碍但冗余）

- 死代码：PermissionStatus.color / TimelineCanvasMetrics.nodeHeight / TimelineCanvasView\.node(\_:) 无引用；reachableNodes 仅测试用

- SettingsTabView 图标色板硬编码中文色名未走 L10n；动态色读 redComponent 依赖外观

- TimelineGraphView\.fitToContent 与 TimelineCanvasView 重复实现 3 份包围盒计算

- 文件超 300 行约束：TimelineCanvasView 742 / SettingsTabView 395 / ConfigView 325 / TimelineNodeView 376（画布部分明显超限）

- 误删警示：删除文件前必须 grep 内部符号引用（TimelineNodeInspector 教训）——本次审查同样发现 PermissionStatus.color 等若删除需先确认引用

### 总体评价

架构与防御意识强（config 锁/mutateConfig、per-gesture eventBox、Godot 固定步长、手动 Codable 兼容、迁移链、@ai 注释、L10n 双语），170 tests 全绿。主要风险集中在**迁移路由可达性未端到端测试**（H1 无测试覆盖）+ **画布/模块最近迭代的边界条件**（module 无子图、端口行命中、模块端口契约）。建议修复顺序：H1/H2/H3 → 4/5/6 → 其余。
