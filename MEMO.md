# 项目备忘录

## 物理键盘 Option+Shift 精确调节修复（2026-09-02，180 tests 通过）
用户原说要加「旁路开关模拟 Option+Shift」，但实际根因是：**物理键盘上手动按 Option+Shift 同时滑触控板，精确调节不生效**。
- 根因：`SystemControl.postMediaKey` 合成 `NX_SYSDEFINED subtype=8` 媒体键事件时，把 `modifierFlags` **硬编码为 `0xA00（keyDown）/ 0xB00（keyUp）`**（系统要求的媒体键私有掩码），直接覆盖了物理键盘当前真实的修饰符状态 → macOS 完全看不到按着 Option/Shift，自然不进入精确档位。
- 修复：每次合成事件前，在主线程读 `NSEvent.modifierFlags`（必须主线程，否则返回空集合；媒体键由 tick 线程调用，使用 `DispatchQueue.main.sync`），把真实修饰符按位或 `| mediaMask`，既保留媒体键需要的私有掩码，又叠加了物理键盘的 ⌥/⇧/⌃/⌘。所有系统原生组合（⌥⇧+音量精确 1/4 档、Shift+音量静音、⌥+亮度精确档等）在触控板触发时全部自然恢复，不需要任何开关。
- 验证：`swift build --disable-sandbox -c release` 成功（仅历史 kIOMasterPortDefault 弃用警告，与本改无关）；`swift test` 180 全过。
- 待用户真机复测：按住物理键盘 ⌥+⇧，触控板滑动调音量/亮度 → HUD 应走 1/4 格小步进（系统原生精确档）。

## 分发改为 DMG 拖入 + 移除 App Translocation 引导（2026-08-31，180 tests 通过，DMG 已打包）
用户要求：把分发方式从 zip 改成 dmg 拖入；去掉「引导拖入」相关代码（zip 分发时才需要，app 被 App Translocation 转移到随机路径才触发）。
- **build_app.sh**：zip 打包（ditto）替换为 DMG——Ad-hoc 签名后在暂存目录放 `TouchpadGestures.app` + `Applications -> /Applications` 软链，`hdiutil create -volname TouchpadGestures -srcfolder <staging> -ov -format UDZO` 生成 `dist/TouchpadGestures.dmg`；删除旧 zip。已挂载验证：DMG 内含 app + Applications 拖入链接，codesign 有效。
- **删除** `Sources/GestureEngine/AppTranslocation.swift`（isRunningTranslocated/shouldOfferMoveToApplications/applicationsDestination/originalURLWhenTranslocated）与 `Tests/GestureEngineTests/AppTranslocationTests.swift`（8 tests）。
- **App.swift**：`applicationDidFinishLaunching` 移除 `handleTranslocationSelfHeal()`/`offerMoveToApplicationsIfNeeded()` 调用；删除 `offerMoveToApplicationsIfNeeded`/`handleTranslocationSelfHeal`/`moveToApplications`/`showMoveError` 四个方法；`ensureSingleInstance()` 移除「排除 /AppTranslocation/ 路径」过滤（原为移入流程服务）。
- 验证：`swift build --disable-sandbox -c release` 成功（仅原 onChange 弃用警告）；`swift test` 180 全过（原 188 - 8）；`build_app.sh` 产出 DMG 并挂载签名校验通过。
- 注意：DMG 拖入后 app 位于 /Applications 稳定路径，TCC 权限（辅助功能）按路径+签名匹配可跨启动保留，不再需要「建议移入」引导。

## v2.0.2 发布（2026-08-31，commit 83c9614）
已发布 GitHub release `v2.0.2`：https://github.com/Zekilou/mac_touchpad/releases/tag/v2.0.2
- 资产：`TouchpadGestures.zip`（ad-hoc 签名，macOS 15+）
- 修复：**App 转译自愈**（新增 AppTranslocation.swift，路径+CDHash 匹配 TCC 解决「已允许仍未授予」）、**输入监控降级为可选提示**（辅助功能为唯一必需项，启动不再弹输入监控授权窗）、**关闭设置窗口不再退出**（applicationShouldTerminateAfterLastWindowClosed→false）、**build_app.sh 加 --disable-sandbox** + 版本号 2.0.1→2.0.2。
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
- **ConfigView.swift**：辅助功能移到权限栏顶部（唯一必需项）；输入监控改 `optionalPermRow`（状态中性色 + info 备注「不影响触控板，无需授权」）；新增 `optionalPermRow` builder。
- 验证：`swift build --disable-sandbox -c release` 成功；188 tests 全过；`build_app.sh` 打 release 包完成。
- **build_app.sh 修正**：三处 `swift build` 加 `--disable-sandbox`——代理终端环境 SwiftPM 子进程沙箱 `sandbox-exec: Operation not permitted` 会导致打包失败；该标志对用户本机正常构建无副作用。
- 待用户复测：权限面板应显示「辅助功能」为必需、输入监控为「可选，不影响触控板」；启动不再弹输入监控授权窗。

## 权限"已允许仍未授予"落地实现：自动除转移+自愈（2026-08-31，188 tests 通过，待用户复测打包）
按用户选择（「自动除转移+自愈」「权限异常自动重置」「暂不，保持 ad-hoc」）完成，参照 Mac Mouse Fix 的 `AppTranslocationManager.m`（SecTranslocate 私有 API 自愈）与 `AccessibilityCheck.m`（tccutil 清授权再重加）：
- **AppTranslocation.swift**：新增 `originalURLWhenTranslocated(bundleURL:)`，`dlopen` Security 框架 + `dlsym` 调 `SecTranslocateIsTranslocatedURL`/`SecTranslocateCreateOriginalPathForURL`；未转移/私有 API 缺失一律回退 `nil`（优雅降级到手动引导）。
- **PermissionManager.swift**：新增 `autoResetAndReprompt()`（`tccutil reset InputMonitoring/Accessibility <bundleID>` 清旧授权 → 重新请求两权限 → 1.5s 后刷新）、`scheduleAutoResetIfNeeded()`（启动后 3s 若未全授权则自动自愈一次，每进程一次）、私有 `resetTCC(service:)`（调 `/usr/bin/tccutil`）。
- **App.swift**：`applicationDidFinishLaunching` 在 `offerMoveToApplicationsIfNeeded()` 前先 `if handleTranslocationSelfHeal() { return }`——检测到转移路径则取回原始路径 → 移入 /Applications → 去隔离 → 重启 → 退出当前实例（无感，无需用户操作）；权限请求后调 `permissionManager.scheduleAutoResetIfNeeded()`。`moveToApplications` 重构为 `moveToApplications(source:destination:)`，自愈与手动引导共用。
- **ConfigView.swift**：权限栏新增「重置授权」按钮（权限未全绿时显示），点击调 `permManager.autoResetAndReprompt()`，带 L10n 双语。
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
已发布 GitHub release `v2.0.1`：https://github.com/Zekilou/mac_touchpad/releases/tag/v2.0.1
- 内容：H1/H2/H3 三项高危修复（见下），180 tests 全过
- 产物：`dist/TouchpadGestures.zip`（ad-hoc 签名 .app，macOS 15+）
- 提交：`0b849c7`（fix 三项高危）+ `aceef9b`（chore 版本号→2.0.1）
- 标签：`v2.0.1`（annotated，已推送）
- 备注：build_app.sh 依然存在「无条件多跑一次 swift build -c release」的小问题（DEV 记录），本轮未动；
  本次打包已把版本号 2.0.0→2.0.1 同步到 release/dev 分支。

## 高危修复完成（2026-08-29，180 tests 通过，debug+release 均构建成功）
应需求"开始"按优先级修复全面审视的问题。已完成 H1/H2/H3 三项高危：
- **H1 v2 迁移路由不可达**：ConfigStore.load 改为先按顶层 version 分流（<3 先走 v2/v1 迁移），不再先 decode v3 被宽松成功。已补回归测试。
- **H2 module 节点无子图 → 无限递归**：TimelineConfig 新增模型层 `subgraph(at:)`/`updatingSubgraph(at:to:)`/`ensuringModuleSubgraphs()`（public）；视图层 `currentTimeline` 改用 `timeline.subgraph(at:modulePath) ?? timeline`、`canvasBinding` 用 `timeline.updatingSubgraph(at:to:)`、`openModule` 加 guard（非 module/无子图拒绝进入）、`addNode` 对 `.module` 初始化空子图、删除旧 `timelineAt`/`updatingTimeline`；ConfigStore.load 加载时对每个手势 `ensuringModuleSubgraphs()` 补全缺失子图。新增 TimelineSubgraphNavigationTests 9 个测试。
- **H3 拖动命中区含端口行 → 无法连线**：TimelineCanvasView.hitTestNode 命中区收窄到仅头部（headerHeight），端口行/编辑器区放行给 SwiftUI 连线手势（此前含端口行，DragMonitor 消费 mouseDown 导致只能拖节点）。**需真机验证**连线/拖动手感。
- 测试：180 tests 全过（171 原 + 9 H2 新增）；`swift build -c release` 成功（仅保留原有过时 `onChange(of:perform:)` 警告）。

## 全面审视复核（2026-08-29，170 tests 通过，只读审查未改码）
应需求"看一下项目有什么问题"重审全部核心源码。**核实结论：MEMO「全面审视」记录的问题（H1/H2/H3、M4~M11）当前全部仍在**，无已修复项。关键确认：
- H1 v2 迁移路由不可达：ConfigStore.load L61 先 decode AppConfig 不查 version；v2 文件必被宽松 decode 成功 → GestureConfig 缺 timeline/timelines 键回退空图 L100 → 升级检查全跳过 → save 覆盖 v2 文件
- H2 module 无子图：TimelineGraphView.addNode L239-249 不设 subgraph；openModule L102 无 guard；updatingTimeline L137 path.count==1 无条件写 subgraph=newValue → 根图自引用 → 执行期无限递归
- H3 拖动命中区含端口行：TimelineCanvasView.hitTestNode L410-425 hitH 含 portRows，与"端口行放行给连线"注释矛盾
- M4 L10n 启动不生效：AppDelegate.init L122 赋值 appSettings 不触发 didSet
- M5 upgradeForcePress L447 waveform != 3 判定
- M6 touchSizeMax L65-68 < 1.2 无版本门控
- M7 direct 模式每 tick 双读 IOKit（EventConfig L290-304）
- M9 模块端口编辑只改声明不同步连接器（ModuleEditorView.addPort/removePort）
- M10 RegionTabView xMin/xMax/yMin/yMax 独立 Slider 可交叉成倒置；MorphologyTabView size 上下限已限定（0...0.5 / 0.5...2.0）不会交叉
- M11 stop() L130-145 与 tick 队列无锁竞争

**本次新增问题**：
1. build_app.sh L28-29 **无条件多跑一次 `swift build -c release`**：dev 模式先 swift build(debug) 又编译 release；release 模式连编两次。dev 模式若 release 编译失败，set -e 会让打包整体中止（尽管 debug 产物已成功）。建议删掉 L28-29，或仅 release 模式保留一次
2. 编译仅 1 条警告：NodeValue.swift L48 `extension` 声明 mt_touch_t 对 Equatable 的 conformance——建议加 `@retroactive` 消除未来冲突

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

## 全面审视（2026-08-05，170 tests 通过，只读审查未改码）
引擎/模型/UI/桥接层全部读完（含两个子代理并行审查 + 关键项亲自验证）。已确认的待修问题：

### 高危（建议优先修）
1. **v2 迁移路由不可达 → v2 配置静默降级为空图并覆盖落盘**（ConfigStore.load L61 先 decode AppConfig 不查 version；AppConfig 必填键 version/global/regions/gestures/events 与 v2 文件键集合完全重合 → 任何 v2 文件必先被宽松 decode 成功 → GestureConfig 缺 timeline/timelines 键回退空图 L100 → 升级检查全跳过 → ensureBindingsInGraph 补 ref 节点后 save 覆盖用户 v2 文件，管线配置全丢）。修复：按 version(<3) 先路由 v2 分支或探测 timeline 键；补真实 v2 JSON 走 load() 的回归测试
2. **工具箱添加的 module 节点无子图 → 双击进入后编辑把根图写进子图 → 执行期无限递归栈溢出**（TimelineGraphView.addNode L243 不设 subgraph；openModule L102 不检查；timelineAt 解析失败静默回退根图 L34-36 但面包屑显示已进模块；updatingTimeline L137 path.count==1 无条件写 subgraph = newValue → 根图自引用；NodeExecutors.module 递归 GraphEvaluator）。修复：addNode 对 .module 初始化空子图 + openModule guard + currentTimeline 解析失败不静默回退
3. **DragMonitor 拖动命中区含端口行，与"端口行放行给连线手势"注释矛盾**（TimelineCanvasView.hitTestNode L407-425 hitH 含 portRows；DragMonitor mouseDown 命中即消费 mouseDragged）→ 端口行无法连线，只能拖节点。修复：命中区收窄到头部或跳过端口行，需真机验证

### 中危
4. **L10n 持久化语言启动不生效**（L10n.currentLanguage 唯一赋值点 = appSettings.didSet；AppDelegate.init 赋值不触发 didSet，启动无人同步 → 存 .en 重启后菜单/设置仍中文，直到再碰一次语言选择器）。修复：init 里 AppSettings.load() 后立即同步
5. **upgradeForcePress 用 waveform != 3 判定"旧图"**（GestureConfig L447/460）：用户关闭 Force 进入震动（haptic 节点缺失，nil != 3 为 true）或自定义波形 → 每次启动整图重建并强制回滚为 waveform 3。修复：区分"节点缺失=用户关闭"与"真旧结构"
6. **touchSizeMax < 1.2 无版本门控**（ConfigStore L65-68）：用户合法设置 1.0~1.19 每次启动被改回 1.35 并落盘。修复：绑定迁移标记只修一次
7. **direct 模式每 tick 双读 IOKit/CoreAudio**（EventConfig.trackedCurrentValue + 写后 currentValue，120Hz tick 队列上 getBrightness 可阻塞数 ms）→ 调节不跟手。修复：direct 也基于 trackedValue 数学推进 + 低频校准
8. **v8/v9/v10 升级函数整图重建**（upgradeStateMachineGraph/ModularGraph/BoundarySense/ForcePress）：只保留可提取命名参数，画布自定义节点/连线/布局丢失且不可逆。修复：增量补丁或升级前备份
9. **模块端口编辑只改声明、不同步子图连接器与边**（ModuleEditorView.addPort/rename/remove 只写 moduleInputs 声明；moduleInput/Output 连接器在工具箱/右键菜单均被隐藏 → 用户无途径补齐 → 模块接口一经编辑即静默断开）。修复：增删改时同步维护连接器或放开子图内添加
10. **区域四坐标/形态 size 上下限可交叉成倒置**（RegionTabView/MorphologyTabView 独立 Slider）→ 预览负宽 frame + 引擎过滤空集手势全失效。修复：clamp 或联动
11. **stop() 与 tick 队列无锁竞争**（GestureEngine.stop L130-144 主线程清 eventBoxes/runtimes/effects.eventBox；timer.cancel 不等正在执行的 tick handler）→ 低概率独占访问 trap。修复：清理派发到 tickQueue 或加锁

### 低危（摘录）
- EngineLog.append 每调用新建 DateFormatter + open/close FileHandle（L4 性能，120Hz 日志密集时拖慢 tick）
- DirectionRule 两处回退默认互相矛盾（缺字段 .positiveIncrease vs 未知值 .positiveDecrease）
- ensureBindingsInGraph 双源状态：图上 ref 节点存在但参数 nil 时顶层字段永不回填/清理
- EventConfig 合成 Equatable 含非 Codable 的 trackedValue → consume 后相等性误判
- hud/freeze/notify 空实现 + set 节点与 GraphEvaluator 第二遍重复写 state（NodeExecutors.set 直接写 state 而 evaluator 也收集写请求 → 同帧双写，语义一致无碍但冗余）
- 死代码：PermissionStatus.color / TimelineCanvasMetrics.nodeHeight / TimelineCanvasView.node(_:) 无引用；reachableNodes 仅测试用
- SettingsTabView 图标色板硬编码中文色名未走 L10n；动态色读 redComponent 依赖外观
- TimelineGraphView.fitToContent 与 TimelineCanvasView 重复实现 3 份包围盒计算
- 文件超 300 行约束：TimelineCanvasView 742 / SettingsTabView 395 / ConfigView 325 / TimelineNodeView 376（画布部分明显超限）
- 误删警示：删除文件前必须 grep 内部符号引用（TimelineNodeInspector 教训）——本次审查同样发现 PermissionStatus.color 等若删除需先确认引用

### 总体评价
架构与防御意识强（config 锁/mutateConfig、per-gesture eventBox、Godot 固定步长、手动 Codable 兼容、迁移链、@ai 注释、L10n 双语），170 tests 全绿。主要风险集中在**迁移路由可达性未端到端测试**（H1 无测试覆盖）+ **画布/模块最近迭代的边界条件**（module 无子图、端口行命中、模块端口契约）。建议修复顺序：H1/H2/H3 → 4/5/6 → 其余。
