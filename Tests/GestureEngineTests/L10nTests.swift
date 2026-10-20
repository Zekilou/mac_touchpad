import XCTest
@testable import GestureEngine

final class L10nTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        L10n.currentLanguage = .system   // 恢复默认，避免影响其他测试（全局静态状态）
    }

    func testForceChinese() {
        L10n.currentLanguage = .zh
        XCTAssertTrue(L10n.isChinese)
        XCTAssertEqual(L10n.tr("中文文案", "English text"), "中文文案")
    }

    func testForceEnglish() {
        L10n.currentLanguage = .en
        XCTAssertFalse(L10n.isChinese)
        XCTAssertEqual(L10n.tr("中文文案", "English text"), "English text")
    }

    func testSystemFollowsPreferredLanguages() {
        L10n.currentLanguage = .system
        let sysChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        XCTAssertEqual(L10n.isChinese, sysChinese)
    }

    func testSwitchBackToSystem() {
        L10n.currentLanguage = .en
        XCTAssertFalse(L10n.isChinese)
        L10n.currentLanguage = .system
        let sysChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        XCTAssertEqual(L10n.isChinese, sysChinese)
    }

    func testAppLanguageCodableRoundTrip() {
        for lang in AppLanguage.allCases {
            let data = try! JSONEncoder().encode(lang)
            let decoded = try! JSONDecoder().decode(AppLanguage.self, from: data)
            XCTAssertEqual(decoded, lang)
        }
    }

    func testAppLanguageDisplayName() {
        XCTAssertEqual(AppLanguage.zh.displayName, "中文")
        XCTAssertEqual(AppLanguage.en.displayName, "English")
    }

    // MARK: - 语言变更通知（菜单栏 / 独立窗口靠它刷新）

    /// 赋值 `currentLanguage` 必须发通知并推进 revision：
    /// 引导窗 / 报告面板不在 AppDelegate 的观察链上，只靠这条通知才会重绘。
    func testAssigningLanguagePostsNotificationAndBumpsRevision() {
        let before = L10n.revision
        let expectation = expectation(forNotification: .l10nLanguageDidChange,
                                      object: nil, handler: nil)
        L10n.currentLanguage = .en
        wait(for: [expectation], timeout: 1)
        XCTAssertGreaterThan(L10n.revision, before,
                             "语言变更应推进 revision（视图据此重算 body）")
    }

    /// 同一语言重复赋值也要发通知：调用方不必各自维护去重逻辑，
    /// 重复重建菜单 / 面板标题的代价可忽略。
    func testReassigningSameLanguageStillPosts() {
        L10n.currentLanguage = .en
        let before = L10n.revision
        let expectation = expectation(forNotification: .l10nLanguageDidChange,
                                      object: nil, handler: nil)
        L10n.currentLanguage = .en
        wait(for: [expectation], timeout: 1)
        XCTAssertGreaterThan(L10n.revision, before)
    }

    /// `isChinese` 必须每次调用求值（而不是启动时快照）——
    /// 这是「切语言后下一次 body 求值即生效」的前提。
    func testIsChineseIsEvaluatedPerCall() {
        L10n.currentLanguage = .en
        XCTAssertFalse(L10n.isChinese)
        L10n.currentLanguage = .zh
        XCTAssertTrue(L10n.isChinese, "切到中文后，同一个进程内必须立刻反映")
    }
}
