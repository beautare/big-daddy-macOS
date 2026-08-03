import XCTest
@testable import BigDaddy

final class LocalizationTests: XCTestCase {
    func testUsesSimplifiedChineseForSimplifiedChineseSystemLanguages() {
        XCTAssertEqual(Localization.string(zh: "绑定", en: "Bind", preferredLanguage: "zh-Hans"), "绑定")
        XCTAssertEqual(Localization.string(zh: "绑定", en: "Bind", preferredLanguage: "zh-CN"), "绑定")
    }

    func testUsesTraditionalChineseForTaiwanSystemLanguages() {
        XCTAssertEqual(Localization.string(zh: "绑定记录", en: "Binding records", preferredLanguage: "zh-Hant"), "綁定記錄")
        XCTAssertEqual(Localization.string(zh: "绑定记录", en: "Binding records", preferredLanguage: "zh-TW"), "綁定記錄")
    }

    func testUsesTraditionalChineseForHongKongSystemLanguages() {
        XCTAssertEqual(Localization.string(zh: "绑定记录", en: "Binding records", preferredLanguage: "zh-Hant-HK"), "綁定記錄")
        XCTAssertEqual(Localization.string(zh: "绑定记录", en: "Binding records", preferredLanguage: "zh-HK"), "綁定記錄")
    }

    func testUsesEnglishForNonChineseSystemLanguages() {
        XCTAssertEqual(Localization.string(zh: "绑定", en: "Bind", preferredLanguage: "en-US"), "Bind")
        XCTAssertEqual(Localization.string(zh: "绑定", en: "Bind", preferredLanguage: "ja-JP"), "Bind")
        XCTAssertEqual(Localization.string(zh: "绑定", en: "Bind", preferredLanguage: nil), "Bind")
    }
}
