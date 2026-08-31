import SwiftUI
import GestureEngine
import mt_bridge
import CoreGraphics
import ApplicationServices

// MARK: - 软件设置

struct AppSettings: Codable, Equatable {
    var launchAtLogin: Bool = false
    var showInDock: Bool = false
    var menuBarIcon: String = "hand.tap"
    var menuBarIconSize: CGFloat = 14
    var appIconColorRed: Double = 1.0
    var appIconColorGreen: Double = 1.0
    var appIconColorBlue: Double = 1.0
    /// UI 语言（跟随系统/中文/英文；启动与设置变更时同步到 L10n.currentLanguage）
    var language: AppLanguage = .system

    init() {}

    /// 手动 Codable：新字段 decodeIfPresent 回退默认——旧 appsettings.json 缺 language 时
    /// 不能整体 decode 失败（否则全部设置被重置为默认）
    enum CodingKeys: String, CodingKey {
        case launchAtLogin, showInDock, menuBarIcon, menuBarIconSize
        case appIconColorRed, appIconColorGreen, appIconColorBlue, language
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false
        menuBarIcon = try c.decodeIfPresent(String.self, forKey: .menuBarIcon) ?? "hand.tap"
        menuBarIconSize = try c.decodeIfPresent(CGFloat.self, forKey: .menuBarIconSize) ?? 14
        appIconColorRed = try c.decodeIfPresent(Double.self, forKey: .appIconColorRed) ?? 1.0
        appIconColorGreen = try c.decodeIfPresent(Double.self, forKey: .appIconColorGreen) ?? 1.0
        appIconColorBlue = try c.decodeIfPresent(Double.self, forKey: .appIconColorBlue) ?? 1.0
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(showInDock, forKey: .showInDock)
        try c.encode(menuBarIcon, forKey: .menuBarIcon)
        try c.encode(menuBarIconSize, forKey: .menuBarIconSize)
        try c.encode(appIconColorRed, forKey: .appIconColorRed)
        try c.encode(appIconColorGreen, forKey: .appIconColorGreen)
        try c.encode(appIconColorBlue, forKey: .appIconColorBlue)
        try c.encode(language, forKey: .language)
    }

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
        // 菜单栏 app 无主窗口：设置窗口由 AppDelegate.openSettings() 手动创建。
        // 保留 Settings 场景仅用于注册 app 菜单，但用 CommandGroup 把系统自带的
        // "Settings…/Cmd+," 重定向到手动窗口——否则 Cmd+, 会弹出 EmptyView 空白设置窗
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button(L10n.tr("设置...", "Settings...")) {
                        appDelegate.openSettings()
                    }
                    .keyboardShortcut(",")
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    let engine = GestureEngine()
    @Published var appSettings: AppSettings {
        didSet {
            // UI 语言同步到 L10n（切语言即时生效；@Published objectWillChange → 依赖视图重算 → 文本刷新）
            L10n.currentLanguage = appSettings.language
            appSettings.save()
        }
    }
    @Published var showResetAllAlert = false

    // MARK: - Config Management

    @Published var config: AppConfig
    @Published var selectedGestureID: UUID?
    @Published var selectedEventID: UUID?
    @Published var selectedRegionID: UUID?
    @Published var currentEditingTab: PrimaryTab = .gestures
    @Published var showRenameAlert = false
    @Published var renameText = ""
    @Published var showDeleteAlert = false
    @Published var pendingDelete: DeleteTarget?

    let permissionManager = PermissionManager()

    // MARK: - Init

    override init() {
        appSettings = AppSettings.load()
        let cfg = ConfigStore.load()
        config = cfg
        super.init()
        // 初始化选中项为首项，避免 TabView selection 为 nil 导致闪烁
        selectedGestureID = cfg.gestures.first?.id
        selectedEventID = cfg.events.first?.id
        selectedRegionID = cfg.regions.first?.id
    }

    // MARK: - Config Edit Actions

    var currentSecondaryID: UUID? {
        switch currentEditingTab {
        case .gestures: return selectedGestureID ?? config.gestures.first?.id
        case .events:   return selectedEventID ?? config.events.first?.id
        case .regions:  return selectedRegionID ?? config.regions.first?.id
        case .morphology: return nil
        case .settings: return nil
        }
    }

    var currentSecondaryName: String? {
        switch currentEditingTab {
        case .gestures: return config.gestures.first { $0.id == selectedGestureID }?.name ?? config.gestures.first?.name
        case .events:   return config.events.first { $0.id == selectedEventID }?.name ?? config.events.first?.name
        case .regions:  return config.regions.first { $0.id == selectedRegionID }?.name ?? config.regions.first?.name
        case .morphology: return nil
        case .settings: return nil
        }
    }

    var canDeleteSecondary: Bool {
        switch currentEditingTab {
        case .gestures: return config.gestures.count > 1
        case .events:   return config.events.count > 1
        case .regions:  return config.regions.count > 1
        case .morphology: return false
        case .settings: return false
        }
    }

    func addItem() {
        switch currentEditingTab {
        case .gestures:
            guard let r = config.regions.first, let e = config.events.first else { return }
            let g = GestureConfig(name: L10n.tr("新手势", "New Gesture"), regionID: r.id, eventID: e.id)
            config.gestures.append(g); selectedGestureID = g.id
        case .events:
            let e = EventConfig(name: L10n.tr("新事件", "New Event"), actionType: .volume, step: 0.0125, boundaryThreshold: 0.001)
            config.events.append(e); selectedEventID = e.id
        case .regions:
            let r = RegionConfig(name: L10n.tr("新区域", "New Region"), xMin: 0.4, xMax: 0.6, yMin: 0.4, yMax: 0.6)
            config.regions.append(r); selectedRegionID = r.id
        case .morphology: break
        case .settings: break
        }
    }

    func startRename() {
        renameText = currentSecondaryName ?? ""
        showRenameAlert = true
    }

    func performRename() {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let id = currentSecondaryID else { return }
        switch currentEditingTab {
        case .gestures:
            if let i = config.gestures.firstIndex(where: { $0.id == id }) { config.gestures[i].name = name }
        case .events:
            if let i = config.events.firstIndex(where: { $0.id == id }) { config.events[i].name = name }
        case .regions:
            if let i = config.regions.firstIndex(where: { $0.id == id }) { config.regions[i].name = name }
        case .morphology, .settings: break
        }
        renameText = ""
    }

    func requestDelete() {
        guard let id = currentSecondaryID else { return }
        switch currentEditingTab {
        case .gestures:
            config.gestures.removeAll { $0.id == id }
            if selectedGestureID == id { selectedGestureID = config.gestures.first?.id }
        case .events:
            // v4 起绑定在图节点（EventRef），顶层 eventID 为 nil——用 boundEventID 判断绑定
            let bound = config.gestures.filter { $0.boundEventID == id }.count
            if bound > 0 { pendingDelete = .event(id); showDeleteAlert = true }
            else { performEventDelete(id) }
        case .regions:
            let bound = config.gestures.filter { $0.boundRegionID == id }.count
            if bound > 0 { pendingDelete = .region(id); showDeleteAlert = true }
            else { performRegionDelete(id) }
        case .morphology, .settings: break
        }
    }

    func performConfirmedDelete() {
        guard let target = pendingDelete else { return }
        switch target {
        case .event(let id):  performEventDelete(id)
        case .region(let id): performRegionDelete(id)
        }
        pendingDelete = nil
    }

    private func performEventDelete(_ id: UUID) {
        guard let first = config.events.first(where: { $0.id != id }) else { return }
        // v4 起绑定在图节点（EventRef）——重绑定时更新图上节点参数，否则手势静默失效
        for i in 0..<config.gestures.count where config.gestures[i].boundEventID == id {
            config.gestures[i].updateNodeParams(.event, title: "绑定事件") { $0.eventID = first.id }
        }
        config.events.removeAll { $0.id == id }
        if selectedEventID == id { selectedEventID = first.id }
    }

    private func performRegionDelete(_ id: UUID) {
        guard let first = config.regions.first(where: { $0.id != id }) else { return }
        for i in 0..<config.gestures.count where config.gestures[i].boundRegionID == id {
            config.gestures[i].updateNodeParams(.region, title: "触发区域") { $0.regionID = first.id }
        }
        config.regions.removeAll { $0.id == id }
        if selectedRegionID == id { selectedRegionID = first.id }
    }

    func boundGestureCount(for target: DeleteTarget) -> Int {
        switch target {
        case .event(let id):  return config.gestures.filter { $0.boundEventID == id }.count
        case .region(let id): return config.gestures.filter { $0.boundRegionID == id }.count
        }
    }

    private var touchArrayPtr: UnsafeMutableRawPointer? = nil
    private var deviceCount: Int32 = 0
    private var firstDev: mt_device_t? = nil
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var retryMenuItem: NSMenuItem?
    private var trackpadReady = false
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        CrashCatcher.install()   // 可插拔诊断：崩溃捕获（仅开发版；release 构建不含）
        #endif
        NSApp.setActivationPolicy(appSettings.showInDock ? .regular : .accessory)
        applyAppIcon()

        // 单实例保护：已有实例在跑时退出本实例（避免重复双击 → 多个状态栏图标 / 多个引擎抢触控板）
        guard ensureSingleInstance() else {
            activateExistingInstance()
            NSApp.terminate(nil)
            return
        }

        // 菜单栏图标必须先于触控板初始化创建——任何初始化失败都不能让应用"隐身"：
        // LSUIElement 无 Dock 图标，若 statusItem 未创建则进程无任何可见 UI（用户"双击没反应"主因）
        setupStatusItem()

        // ① 自动除转移 + 自愈：若被 macOS App Translocation 转移到随机只读路径，
        //   直接取回原始路径、移入 /Applications、去隔离、重启并退出当前实例。
        //   权限本就按「路径+签名」匹配，避免授权再次落到随机路径上（无感处理，无需用户操作）。
        //   若无法解析原始路径（私有 API 缺失），退化为下方「建议移入」引导。
        if handleTranslocationSelfHeal() { return }

        // ② App 转移/非标准位置引导：移入「应用程序」稳定 TCC 权限（此刻 statusItem 已就绪，
        //   弹窗不至于让应用"隐身"；权限请求放在其之后——转移路径下请求权限本就不持久）
        offerMoveToApplicationsIfNeeded()

        // 应用持久化的诊断日志开关（设置页可开启；日志落 /tmp/touchpad_run.log）
        if UserDefaults.standard.bool(forKey: "engine.debugLogging") {
            GestureEngine.forceDebugLogging = true
            NodeExecutors.debugLogging = true
        }

        // 权限请求：仅请求本 app 真正必需的「辅助功能」。
        // 「输入监控」是可选项——触控板读取走 MultitouchSupport 私有框架，不受 TCC 输入监控门控；
        // 主动请求它只会弹窗误导用户，故不再请求/不再把它当功能前提。
        permissionManager.requestRequiredPermissions()
        // 辅助功能授权后自动重试触控板初始化（无需重启 app）
        permissionManager.onAccessibilityGranted = { [weak self] in
            self?.setupTrackpad()
        }

        // ③ 权限异常自愈：若启动后权限仍未授予（含「已允许但未生效」的多副本匹配问题），
        //   延迟 3s 自动 tccutil 清旧授权并重新请求——否则授权可能一直落在错误的副本/随机路径上。
        permissionManager.scheduleAutoResetIfNeeded()

        setupTrackpad()
    }

    // 菜单栏 app 常驻：关闭（最后一个）设置窗口不应退出应用。
    // SwiftUI App 生命周期默认把「最后一个窗口关闭」实现为终止应用，
    // 而本 app 唯一窗口是手动创建的设置 NSWindow——覆盖为 false 保持进程存活（状态栏图标仍在）。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 创建菜单栏图标与菜单（先于触控板初始化——菜单栏图标必须始终可见）
    private func setupStatusItem() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyMenuBarIcon()
        let menu = NSMenu()
        menu.addItem(withTitle: "Touchpad Gestures", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        // 显式 target：不依赖响应链解析（响应链在无窗口场景可能解析到异常对象——
        // 历史崩溃 openSettings 内 objc_retain/objc_msgSend SIGSEGV 与此相关）
        let settingsItem = NSMenuItem(title: L10n.tr("设置...", "Settings..."),
                                      action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        // 触控板状态行：初始化中 → 就绪 / 失败（失败时提供「重试」）
        statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(statusMenuItem!)
        retryMenuItem = NSMenuItem(title: L10n.tr("重试初始化", "Retry trackpad"),
                                   action: #selector(retryTrackpad), keyEquivalent: "")
        menu.addItem(retryMenuItem!)
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr("退出", "Quit"), action: #selector(quit), keyEquivalent: "q")
        statusItem?.menu = menu
        setTrackpadStatus(L10n.tr("触控板初始化中…", "Initializing trackpad…"), retryable: false)
    }

    /// 触控板初始化（失败不致命：菜单栏显示状态 + 提供重试；权限授权后自动重试）
    private func setupTrackpad() {
        guard !trackpadReady else { return }
        // 重置旧状态（重试路径幂等）
        engine.stop()
        if let dev = firstDev { mt_stop_touch(dev) }
        mt_release_devices_array(touchArrayPtr)
        touchArrayPtr = nil
        firstDev = nil
        deviceCount = 0
        engine.deviceID = 0
        mt_shutdown()

        guard mt_init() == 0 else {
            setTrackpadStatus(L10n.tr("触控板初始化失败", "Trackpad init failed"), retryable: true)
            return
        }
        deviceCount = mt_scan_devices_array(&touchArrayPtr)
        guard deviceCount > 0, let arr = touchArrayPtr else {
            setTrackpadStatus(L10n.tr("未检测到触控板（请在系统设置中授予「输入监控」权限）",
                                     "No trackpad detected (grant Input Monitoring in System Settings)"),
                              retryable: true)
            return
        }
        guard let dev = mt_device_at_index(arr, 0) else {
            setTrackpadStatus(L10n.tr("触控板设备无效", "Invalid trackpad device"), retryable: true)
            return
        }
        firstDev = dev
        let idOffset = mt_device_get_id(dev)
        let idIOReg = mt_device_get_id_by_index(0)
        engine.deviceID = idIOReg != 0 ? idIOReg : idOffset

        let ctxPtr = Unmanaged.passUnretained(self).toOpaque()
        mt_start_touch(dev, touchCallback, ctxPtr)
        engine.start()
        trackpadReady = true
        setTrackpadStatus(L10n.tr("触控板就绪（\(deviceCount) 个设备）", "Trackpad ready (\(deviceCount) devices)"),
                          retryable: false)
    }

    private func setTrackpadStatus(_ text: String, retryable: Bool) {
        statusMenuItem?.title = text
        retryMenuItem?.isHidden = !retryable
    }

    @objc private func retryTrackpad() {
        setupTrackpad()
    }

    /// 「移到应用程序」引导：非 /Applications 下运行的 .app（含 App Translocation 转移路径）
    /// 弹窗让用户选择移入 /Applications，从而让 TCC 权限（输入监控/辅助功能）跨启动持久。
    private func offerMoveToApplicationsIfNeeded() {
        let bundlePath = Bundle.main.bundlePath
        guard AppTranslocation.shouldOfferMoveToApplications(bundlePath: bundlePath) else { return }
        // 用户此前勾选「不再提示」则静默跳过
        if UserDefaults.standard.bool(forKey: "appTranslocation.neverOfferMove") { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.tr("建议移入「应用程序」", "Move to “Applications”")
        alert.informativeText = L10n.tr(
            "当前从非标准位置运行，系统权限（输入监控 / 辅助功能）可能无法跨启动保存。\n移到「应用程序」后可稳定保留权限。",
            "Running from a non-standard location may not persist system permissions.\nMove to Applications for a stable setup.")
        alert.addButton(withTitle: L10n.tr("移到应用程序", "Move to Applications"))
        alert.addButton(withTitle: L10n.tr("以后再说", "Later"))
        alert.addButton(withTitle: L10n.tr("不再提示", "Don’t ask again"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let source = Bundle.main.bundleURL
            let dest = AppTranslocation.applicationsDestination(forSource: source)
            moveToApplications(source: source, destination: dest)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: "appTranslocation.neverOfferMove")
        default:
            break
        }
    }

    /// 自动除转移 + 自愈：当前实例处于 App Translocation 随机路径时，
    /// 取回原始路径 → 移入 /Applications → 去隔离 → 重启 → 退出当前实例。
    /// 返回 true 表示已处理（当前实例即将退出，调用方应直接 return）。
    private func handleTranslocationSelfHeal() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        guard AppTranslocation.isRunningTranslocated(bundlePath: bundleURL.path) else { return false }
        guard let original = AppTranslocation.originalURLWhenTranslocated(bundleURL: bundleURL) else { return false }
        let destination = AppTranslocation.applicationsDestination(forSource: original)
        moveToApplications(source: original, destination: destination)
        return true
    }

    /// 执行移入：拷贝 source → 目标 /Applications → 去隔离属性 → 启动新实例 → 退出当前实例。
    /// source 通常为 `Bundle.main.bundleURL`（手动路径）或自愈取回的原始路径。
    private func moveToApplications(source: URL, destination: URL) {
        let dest = destination

        do {
            try FileManager.default.copyItem(at: source, to: dest)
        } catch let copyError as NSError {
            // 目标已存在（如旧版本在 /Applications）：先移除旧副本再拷贝
            if FileManager.default.fileExists(atPath: dest.path) {
                do {
                    try FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: source, to: dest)
                } catch {
                    showMoveError(error)
                    return
                }
            } else {
                showMoveError(copyError)
                return
            }
        }

        // 去隔离：去掉 com.apple.quarantine 等扩展属性，避免新副本再次被 App Translocation 转移
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-cr", dest.path]
        try? xattr.run()
        xattr.waitUntilExit()

        // 启动 /Applications 里的新实例，随后退出当前（转移路径）实例。
        // 因单实例检测已排除转移实例，新实例不会被本实例误杀。
        NSWorkspace.shared.open(dest)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.quit()
        }
    }

    private func showMoveError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("移入「应用程序」失败", "Failed to move to Applications")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.tr("知道了", "OK"))
        alert.runModal()
    }

    /// 单实例保护：返回 false 表示已有实例在运行
    private func ensureSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.zekiwithcat.TouchpadGestures"
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter {
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                // App 转移（路径含 /AppTranslocation/）中的旧实例在用户选择「移到应用程序」后
                // 即将退出；若不过滤，刚从 /Applications 启动的新实例会被旧实例误杀（同 bundleID）。
                && !($0.bundleURL?.path.contains("/AppTranslocation/") ?? false)
            }
            .isEmpty
    }

    private func activateExistingInstance() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.zekiwithcat.TouchpadGestures"
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?
            .activate()
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
        let iconColor = NSColor(calibratedRed: CGFloat(appSettings.appIconColorRed),
                                green: CGFloat(appSettings.appIconColorGreen),
                                blue: CGFloat(appSettings.appIconColorBlue), alpha: 1.0)
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

    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0" }
    var appBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1" }
    var trackpadDeviceID: UInt64 { engine.deviceID }
    var trackpadDeviceCount: Int32 { deviceCount }
    /// 引擎帧循环是否在运行（设置页「引擎状态」显示）
    var engineIsRunning: Bool { engine.isRunning }

    // MARK: - 手势健康检查（"权限全绿但无触控板反馈"时先看这里定位断点）

    /// 单个手势的健康状态：启用 / 绑定有效 / 图可执行（任一失败 = 该手势被引擎静默跳过）
    struct GestureHealth: Identifiable {
        let id: UUID
        let name: String
        let enabled: Bool
        let boundOK: Bool
        let graphOK: Bool
    }

    var gestureHealth: [GestureHealth] {
        config.gestures.map { g in
            // 闭包参数遮蔽修复：$0 在 contains 内被 RegionConfig 遮蔽，需显式命名 regionID/eventID
            let regionOK = g.boundRegionID.map { regionID in config.regions.contains { $0.id == regionID } } ?? false
            let eventOK = g.boundEventID.map { eventID in config.events.contains { $0.id == eventID } } ?? false
            // GraphEvaluator 构造失败（环/悬挂边）→ 引擎回退空执行器 → 该手势静默失效
            let graphOK = GraphEvaluator(timeline: g.timeline) != nil
            return GestureHealth(id: g.id, name: g.name, enabled: g.enabled,
                                 boundOK: regionOK && eventOK, graphOK: graphOK)
        }
    }

    // MARK: - 诊断日志开关（设置页可切换；落盘 /tmp/touchpad_run.log）

    var debugLoggingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "engine.debugLogging") }
        set {
            UserDefaults.standard.set(newValue, forKey: "engine.debugLogging")
            GestureEngine.forceDebugLogging = newValue
            NodeExecutors.debugLogging = newValue
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let hostingView = NSHostingView(rootView: ConfigView()
                .environmentObject(self))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            // 标题栏透明融入内容，整个窗口只有左右两栏
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = hostingView
            window.center()
            // 窗口关闭后释放引用：下次点击重建（避免复用可能已失效的窗口状态）
            window.delegate = self
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    // NSWindowDelegate：窗口关闭时清引用，保证每次 openSettings 操作的是活窗口
    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow, w === settingsWindow {
            settingsWindow = nil
        }
    }

    @objc func quit() {
        engine.stop()
        if let dev = firstDev { mt_stop_touch(dev) }
        mt_release_devices_array(touchArrayPtr)   // 归还设备 CFArray（quit 前释放）
        touchArrayPtr = nil
        mt_shutdown()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)   // 退出前移除状态栏图标
            statusItem = nil
        }
        NSApp.terminate(nil)
    }

    func updateConfig(_ newConfig: AppConfig) {
        config = newConfig
        engine.config = newConfig
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
    delegate.engine.onTouchFrame(touches: touchArray)
}

// ConfigView 已移至 Views/ConfigView.swift
