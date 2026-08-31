import Foundation
import Darwin

/// App 转移（App Translocation）与「移入应用程序」引导的可测纯逻辑。
///
/// 根因：从网上下载、带 `com.apple.quarantine` 隔离属性的 .app，macOS 会把它复制到
/// 一个随机只读路径（App Translocation）下运行，每启动一次路径就变一次。TCC 权限
/// （输入监控 / 辅助功能）按「签名身份 + 路径」绑定，授权记录在某个随机路径上，
/// 下次启动路径已变 → 系统把它当成另一个 app → 显示「未授予」。
///
/// 官方/生态推荐做法：把 app 放到稳定位置（/Applications）并去掉隔离属性。
/// 本文件只包含可测的纯计算；AppKit/进程操作（拷贝、去隔离、重启）在 AppDelegate。
public enum AppTranslocation {

    /// 是否运行在 macOS 的 App Translocation 随机只读路径下。
    ///
    /// 通过路径是否含 `/AppTranslocation/` 判断（这是转移副本的固定目录特征，
    /// 目录名带随机 UUID，但目录段不变）。
    public static func isRunningTranslocated(bundlePath: String) -> Bool {
        bundlePath.contains("/AppTranslocation/")
    }

    /// 是否建议弹出「移到应用程序」引导。
    ///
    /// 规则：以 `.app` 打包方式运行、且不在 `/Applications` 目录下。这同时覆盖
    /// 转移路径（必然不在 /Applications）与「直接双击下载目录里的 .app」两种情况。
    /// 用 `Bundle.main.bundlePath` 判断；`swift run` 的裸二进制不满足 `.app` 后缀，
    /// 因此开发调试不会误触发。已位于 /Applications 的 .app 不再提示。
    public static func shouldOfferMoveToApplications(bundlePath: String) -> Bool {
        bundlePath.hasSuffix(".app") && !bundlePath.hasPrefix("/Applications/")
    }

    /// 计算「移入应用程序」后的目标路径：`/Applications/<app 名>`。
    public static func applicationsDestination(forSource sourceURL: URL) -> URL {
        URL(fileURLWithPath: "/Applications")
            .appendingPathComponent(sourceURL.lastPathComponent)
    }

    // MARK: - 自愈：自动除转移（仿 Mac Mouse Fix 的 AppTranslocationManager.m）

    /// 判断当前 bundle 是否处于 App Translocation 转移路径，并返回其「原始路径」。
    ///
    /// 直接使用私有 API：`dlopen` 加载 Security 框架后 `dlsym` 取
    /// `SecTranslocateIsTranslocatedURL` / `SecTranslocateCreateOriginalPathForURL`。
    /// 这两个符号未公开、依赖运行时解析；任何一步缺失/失败都回退 `nil`——
    /// 调用方再退回「建议移入」引导，不会造成回归（最多退化为手动处理）。
    public static func originalURLWhenTranslocated(bundleURL: URL) -> URL? {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else {
            return nil
        }
        defer { dlclose(handle) }

        // SecTranslocateIsTranslocatedURL(CFURLRef, bool *, CFErrorRef **) -> Boolean
        typealias IsTranslocatedFn = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<CFError?>?) -> UInt8
        guard let isSymAddr = dlsym(handle, "SecTranslocateIsTranslocatedURL") else { return nil }
        let isTranslocatedFn = unsafeBitCast(isSymAddr, to: IsTranslocatedFn.self)

        var isTranslocated = false
        _ = isTranslocatedFn(bundleURL as CFURL, &isTranslocated, nil)
        guard isTranslocated else { return nil }

        // SecTranslocateCreateOriginalPathForURL(CFURLRef, CFErrorRef **) -> CFURLRef
        typealias OriginalPathFn = @convention(c) (CFURL, UnsafeMutablePointer<CFError?>?) -> Unmanaged<CFURL>?
        guard let origAddr = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let originalPathFn = unsafeBitCast(origAddr, to: OriginalPathFn.self)

        guard let unmanaged = originalPathFn(bundleURL as CFURL, nil) else { return nil }
        let originalCF = unmanaged.takeRetainedValue()
        return (originalCF as NSURL) as URL
    }
}
