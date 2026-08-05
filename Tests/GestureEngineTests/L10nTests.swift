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
}
