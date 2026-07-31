# 项目备忘录

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
