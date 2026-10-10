import Foundation
import ApplicationServices
import IOKit.hid
import Combine
import AppKit
import GestureEngine

// MARK: - 权限状态

enum PermissionStatus: String {
    case granted   // 已授权
    case denied    // 已拒绝
    case unknown   // 未请求

    var isOK: Bool { self == .granted }

    var label: String {
        switch self {
        case .granted: return L10n.tr("已授权", "Granted")
        case .denied:  return L10n.tr("已拒绝", "Denied")
        case .unknown: return L10n.tr("未授权", "Not Granted")
        }
    }

    var symbolName: String {
        switch self {
        case .granted: return "checkmark.circle.fill"
        case .denied:  return "xmark.circle.fill"
        case .unknown: return "exclamationmark.circle.fill"
        }
    }

    var color: String {
        switch self {
        case .granted: return "green"
        case .denied:  return "red"
        case .unknown: return "orange"
        }
    }
}

// MARK: - PermissionManager

/// 轮询检查 Input Monitoring + Accessibility 权限状态
final class PermissionManager: ObservableObject {

    @Published var inputMonitoring: PermissionStatus = .unknown
    @Published var accessibility: PermissionStatus = .unknown

    /// 输入监控权限从"未授权"变为"已授权"时回调（保留：部分机型上 MultitouchSupport
    /// 枚举设备会受输入监控影响，授权后自动重试触控板初始化，无需重启 app）
    var onInputMonitoringGranted: (() -> Void)?
    private var wasInputMonitoringGranted = false

    /// 辅助功能从"未授权"变为"已授权"时回调（执行手势走 CGEventTap 仅需辅助功能，
    /// 授权后自动重试触控板初始化，无需重启 app）
    var onAccessibilityGranted: (() -> Void)?
    private var wasAccessibilityGranted = false

    private var timer: Timer?

    init() {
        refresh()
        startPolling()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - 轮询

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        // Input Monitoring: IOHIDCheckAccess
        let hidAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch hidAccess {
        case kIOHIDAccessTypeGranted:
            // 边沿检测：只在"未授权 → 已授权"转变时回调（持续轮询期间每次 granted 都回调会重复初始化）
            if !wasInputMonitoringGranted { onInputMonitoringGranted?() }
            wasInputMonitoringGranted = true
            inputMonitoring = .granted
        case kIOHIDAccessTypeDenied:
            wasInputMonitoringGranted = false
            inputMonitoring = .denied
        default:
            wasInputMonitoringGranted = false
            inputMonitoring = .unknown
        }

        // Accessibility: AXIsProcessTrusted
        let axOK = AXIsProcessTrusted()
        if axOK && !wasAccessibilityGranted { onAccessibilityGranted?() }
        wasAccessibilityGranted = axOK
        accessibility = axOK ? .granted : .unknown
    }

    // MARK: - 请求权限

    /// 请求 Input Monitoring 权限（触发系统弹窗）
    func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// 请求 Accessibility 权限（触发系统弹窗）
    func requestAccessibility() {
        // kAXTrustedCheckOptionPrompt 是框架拥有的全局常量（非 +1 引用）：
        // 用 takeRetainedValue() 会转移本不属于我们的所有权 → 过度释放。
        // 正确做法是 takeUnretainedValue()。
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - 打开系统设置

    func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - 自愈：权限异常自动重置（仿 Mac Mouse Fix 的 AccessibilityCheck.m）

    /// 权限异常自愈：`tccutil reset` 清掉 bundleID 的旧授权记录后重新请求授权。
    ///
    /// 解决「已允许但仍未授予」——ad-hoc 签名 app 的 TCC 按「路径+签名身份(CDHash)」匹配，
    /// 多份拷贝（不同路径/CDHash）会让授权落到别的副本上。清空后重新请求，用户授权「当前
    /// 运行的这一份」即可生效。用户在设置页也可手动触发「重置授权」。
    ///
    /// 注意：仅处理**辅助功能**（本 app 唯一必需权限）。「输入监控」为可选、不影响
    /// 触控板读取（走 MultitouchSupport 私有框架，不受 TCC 输入监控门控），故不再请求，
    /// 避免误导用户以为必须授权。
    func autoResetAndReprompt() {
        // 顺序修正：必须等 tccutil 真正执行完再请求授权，否则弹窗可能发生在旧记录
        // 尚未清除时，授权又落到旧记录上（重置白做）。故用 terminationHandler 串行化。
        resetTCC(service: "Accessibility") { [weak self] in
            self?.requestAccessibility()
            // 给系统弹窗/授权落地留一点时间后再刷新状态（否则仍读到旧值）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.refresh()
            }
        }
    }

    /// 请求 Accessibility 权限（触发系统弹窗）。输入监控为可选项，不再自动请求。
    func requestRequiredPermissions() {
        if !accessibility.isOK {
            requestAccessibility()
        }
    }

    /// 启动时**只申请权限，绝不自动重置 TCC**。
    ///
    /// 原实现（`scheduleAutoResetIfNeeded`）在启动 3s 后只要权限未授予就无条件执行
    /// `tccutil reset Accessibility`——这会**摧毁用户已经授予的授权记录**并重新弹窗，
    /// 权限未生效时每次启动都循环一次，属于未经同意的破坏性操作。
    ///
    /// 现在自动路径只申请（幂等、无副作用）；「重置授权」保留为设置页的**显式**操作
    /// （见 ConfigView 的按钮 → `autoResetAndReprompt()`），由用户主动触发。
    func requestPermissionsOnLaunch() {
        requestRequiredPermissions()
    }

    private var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.zekiwithcat.TouchpadGestures"
    }

    /// 执行 `tccutil reset <service> <bundleID>`（清掉 TCC 里针对该 bundleID 的授权记录）。
    /// **只在用户显式点击「重置授权」时调用**。
    /// 不再 `waitUntilExit()` 阻塞主线程——tccutil 起停可能耗时数百毫秒，
    /// 阻塞主线程会让设置窗口卡住；改为 terminationHandler 异步收尾。
    private func resetTCC(service: String, completion: (() -> Void)? = nil) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", service, bundleID]
        if let completion {
            task.terminationHandler = { _ in
                DispatchQueue.main.async { completion() }
            }
        }
        do {
            try task.run()
        } catch {
            fputs("[Permission] tccutil 启动失败：\(error)\n", stderr)
            DispatchQueue.main.async { completion?() }   // 失败也要继续后续流程，避免卡死
        }
    }

    // MARK: - 便捷属性

    /// 权限是否全部就绪。仅由**辅助功能**决定——本 app 触控板读取走 MultitouchSupport
    /// 私有框架，不受 TCC「输入监控」门控；执行手势走 CGEventTap 仅需辅助功能。
    /// 「输入监控」是可选说明项，不参与功能可用性判定。
    var allGranted: Bool {
        accessibility.isOK
    }
}
