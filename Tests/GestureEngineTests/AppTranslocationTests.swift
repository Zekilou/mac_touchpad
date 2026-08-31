import XCTest
@testable import GestureEngine

/// 权限「打开开关仍显示未授予」的根因回归测试：
/// 从网上下载的 .app 带 quarantine 属性，会被 macOS 复制到随机只读路径（App Translocation）
/// 运行；每启动一次路径就变一次 → TCC 权限按路径+签名绑定，授权无法跨启动保留。
/// 官方/生态推荐：把 app 放到稳定位置（/Applications）并去掉隔离属性。
/// 本文件只测可测的纯逻辑（检测转移 / 是否建议移入 / 目标路径计算）。
final class AppTranslocationTests: XCTestCase {

    // MARK: - isRunningTranslocated

    func testIsRunningTranslocated_detectsAppTranslocationPath() {
        XCTAssertTrue(AppTranslocation.isRunningTranslocated(
            bundlePath: "/private/var/folders/4p/xyz/T/AppTranslocation/B79EDC55/d/TouchpadGestures.app"))
    }

    func testIsRunningTranslocated_normalApplicationsPath_false() {
        XCTAssertFalse(AppTranslocation.isRunningTranslocated(
            bundlePath: "/Applications/TouchpadGestures.app"))
    }

    func testIsRunningTranslocated_downloadsPath_false() {
        XCTAssertFalse(AppTranslocation.isRunningTranslocated(
            bundlePath: "/Users/demo/Downloads/TouchpadGestures.app"))
    }

    // MARK: - shouldOfferMoveToApplications

    func testShouldOfferMove_bundledAppInDownloads_true() {
        XCTAssertTrue(AppTranslocation.shouldOfferMoveToApplications(
            bundlePath: "/Users/demo/Downloads/TouchpadGestures.app"))
    }

    func testShouldOfferMove_bundledAppInApplications_false() {
        XCTAssertFalse(AppTranslocation.shouldOfferMoveToApplications(
            bundlePath: "/Applications/TouchpadGestures.app"))
    }

    func testShouldOfferMove_nonBundleBinary_false() {
        XCTAssertFalse(AppTranslocation.shouldOfferMoveToApplications(
            bundlePath: "/Users/demo/project/.build/debug/TouchpadGestures"))
    }

    // MARK: - applicationsDestination

    func testApplicationsDestination_appendsToApplicationsFolder() {
        let src = URL(fileURLWithPath: "/Users/demo/Downloads/TouchpadGestures.app")
        let dest = AppTranslocation.applicationsDestination(forSource: src)
        XCTAssertEqual(dest.path, "/Applications/TouchpadGestures.app")
    }

    // MARK: - 自愈：自动除转移（私有 API 优雅降级）

    func testOriginalURLWhenTranslocated_nonTranslocatedPath_returnsNil() {
        // 非转移路径（/Applications 下的真实 app）不会被判定为转移 → 返回 nil。
        // 这验证私有 API 缺失/未转移时优雅回退，不抛错、不崩溃。
        let appURL = URL(fileURLWithPath: "/Applications/TouchpadGestures.app")
        XCTAssertNil(AppTranslocation.originalURLWhenTranslocated(bundleURL: appURL))
    }
}
