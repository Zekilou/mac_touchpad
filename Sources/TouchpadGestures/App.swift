import SwiftUI
import GestureEngine
import mt_bridge
import CoreGraphics

// MARK: - 国际化工具（根据系统语言中英切换，不依赖 .strings 文件加载）

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
