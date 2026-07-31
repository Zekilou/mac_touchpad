//  TrackpadHIDTool — 最基础解析
//  通过 IOKit HID 发现内置触控板，打开设备，注册两路回调：
//    1) InputReportCallback —— 原始报告字节（用于逆向报告格式）
//    2) InputValueCallback   —— IOKit 已解析的元素值（X/Y/Touch/Pressure 等）
//  目标：先把 HID 数据通路打通，确认能拿到真实触摸数据。

import Foundation
import IOKit
import IOKit.hid

// MARK: - 常量

private let kUsagePage_VendorDefined: UInt32 = 0xFF00
private let kReportBufferSize = 8192  // 覆盖 reportID=68 的 1751 字节报告

// MARK: - 监控器

final class TrackpadHIDMonitor {
    private var manager: IOHIDManager?
    private var deviceBuffers: [IOHIDDevice: UnsafeMutablePointer<UInt8>] = [:]
    private var trackedDevices: [IOHIDDevice] = []

    deinit {
        for (_, buf) in deviceBuffers {
            buf.deinitialize(count: kReportBufferSize)
            buf.deallocate()
        }
    }

    func start() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(0))

        // 不设 matching —— 匹配所有 HID 设备，在回调里按 Product 名过滤触控板
        // （Apple 内置触控板常暴露为 Vendor-defined usage，而非标准 TouchPad）
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(),
                                        CFRunLoopMode.defaultMode.rawValue)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceMatchedCb, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemovedCb, ctx)

        let openRes = IOHIDManagerOpen(manager, IOOptionBits(0))
        print("[DIAG] IOHIDManagerOpen 结果: 0x\(String(openRes, radix: 16))")
        guard openRes == kIOReturnSuccess else {
            print("[ERROR] 打开 IOHIDManager 失败")
            return
        }
        self.manager = manager
        print("[INFO] HID Manager 已启动，匹配所有 HID 设备 ...")

        // run loop 跑起来后异步复查匹配到的设备
        let weakMgr = manager
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if let set = IOHIDManagerCopyDevices(weakMgr) {
                let n = CFSetGetCount(set)
                print("[DIAG] 1s 后已匹配设备数: \(n)")
                let ptrs = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: n)
                CFSetGetValues(set, ptrs)
                for i in 0..<n {
                    if let p = ptrs[i] {
                        self.onDeviceMatched(p.assumingMemoryBound(to: IOHIDDevice.self).pointee)
                    }
                }
                ptrs.deallocate()
            } else {
                print("[DIAG] 1s 后 CopyDevices 仍为 nil")
            }
        }
    }

    // MARK: 设备事件

    fileprivate func onDeviceMatched(_ device: IOHIDDevice) {
        let product = stringProperty(device, kIOHIDProductKey) ?? "?"
        let transport = stringProperty(device, kIOHIDTransportKey) ?? "?"
        let page = anyProperty(device, kIOHIDPrimaryUsagePageKey) ?? "?"
        let usage = anyProperty(device, "PrimaryUsage") ?? "?"
        print("[SCAN] \(product) | transport=\(transport) page=\(page) usage=\(usage)")

        // 只处理触控板触摸帧接口：page=0xFF00 (Vendor-defined) + usage=0xD (13)
        // usage=0xD 的 rid=83 报告为 63 字节，符合 Apple 多点触摸帧格式
        // （参考 Linux magicmouse / mtrack 驱动）
        guard page == "65280", usage == "13" else { return }

        printDeviceInfo(device)
        enumerateElements(device)

        // 每个设备独立 buffer（避免多设备共用导致并发溢出）
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: kReportBufferSize)
        buf.initialize(repeating: 0, count: kReportBufferSize)
        deviceBuffers[device] = buf

        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(),
                                       CFRunLoopMode.defaultMode.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device,
                                               buf,
                                               kReportBufferSize,
                                               inputReportCb, ctx)
        trackedDevices.append(device)
        print("[INFO] 已注册触摸帧回调 (page=0xff00 usage=0xd)")
    }

    private func isLikelyTrackpad(_ device: IOHIDDevice) -> Bool {
        let product = (stringProperty(device, kIOHIDProductKey) ?? "").lowercased()
        return product.contains("trackpad") || product.contains("touch")
            || product.contains("multitouch")
    }

    fileprivate func onDeviceRemoved(_ device: IOHIDDevice) {
        let name = stringProperty(device, kIOHIDProductKey) ?? "?"
        print("[INFO] 设备移除: \(name)")
        if let buf = deviceBuffers.removeValue(forKey: device) {
            buf.deinitialize(count: kReportBufferSize)
            buf.deallocate()
        }
    }

    // MARK: 数据回调处理

    fileprivate func handleReport(_ report: UnsafePointer<UInt8>,
                                  length: Int, type: IOHIDReportType, reportID: UInt32) {
        let n = min(length, 48)
        let hex = (0..<n).map { String(format: "%02X", report[$0]) }.joined(separator: " ")
        print("[REPORT] id=\(reportID) type=\(type.rawValue) len=\(length) | \(hex)")
    }

    fileprivate func handleValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page  = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let type  = IOHIDElementGetType(element)
        let cookie = IOHIDElementGetCookie(element)
        let intVal  = IOHIDValueGetIntegerValue(value)
        let physVal = IOHIDValueGetScaledValue(value, IOHIDValueScaleType(1))
        let reportID = IOHIDElementGetReportID(element)
        print("[VALUE] cookie=\(cookie) rid=\(reportID) page=0x\(String(page, radix: 16)) "
              + "usage=0x\(String(usage, radix: 16)) type=\(type.rawValue) "
              + "int=\(intVal) phys=\(String(format: "%.4f", physVal))")
    }

    // MARK: 设备信息

    private func printDeviceInfo(_ device: IOHIDDevice) {
        print("------ Trackpad Device ------")
        print("  Product     : \(stringProperty(device, kIOHIDProductKey) ?? "n/a")")
        print("  Manufacturer: \(stringProperty(device, kIOHIDManufacturerKey) ?? "n/a")")
        print("  VendorID    : \(stringProperty(device, kIOHIDVendorIDKey) ?? "n/a")")
        print("  ProductID   : \(stringProperty(device, kIOHIDProductIDKey) ?? "n/a")")
        print("  Transport   : \(stringProperty(device, kIOHIDTransportKey) ?? "n/a")")
        print("  PhysWidth   : \(anyProperty(device, "PhysicalWidth") ?? "n/a")")
        print("  PhysHeight  : \(anyProperty(device, "PhysicalHeight") ?? "n/a")")
        print("------------------------------")
    }

    private func enumerateElements(_ device: IOHIDDevice) {
        guard let arr = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(0)) as? [IOHIDElement] else {
            print("  Elements: 0 (无法枚举)")
            return
        }
        print("  Elements: \(arr.count)  (显示前 60 个)")
        for e in arr.prefix(60) {
            let page = IOHIDElementGetUsagePage(e)
            let usage = IOHIDElementGetUsage(e)
            let type = IOHIDElementGetType(e).rawValue
            let cookie = IOHIDElementGetCookie(e)
            let min = IOHIDElementGetLogicalMin(e)
            let max = IOHIDElementGetLogicalMax(e)
            let size = IOHIDElementGetReportSize(e)
            let cnt = IOHIDElementGetReportCount(e)
            let rid = IOHIDElementGetReportID(e)
            print("    [cookie=\(cookie) rid=\(rid) page=0x\(String(page, radix: 16)) "
                  + "usage=0x\(String(usage, radix: 16)) type=\(type) "
                  + "bits=\(size) cnt=\(cnt) min=\(min) max=\(max)]")
        }
    }

    private func stringProperty(_ d: IOHIDDevice, _ key: String) -> String? {
        guard let v = IOHIDDeviceGetProperty(d, key as CFString) else { return nil }
        return "\(v)"
    }
    private func anyProperty(_ d: IOHIDDevice, _ key: String) -> String? {
        guard let v = IOHIDDeviceGetProperty(d, key as CFString) else { return nil }
        return "\(v)"
    }
}

// MARK: - @convention(c) 回调（不能捕获上下文，通过 context 指针取回 self）

private let deviceMatchedCb: IOHIDDeviceCallback = { context, _, _, device in
    guard let context = context else { return }
    Unmanaged<TrackpadHIDMonitor>.fromOpaque(context).takeUnretainedValue().onDeviceMatched(device)
}

private let deviceRemovedCb: IOHIDDeviceCallback = { context, _, _, device in
    guard let context = context else { return }
    Unmanaged<TrackpadHIDMonitor>.fromOpaque(context).takeUnretainedValue().onDeviceRemoved(device)
}

private let inputReportCb: IOHIDReportCallback = { context, _, _, type, reportID, report, length in
    guard let context = context else { return }
    Unmanaged<TrackpadHIDMonitor>.fromOpaque(context).takeUnretainedValue()
        .handleReport(report, length: length, type: type, reportID: reportID)
}

private let inputValueCb: IOHIDValueCallback = { context, _, _, value in
    guard let context = context else { return }
    Unmanaged<TrackpadHIDMonitor>.fromOpaque(context).takeUnretainedValue().handleValue(value)
}

// MARK: - 入口

setvbuf(stdout, nil, _IONBF, 0)  // 关闭 stdout 缓冲，确保实时输出
let monitor = TrackpadHIDMonitor()
monitor.start()
print("[INFO] 运行中，手指在触控板上滑动可观察输出。Ctrl+C 退出。")
CFRunLoopRun()
