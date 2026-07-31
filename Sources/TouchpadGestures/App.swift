import SwiftUI
import GestureEngine
import mt_bridge
import CoreGraphics

// MARK: - 国际化工具（根据系统语言中英切换，不依赖 .strings 文件加载）

enum L10n {
    static let isChinese: Bool = {
        Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    }()
    /// 中英双语：第一个参数为中文，第二个为英文
    static func tr(_ zh: String, _ en: String) -> String { isChinese ? zh : en }
}

/// 默认配置（用于单项/全局重置）
private let defaultConfig = GestureConfig()

/// 默认软件设置（用于单项重置）
private let defaultAppSettings = AppSettings()

// MARK: - 软件设置（自启动 / 菜单栏图标 / 尺寸）

struct AppSettings: Codable, Equatable {
    /// 开机自启动
    var launchAtLogin: Bool = false
    /// 在 Dock 中显示
    var showInDock: Bool = false
    /// 菜单栏图标（SF Symbol 名称）
    var menuBarIcon: String = "hand.tap"
    /// 菜单栏图标尺寸（point size）
    var menuBarIconSize: CGFloat = 14
    /// App 图标颜色（RGB 0~1，默认白色）
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
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let engine = GestureEngine()
    @Published var appSettings: AppSettings {
        didSet { appSettings.save() }
    }
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
        // 根据 showInDock 决定 activationPolicy（先切换 policy，再设置图标，避免被重置）
        // .accessory = 不显示在 Dock（菜单栏 app 默认）
        // .regular = 显示在 Dock
        NSApp.setActivationPolicy(appSettings.showInDock ? .regular : .accessory)
        // 设置 app 图标为 hand.tap（非 bundle 环境没有 Assets.xcassets，用 SF Symbol 生成）
        // 必须在 setActivationPolicy 之后调用，否则图标会被 policy 切换重置
        applyAppIcon()

        // 初始化 mt_bridge
        guard mt_init() == 0 else {
            print("[ERROR] mt_init 失败")
            return
        }

        // 扫描设备
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

        // 菜单栏图标
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

    /// 应用菜单栏图标与尺寸
    func applyMenuBarIcon() {
        guard let button = statusItem?.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: appSettings.menuBarIconSize, weight: .regular)
        let name = appSettings.menuBarIcon.isEmpty ? "hand.tap" : appSettings.menuBarIcon
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Touchpad Gestures")?
            .withSymbolConfiguration(config)
    }

    /// 设置 app 图标（hand.tap SF Symbol，用 appSettings.appIconColor 着色）
    /// 通过 sourceAtop 合成把颜色填充到符号形状区域，isTemplate=false 防止系统自动着色
    func applyAppIcon() {
        let config = NSImage.SymbolConfiguration(pointSize: 96, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "hand.tap", accessibilityDescription: "Touchpad Gestures")?
            .withSymbolConfiguration(config) else { return }

        let size = NSSize(width: 128, height: 128)
        let colored = NSImage(size: size)
        colored.lockFocus()

        // 先把符号画到中心区域
        let drawRect = NSRect(
            x: (size.width - symbol.size.width) / 2,
            y: (size.height - symbol.size.height) / 2,
            width: symbol.size.width,
            height: symbol.size.height
        )
        symbol.draw(in: drawRect,
                    from: .zero, operation: .sourceOver, fraction: 1.0)

        // 用 sourceAtop 把颜色填充到符号不透明区域（着色）
        let iconColor = NSColor(
            calibratedRed: appSettings.appIconColorRed,
            green: appSettings.appIconColorGreen,
            blue: appSettings.appIconColorBlue,
            alpha: 1.0
        )
        iconColor.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)

        colored.unlockFocus()
        // 关键：设为非模板，否则系统会按上下文自动着色覆盖我们的颜色
        colored.isTemplate = false
        NSApp.applicationIconImage = colored
    }

    /// 切换 Dock 显示策略
    func applyDockPolicy() {
        NSApp.setActivationPolicy(appSettings.showInDock ? .regular : .accessory)
        // setActivationPolicy 会重置 app icon，需要重新设置
        applyAppIcon()
    }

    /// 设置开机自启动（通过 osascript 写入登录项，兼容非 bundle 可执行文件）
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

    /// 软件版本号
    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// 软件构建版本号
    var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// 触控板设备 ID
    var trackpadDeviceID: UInt64 { engine.deviceID }
    /// 触控板设备数量
    var trackpadDeviceCount: Int32 { deviceCount }

    @objc func openSettings() {
        if settingsWindow == nil {
            let hostingView = NSHostingView(rootView: ConfigView(config: engine.config)
                .environmentObject(self))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 760),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = L10n.tr("Touchpad Gestures 设置", "Touchpad Gestures Settings")
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.contentView = hostingView

            // 标题栏右侧 accessory：全局重置按钮（上浮到标题栏层级，两 tab 共享）
            let titlebarView = NSHostingView(rootView:
                ResetAllTitlebarButton { [weak self] in
                    self?.showResetAllAlert = true
                }
            )
            titlebarView.frame.size = NSSize(width: 110, height: 28)
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = titlebarView
            accessory.layoutAttribute = .trailing
            window.addTitlebarAccessoryViewController(accessory)

            window.center()
            settingsWindow = window
        }
        // 菜单栏点击强制窗口前置：activate + orderFrontRegardless
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    /// 触发全局重置弹窗（由标题栏按钮调用）
    @Published var showResetAllAlert = false

    @objc func quit() {
        engine.restoreMouse()
        if let dev = firstDev { mt_stop_touch(dev) }
        mt_shutdown()
        NSApp.terminate(nil)
    }

    func updateConfig(_ config: GestureConfig) {
        engine.config = config
    }
}

// MARK: - 触摸回调

private let touchCallback: @convention(c) (
    _ dev: UnsafeMutableRawPointer?,
    _ touches: UnsafePointer<mt_touch_t>?,
    _ n: Int32,
    _ timestamp: Double,
    _ frame: Int32,
    _ userData: UnsafeMutableRawPointer?
) -> Void = { _, touches, n, _, _, userData in
    guard let userData = userData else { return }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()

    var touchArray: [mt_touch_t] = []
    if let touches = touches, n > 0 {
        for i in 0..<Int(n) {
            touchArray.append(touches[i])
        }
    }
    delegate.engine.processFrame(touches: touchArray)
}

// MARK: - 设置界面

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

/// 触觉波形对照表：列出所有已知波形 ID 的触感，并标注当前项目中的使用位置
/// 数据来源：mt_bridge.h 中 mactic 探测到的有效 waveform
struct HapticWaveformReference: View {
    let config: GestureConfig

    /// (id, 中文描述, 英文描述)
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

    /// 根据 ID 返回当前项目中的使用位置（进入反馈 / 滑动刻度 / 边界震动）
    private func usageLabel(id: Int32) -> String {
        var usages: [String] = []
        if config.hapticEnter == id     { usages.append(L10n.tr("进入反馈", "Enter")) }
        if config.hapticTick == id      { usages.append(L10n.tr("滑动刻度", "Tick")) }
        if config.hapticBoundary == id  { usages.append(L10n.tr("边界震动", "Boundary")) }
        return usages.isEmpty ? "—" : usages.joined(separator: " / ")
    }

    var body: some View {
        // 表头
        HStack {
            Text(L10n.tr("ID", "ID"))
                .frame(width: 40, alignment: .leading)
            Text(L10n.tr("触感", "Sensation"))
                .frame(width: 150, alignment: .leading)
            Text(L10n.tr("本项目用途", "Used For"))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

        ForEach(waveforms, id: \.0) { item in
            HStack {
                Text("\(item.0)")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .leading)
                Text(L10n.tr(item.1, item.2))
                    .frame(width: 150, alignment: .leading)
                Text(usageLabel(id: item.0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct ConfigView: View {
    @State var config: GestureConfig
    @EnvironmentObject var appDelegate: AppDelegate
    /// "恢复代码默认"确认弹窗
    @State private var showRestoreFactoryAlert = false
    /// "保存为默认"成功提示
    @State private var showSavedAsDefault = false

    /// 单项重置按钮（小图标，直接恢复默认值，不弹窗）
    @ViewBuilder
    private func resetButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(L10n.tr("重置为默认值", "Reset to default"))
    }

    /// Toggle 行：标签 + Toggle（labelsHidden）+ resetButton
    @ViewBuilder
    private func toggleRow(_ label: String, isOn: Binding<Bool>, reset: @escaping () -> Void) -> some View {
        HStack {
            Text(label).frame(width: 150, alignment: .leading)
            Toggle("", isOn: isOn).labelsHidden()
            Spacer()
            resetButton(reset)
        }
    }

    /// Stepper 行：标签 + Stepper + resetButton（Int32 版本）
    @ViewBuilder
    private func stepperRow(_ label: String, value: Binding<Int32>, in range: ClosedRange<Int32>, reset: @escaping () -> Void) -> some View {
        HStack {
            Text(label).frame(width: 150, alignment: .leading)
            Stepper(value: value, in: range) { Text("\(value.wrappedValue)") }
            resetButton(reset)
        }
    }

    var body: some View {
        TabView {
        // 左：手势设置
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 1. 触摸数据流
                Card(title: L10n.tr("1. 触摸数据流", "1. Touch Data Stream")) {
                    HStack {
                        Text(L10n.tr("帧处理限频 (Hz)", "Frame Rate Limit (Hz)"))
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $config.frameRateLimit, in: 0...240)
                        Text(config.frameRateLimit < 1 ? L10n.tr("不限", "off") : String(format: "%.0f", config.frameRateLimit))
                            .monospacedDigit().frame(width: 50, alignment: .trailing)
                        resetButton { config.frameRateLimit = defaultConfig.frameRateLimit }
                    }
                    HStack {
                        Text(L10n.tr("接触面积下限", "Touch Size Min"))
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $config.touchSizeMin, in: 0...0.5)
                        Text(String(format: "%.2f", config.touchSizeMin))
                            .monospacedDigit().frame(width: 50, alignment: .trailing)
                        resetButton { config.touchSizeMin = defaultConfig.touchSizeMin }
                    }
                    HStack {
                        Text(L10n.tr("接触面积上限", "Touch Size Max"))
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $config.touchSizeMax, in: 0.5...2.0)
                        Text(String(format: "%.2f", config.touchSizeMax))
                            .monospacedDigit().frame(width: 50, alignment: .trailing)
                        resetButton { config.touchSizeMax = defaultConfig.touchSizeMax }
                    }
                }

                // 2. 第一次轻点
                Card(title: L10n.tr("2. 第一次轻点（idle → firstTapDown → firstTapUp）",
                                "2. First Tap (idle → firstTapDown → firstTapUp)")) {
                    HStack {
                        Text(L10n.tr("右侧阈值（音量）", "Right Threshold (Volume)"))
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $config.edgeRightThreshold, in: 0.5...0.95)
                        Text(String(format: "%.2f", config.edgeRightThreshold))
                            .monospacedDigit().frame(width: 50, alignment: .trailing)
                        resetButton { config.edgeRightThreshold = defaultConfig.edgeRightThreshold }
                    }
                    HStack {
                        Text(L10n.tr("左侧阈值（亮度）", "Left Threshold (Brightness)"))
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $config.edgeLeftThreshold, in: 0.05...0.5)
                        Text(String(format: "%.2f", config.edgeLeftThreshold))
                            .monospacedDigit().frame(width: 50, alignment: .trailing)
                        resetButton { config.edgeLeftThreshold = defaultConfig.edgeLeftThreshold }
                    }
                    HStack {
                        Text(L10n.tr("最长轻点时长 (s)", "Max Tap Duration (s)"))
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $config.tapMaxDuration, in: 0.1...0.5)
                        Text(String(format: "%.2f", config.tapMaxDuration))
                            .monospacedDigit().frame(width: 50, alignment: .trailing)
                        resetButton { config.tapMaxDuration = defaultConfig.tapMaxDuration }
                    }
                    HStack {
                        Text(L10n.tr("最大位移容差", "Max Drift"))
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $config.tapMaxDrift, in: 0.01...0.15)
                        Text(String(format: "%.3f", config.tapMaxDrift))
                            .monospacedDigit().frame(width: 50, alignment: .trailing)
                        resetButton { config.tapMaxDrift = defaultConfig.tapMaxDrift }
                    }
                }

                // 3. 两次轻点衔接
                Card(title: L10n.tr("3. 两次轻点衔接（firstTapUp → secondTapDown）",
                                "3. Two-Tap Gap (firstTapUp → secondTapDown)")) {
                    HStack {
                        Text(L10n.tr("两次轻点间隔 (s)", "Tap Gap (s)"))
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $config.tapMaxGap, in: 0.1...0.6)
                        Text(String(format: "%.2f", config.tapMaxGap))
                            .monospacedDigit().frame(width: 50, alignment: .trailing)
                        resetButton { config.tapMaxGap = defaultConfig.tapMaxGap }
                    }
                }

                // 4. 第二次轻点保持
                Card(title: L10n.tr("4. 第二次轻点保持（secondTapDown → holding）",
                                "4. Second Tap Hold (secondTapDown → holding)")) {
                    HStack {
                        Text(L10n.tr("保持确认时长 (s)", "Hold Confirm (s)"))
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $config.holdMinDuration, in: 0.1...0.5)
                        Text(String(format: "%.2f", config.holdMinDuration))
                            .monospacedDigit().frame(width: 50, alignment: .trailing)
                        resetButton { config.holdMinDuration = defaultConfig.holdMinDuration }
                    }
                    stepperRow(L10n.tr("进入反馈波形", "Enter Haptic Waveform"),
                               value: $config.hapticEnter, in: 1...16) {
                        config.hapticEnter = defaultConfig.hapticEnter
                    }
                }

                // 5. 滑动调节
                Card(title: L10n.tr("5. 滑动调节（holding 状态）",
                                "5. Slide Adjust (holding)")) {
                    HStack {
                        Text(L10n.tr("音量滑动刻度", "Volume Slide Step"))
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $config.volumeStepNorm, in: 0.005...0.05)
                        Text(String(format: "%.3f", config.volumeStepNorm))
                            .monospacedDigit().frame(width: 50, alignment: .trailing)
                        resetButton { config.volumeStepNorm = defaultConfig.volumeStepNorm }
                    }
                    HStack {
                        Text(L10n.tr("音量变化", "Volume Change"))
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $config.volumeStep, in: 0.005...0.05)
                        Text(String(format: "%.1f%%", config.volumeStep * 100))
                            .monospacedDigit().frame(width: 50, alignment: .trailing)
                        resetButton { config.volumeStep = defaultConfig.volumeStep }
                    }
                    HStack {
                        Text(L10n.tr("亮度滑动刻度", "Brightness Slide Step"))
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $config.brightnessStepNorm, in: 0.005...0.05)
                        Text(String(format: "%.3f", config.brightnessStepNorm))
                            .monospacedDigit().frame(width: 50, alignment: .trailing)
                        resetButton { config.brightnessStepNorm = defaultConfig.brightnessStepNorm }
                    }
                    HStack {
                        Text(L10n.tr("亮度变化", "Brightness Change"))
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $config.brightnessStep, in: 0.005...0.05)
                        Text(String(format: "%.1f%%", config.brightnessStep * 100))
                            .monospacedDigit().frame(width: 50, alignment: .trailing)
                        resetButton { config.brightnessStep = defaultConfig.brightnessStep }
                    }
                    stepperRow(L10n.tr("刻度反馈波形", "Tick Haptic Waveform"),
                               value: $config.hapticTick, in: 1...16) {
                        config.hapticTick = defaultConfig.hapticTick
                    }
                }

                // 6. 边界检测
                Card(title: L10n.tr("6. 边界检测（0% / 100%）",
                                "6. Boundary Detection (0% / 100%)")) {
                    HStack {
                        Text(L10n.tr("边界判定阈值", "Boundary Threshold"))
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $config.boundaryThreshold, in: 0.001...0.05)
                        Text(String(format: "%.3f", config.boundaryThreshold))
                            .monospacedDigit().frame(width: 50, alignment: .trailing)
                        resetButton { config.boundaryThreshold = defaultConfig.boundaryThreshold }
                    }
                    stepperRow(L10n.tr("边界强震动波形", "Boundary Haptic Waveform"),
                               value: $config.hapticBoundary, in: 1...16) {
                        config.hapticBoundary = defaultConfig.hapticBoundary
                    }
                    HStack {
                        Text(L10n.tr("边界震动间隔 (ms)", "Boundary Haptic Interval (ms)"))
                            .frame(width: 150, alignment: .leading)
                        Slider(value: Binding(
                            get: { Double(config.boundaryHapticInterval) / 1000.0 },
                            set: { config.boundaryHapticInterval = Int32($0 * 1000) }
                        ), in: 10...200)
                        Text(String(format: "%.0f", Double(config.boundaryHapticInterval) / 1000.0))
                            .monospacedDigit().frame(width: 50, alignment: .trailing)
                        resetButton { config.boundaryHapticInterval = defaultConfig.boundaryHapticInterval }
                    }
                }

                // 7. 鼠标控制
                Card(title: L10n.tr("7. 鼠标控制", "7. Mouse Control")) {
                    toggleRow(L10n.tr("进入 holding 时解除鼠标关联", "Disassociate mouse on holding"),
                              isOn: $config.disassociateMouse) {
                        config.disassociateMouse = defaultConfig.disassociateMouse
                    }
                }

                // 8. 触觉波形对照
                Card(title: L10n.tr("8. 触觉波形对照", "8. Haptic Waveform Reference")) {
                    HapticWaveformReference(config: config)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .tabItem { Label(L10n.tr("手势设置", "Gestures"), systemImage: "hand.tap") }

        // 右：软件设置
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Card(title: L10n.tr("软件信息", "App Info")) {
                        HStack {
                            Text(L10n.tr("名称", "Name"))
                                .frame(width: 150, alignment: .leading)
                            Text("Touchpad Gestures")
                            Spacer()
                        }
                        HStack {
                            Text(L10n.tr("版本", "Version"))
                                .frame(width: 150, alignment: .leading)
                            Text("\(appDelegate.appVersion) (\(appDelegate.appBuild))")
                                .monospacedDigit()
                            Spacer()
                        }
                    }

                    Card(title: L10n.tr("触控板规格", "Trackpad Spec")) {
                        HStack {
                            Text(L10n.tr("检测到的设备数", "Detected Devices"))
                                .frame(width: 150, alignment: .leading)
                            Text("\(appDelegate.trackpadDeviceCount)")
                                .monospacedDigit()
                            Spacer()
                        }
                        HStack {
                            Text(L10n.tr("设备 ID", "Device ID"))
                                .frame(width: 150, alignment: .leading)
                            Text(String(format: "%llu", appDelegate.trackpadDeviceID))
                                .monospacedDigit()
                                .textSelection(.enabled)
                            Spacer()
                        }
                    }

                    Card(title: L10n.tr("启动", "Startup")) {
                        toggleRow(L10n.tr("登录时自动启动", "Launch at login"),
                                  isOn: Binding(
                            get: { appDelegate.appSettings.launchAtLogin },
                            set: { newVal in
                                appDelegate.appSettings.launchAtLogin = newVal
                                appDelegate.setLaunchAtLogin(newVal)
                            }
                        )) {
                            appDelegate.appSettings.launchAtLogin = defaultAppSettings.launchAtLogin
                            appDelegate.setLaunchAtLogin(defaultAppSettings.launchAtLogin)
                        }
                        toggleRow(L10n.tr("在 Dock 中显示", "Show in Dock"),
                                  isOn: Binding(
                            get: { appDelegate.appSettings.showInDock },
                            set: { newVal in
                                appDelegate.appSettings.showInDock = newVal
                                appDelegate.applyDockPolicy()
                            }
                        )) {
                            appDelegate.appSettings.showInDock = defaultAppSettings.showInDock
                            appDelegate.applyDockPolicy()
                        }
                    }

                    Card(title: L10n.tr("菜单栏图标", "Menu Bar Icon")) {
                        HStack {
                            Text(L10n.tr("图标 (SF Symbol)", "Icon (SF Symbol)"))
                                .frame(width: 150, alignment: .leading)
                            TextField("hand.tap", text: Binding(
                                get: { appDelegate.appSettings.menuBarIcon },
                                set: { newVal in
                                    appDelegate.appSettings.menuBarIcon = newVal
                                    appDelegate.applyMenuBarIcon()
                                }
                            ))
                            .frame(maxWidth: 200)
                            Spacer()
                            resetButton {
                                appDelegate.appSettings.menuBarIcon = defaultAppSettings.menuBarIcon
                                appDelegate.applyMenuBarIcon()
                            }
                        }
                        HStack {
                            Text(L10n.tr("图标尺寸", "Icon Size"))
                                .frame(width: 150, alignment: .leading)
                            Slider(value: Binding(
                                get: { appDelegate.appSettings.menuBarIconSize },
                                set: { newVal in
                                    appDelegate.appSettings.menuBarIconSize = newVal
                                    appDelegate.applyMenuBarIcon()
                                }
                            ), in: 10...24)
                            Text(String(format: "%.0f", appDelegate.appSettings.menuBarIconSize))
                                .monospacedDigit().frame(width: 50, alignment: .trailing)
                            resetButton {
                                appDelegate.appSettings.menuBarIconSize = defaultAppSettings.menuBarIconSize
                                appDelegate.applyMenuBarIcon()
                            }
                        }
                        HStack {
                            Text(L10n.tr("预览", "Preview"))
                                .frame(width: 150, alignment: .leading)
                            Image(systemName: appDelegate.appSettings.menuBarIcon.isEmpty ? "hand.tap" : appDelegate.appSettings.menuBarIcon)
                                .imageScale(.large)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }

                    Card(title: L10n.tr("App 图标", "App Icon")) {
                        // 预设色板
                        HStack {
                            Text(L10n.tr("颜色", "Color"))
                                .frame(width: 150, alignment: .leading)
                            ForEach([
                                (NSColor.white,  "白"),
                                (NSColor.black,  "黑"),
                                (NSColor.systemRed,    "红"),
                                (NSColor.systemOrange, "橙"),
                                (NSColor.systemYellow, "黄"),
                                (NSColor.systemGreen,  "绿"),
                                (NSColor.systemCyan,   "青"),
                                (NSColor.systemBlue,   "蓝"),
                                (NSColor.systemPurple, "紫"),
                                (NSColor.systemPink,   "粉"),
                            ], id: \.1) { color, _ in
                                Circle()
                                    .fill(Color(nsColor: color))
                                    .frame(width: 18, height: 18)
                                    .overlay(
                                        Circle().stroke(.separator, lineWidth: 0.5)
                                    )
                                    .help(L10n.tr("选择颜色", "Pick color"))
                                    .onTapGesture {
                                        appDelegate.appSettings.appIconColorRed = color.redComponent
                                        appDelegate.appSettings.appIconColorGreen = color.greenComponent
                                        appDelegate.appSettings.appIconColorBlue = color.blueComponent
                                        appDelegate.applyAppIcon()
                                    }
                            }
                            Spacer()
                            resetButton {
                                appDelegate.appSettings.appIconColorRed = 1.0
                                appDelegate.appSettings.appIconColorGreen = 1.0
                                appDelegate.appSettings.appIconColorBlue = 1.0
                                appDelegate.applyAppIcon()
                            }
                        }
                        // 自定义 RGB
                        HStack {
                            Text(L10n.tr("R", "R"))
                                .frame(width: 150, alignment: .leading)
                            Slider(value: Binding(
                                get: { appDelegate.appSettings.appIconColorRed },
                                set: { newVal in
                                    appDelegate.appSettings.appIconColorRed = newVal
                                    appDelegate.applyAppIcon()
                                }
                            ), in: 0...1)
                            Text(String(format: "%.2f", appDelegate.appSettings.appIconColorRed))
                                .monospacedDigit().frame(width: 50, alignment: .trailing)
                        }
                        HStack {
                            Text(L10n.tr("G", "G"))
                                .frame(width: 150, alignment: .leading)
                            Slider(value: Binding(
                                get: { appDelegate.appSettings.appIconColorGreen },
                                set: { newVal in
                                    appDelegate.appSettings.appIconColorGreen = newVal
                                    appDelegate.applyAppIcon()
                                }
                            ), in: 0...1)
                            Text(String(format: "%.2f", appDelegate.appSettings.appIconColorGreen))
                                .monospacedDigit().frame(width: 50, alignment: .trailing)
                        }
                        HStack {
                            Text(L10n.tr("B", "B"))
                                .frame(width: 150, alignment: .leading)
                            Slider(value: Binding(
                                get: { appDelegate.appSettings.appIconColorBlue },
                                set: { newVal in
                                    appDelegate.appSettings.appIconColorBlue = newVal
                                    appDelegate.applyAppIcon()
                                }
                            ), in: 0...1)
                            Text(String(format: "%.2f", appDelegate.appSettings.appIconColorBlue))
                                .monospacedDigit().frame(width: 50, alignment: .trailing)
                        }
                        // 预览
                        HStack {
                            Text(L10n.tr("预览", "Preview"))
                                .frame(width: 150, alignment: .leading)
                            Image(systemName: "hand.tap")
                                .imageScale(.large)
                                .font(.system(size: 28))
                                .foregroundStyle(Color(nsColor: NSColor(
                                    calibratedRed: appDelegate.appSettings.appIconColorRed,
                                    green: appDelegate.appSettings.appIconColorGreen,
                                    blue: appDelegate.appSettings.appIconColorBlue,
                                    alpha: 1.0
                                )))
                            Spacer()
                        }
                    }

                    // 配置默认值管理
                    Card(title: L10n.tr("配置默认值", "Config Defaults")) {
                        HStack {
                            Button(L10n.tr("保存当前为默认", "Save as Default")) {
                                config.saveAsDefault()
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
                        Text(L10n.tr(
                            "「保存为默认」后，重置全部将恢复到此配置；「恢复代码默认值」会清除自定义默认。",
                            "After 'Save as Default', 'Reset All' restores to this config; 'Restore Factory Defaults' clears the custom default."
                        ))
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
        .tabItem { Label(L10n.tr("软件设置", "App Settings"), systemImage: "gearshape") }
        }
        .frame(width: 580, height: 700)
        .onChange(of: config) { newConfig in
            appDelegate.updateConfig(newConfig)
        }
        .alert(L10n.tr("确认重置全部配置？", "Reset all settings?"),
               isPresented: $appDelegate.showResetAllAlert) {
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
            Button(L10n.tr("重置", "Reset"), role: .destructive) {
                // 重置到用户自定义默认（若存在），否则代码默认值
                config = GestureConfig.loadDefault()
            }
        } message: {
            Text(L10n.tr("所有配置将恢复为默认值，此操作不可撤销。",
                        "All settings will be restored to defaults. This cannot be undone."))
        }
        .alert(L10n.tr("确认恢复代码默认值？", "Restore factory defaults?"),
               isPresented: $showRestoreFactoryAlert) {
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
            Button(L10n.tr("恢复", "Restore"), role: .destructive) {
                GestureConfig.clearUserDefault()
                config = GestureConfig()
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
