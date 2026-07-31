import Foundation
import CoreAudio
import AppKit
import IOKit
import IOKit.graphics

/// 系统控制：音量 + 亮度
public enum SystemControl {

    // MARK: - 音量读取

    public static func getVolume() -> Float {
        var devID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) == noErr else { return 0 }
        var vol: Float = 0
        size = UInt32(MemoryLayout<Float>.size)
        addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, &vol) == noErr else { return 0 }
        return vol
    }

    // MARK: - 亮度读取

    public static func getBrightness() -> Float {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iterator) == kIOReturnSuccess else { return 0 }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var brightness: Float = 0
            let ok = IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &brightness)
            IOObjectRelease(service)
            if ok == kIOReturnSuccess {
                return brightness
            }
            service = IOIteratorNext(iterator)
        }
        return 0
    }

    // MARK: - 媒体键事件（触发系统 HUD + 实际调节）

    /// 发送系统媒体键事件（NX_SYSDEFINED, subtype=8）
    /// 这会让系统自动调节音量/亮度并显示右上角 HUD
    private static func postMediaKey(_ keyType: Int32) {
        // keyDown
        let data1Down = Int((keyType << 16) | Int32(0x0A00))
        let downEvent = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,            // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            data1: data1Down,
            data2: -1
        )
        downEvent?.cgEvent?.post(tap: CGEventTapLocation.cghidEventTap)

        // keyUp
        let data1Up = Int((keyType << 16) | Int32(0x0B00))
        let upEvent = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1Up,
            data2: -1
        )
        upEvent?.cgEvent?.post(tap: CGEventTapLocation.cghidEventTap)
    }

    // NX_KEYTYPE constants (from IOKit/hidsystem/ev_keymap.h)
    // 0 = VOLUME_UP, 1 = VOLUME_DOWN, 2 = BRIGHTNESS_UP, 3 = BRIGHTNESS_DOWN

    public static func volumeUp()    { postMediaKey(0) }
    public static func volumeDown()  { postMediaKey(1) }
    public static func brightnessUp()   { postMediaKey(2) }
    public static func brightnessDown() { postMediaKey(3) }

    // MARK: - 直接 API（精确赋值，无 HUD）

    /// 直接设置系统音量（0~1）
    /// 使用 CoreAudio kAudioDevicePropertyVolumeScalar，支持任意精度
    /// 不会弹出系统 HUD
    @discardableResult
    public static func setVolume(_ value: Float) -> Bool {
        let clamped = max(0.0, min(1.0, value))
        var devID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) == noErr else {
            return false
        }
        var vol = clamped
        size = UInt32(MemoryLayout<Float>.size)
        addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(devID, &addr, 0, nil, size, &vol) == noErr
    }

    /// 直接设置系统亮度（0~1）
    /// 使用 IOKit IODisplaySetFloatParameter，不会弹出 HUD
    /// 取第一个成功写入的 IODisplayConnect（通常是内置屏幕）
    @discardableResult
    public static func setBrightness(_ value: Float) -> Bool {
        let clamped = max(0.0, min(1.0, value))
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return false
        }
        defer { IOObjectRelease(iterator) }
        var success = false
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let err = IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, clamped)
            IOObjectRelease(service)
            if err == kIOReturnSuccess {
                success = true
                // 第一个成功就 break（优先内置屏幕），避免同时改外接
                break
            }
            service = IOIteratorNext(iterator)
        }
        return success
    }

}
