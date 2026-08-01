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
        case .settings: return nil
        }
    }

    var currentSecondaryName: String? {
        switch currentEditingTab {
        case .gestures: return config.gestures.first { $0.id == selectedGestureID }?.name ?? config.gestures.first?.name
        case .events:   return config.events.first { $0.id == selectedEventID }?.name ?? config.events.first?.name
        case .regions:  return config.regions.first { $0.id == selectedRegionID }?.name ?? config.regions.first?.name
        case .settings: return nil
        }
    }

    var canDeleteSecondary: Bool {
        switch currentEditingTab {
        case .gestures: return config.gestures.count > 1
        case .events:   return config.events.count > 1
        case .regions:  return config.regions.count > 1
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
        case .settings: break
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
            let bound = config.gestures.filter { $0.eventID == id }.count
            if bound > 0 { pendingDelete = .event(id); showDeleteAlert = true }
            else { performEventDelete(id) }
        case .regions:
            let bound = config.gestures.filter { $0.regionID == id }.count
            if bound > 0 { pendingDelete = .region(id); showDeleteAlert = true }
            else { performRegionDelete(id) }
        case .settings: break
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
        for i in 0..<config.gestures.count {
            if config.gestures[i].eventID == id { config.gestures[i].eventID = first.id }
        }
        config.events.removeAll { $0.id == id }
        if selectedEventID == id { selectedEventID = first.id }
    }

    private func performRegionDelete(_ id: UUID) {
        guard let first = config.regions.first(where: { $0.id != id }) else { return }
        for i in 0..<config.gestures.count {
            if config.gestures[i].regionID == id { config.gestures[i].regionID = first.id }
        }
        config.regions.removeAll { $0.id == id }
        if selectedRegionID == id { selectedRegionID = first.id }
    }

    func boundGestureCount(for target: DeleteTarget) -> Int {
        switch target {
        case .event(let id):  return config.gestures.filter { $0.eventID == id }.count
        case .region(let id): return config.gestures.filter { $0.regionID == id }.count
        }
    }

    private var touchArrayPtr: UnsafeMutableRawPointer? = nil
    private var deviceCount: Int32 = 0
    private var firstDev: mt_device_t? = nil
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(appSettings.showInDock ? .regular : .accessory)
        applyAppIcon()

        // 首次启动请求权限（PermissionManager 轮询会持续检查状态）
        if !permissionManager.accessibility.isOK {
            permissionManager.requestAccessibility()
        }

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
            let hostingView = NSHostingView(rootView: ConfigView()
                .environmentObject(self))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            // 标题栏透明融入内容，整个窗口只有左右两栏
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = hostingView
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
    delegate.engine.processFrame(touches: touchArray)
}

// ConfigView 已移至 Views/ConfigView.swift
