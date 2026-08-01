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
        case kIOHIDAccessTypeGranted: inputMonitoring = .granted
        case kIOHIDAccessTypeDenied:  inputMonitoring = .denied
        default:                       inputMonitoring = .unknown
        }

        // Accessibility: AXIsProcessTrusted
        accessibility = AXIsProcessTrusted() ? .granted : .unknown
    }

    // MARK: - 请求权限

    /// 请求 Input Monitoring 权限（触发系统弹窗）
    func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// 请求 Accessibility 权限（触发系统弹窗）
    func requestAccessibility() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
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

    // MARK: - 便捷属性

    var allGranted: Bool {
        inputMonitoring.isOK && accessibility.isOK
    }
}
