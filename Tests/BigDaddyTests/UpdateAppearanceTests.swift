import XCTest
import AppKit
import Sparkle
@testable import BigDaddy

@MainActor
final class UpdateAppearanceTests: XCTestCase {
    func testManualUpdateAlertShowsVersionTransitionBeforeAndAfterDownload() throws {
        for ready in [false, true] {
            let alert = UpdateUserDriver.makeUpdateAlert(currentVersion: "0.11.0", newVersion: "0.12.0", ready: ready)
            let content = try XCTUnwrap(alert.accessoryView as? NSStackView)
            let field = try XCTUnwrap(content.arrangedSubviews.first as? NSTextField)
            let title = field.attributedStringValue
            XCTAssertTrue(title.string.contains("0.11.0 → 0.12.0"))
            let targetRange = (title.string as NSString).range(of: "0.12.0")
            let font = try XCTUnwrap(title.attribute(.font, at: targetRange.location, effectiveRange: nil) as? NSFont)
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
            XCTAssertEqual(title.string.contains(Localization.string(zh: "待安装", en: "Ready")), ready)
            XCTAssertGreaterThanOrEqual(content.frame.width, field.fittingSize.width)
        }
    }

    func testManualUpdateChoicesReachSparkleOnce() throws {
        _ = NSApplication.shared
        for choice in [SPUUserUpdateChoice.install, .dismiss, .skip] {
            let driver = UpdateUserDriver(hostBundle: .main, delegate: nil)
            var replies: [SPUUserUpdateChoice] = []
            driver.showUpdateFound(with: try updateItem(), state: try updateState(.notDownloaded)) { replies.append($0) }
            let window = try XCTUnwrap(NSApp.windows.first { $0.delegate === driver })
            let button = try XCTUnwrap(descendants(of: try XCTUnwrap(window.contentView))
                .compactMap { $0 as? NSButton }.first { $0.tag == choice.rawValue })
            button.performClick(nil)
            XCTAssertEqual(replies, [choice])
            XCTAssertFalse(window.isVisible)
            driver.dismissUpdateInstallation()
            XCTAssertEqual(replies, [choice])
        }
    }

    func testReadyToInstallRetainsTargetVersionAndDeliversInstallChoice() throws {
        _ = NSApplication.shared
        let driver = UpdateUserDriver(hostBundle: .main, delegate: nil)
        driver.showUpdateFound(with: try updateItem(), state: try updateState(.downloaded)) { _ in }
        let firstWindow = try XCTUnwrap(NSApp.windows.first { $0.delegate === driver })
        let install = try XCTUnwrap(descendants(of: try XCTUnwrap(firstWindow.contentView))
            .compactMap { $0 as? NSButton }.first { $0.tag == SPUUserUpdateChoice.install.rawValue })
        install.performClick(nil)
        var replies: [SPUUserUpdateChoice] = []
        driver.showReady(toInstallAndRelaunch: { replies.append($0) })
        let window = try XCTUnwrap(NSApp.windows.first { $0.delegate === driver })
        let views = descendants(of: try XCTUnwrap(window.contentView))
        XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains {
            $0.stringValue.contains("\(AppVersion.current) → 0.12.0")
        })
        let button = try XCTUnwrap(views.compactMap { $0 as? NSButton }
            .first { $0.tag == SPUUserUpdateChoice.install.rawValue })
        button.performClick(nil)
        XCTAssertEqual(replies, [.install])
    }

    func testClosingAndAbortingManualUpdateHaveDifferentReplies() throws {
        _ = NSApplication.shared
        let driver = UpdateUserDriver(hostBundle: .main, delegate: nil)
        var replies: [SPUUserUpdateChoice] = []
        driver.showUpdateFound(with: try updateItem(), state: try updateState(.notDownloaded)) { replies.append($0) }
        let window = try XCTUnwrap(NSApp.windows.first { $0.delegate === driver })
        window.close()
        XCTAssertEqual(replies, [.dismiss])
        replies.removeAll()
        driver.showUpdateFound(with: try updateItem(), state: try updateState(.notDownloaded)) { replies.append($0) }
        driver.dismissUpdateInstallation()
        XCTAssertTrue(replies.isEmpty)
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func updateItem() throws -> SUAppcastItem {
        try XCTUnwrap(SUAppcastItem(dictionary: [
            "sparkle:version": "12000", "sparkle:shortVersionString": "0.12.0",
            "enclosure": ["url": "https://example.com/BigDaddy.dmg"]
        ]))
    }

    private func updateState(_ stage: SPUUserUpdateStage) throws -> SPUUserUpdateState {
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        encoder.encode(stage.rawValue, forKey: "SPUUserUpdateStateStage")
        encoder.encode(true, forKey: "SPUUserUpdateStateUserInitiated")
        encoder.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: encoder.encodedData)
        defer { decoder.finishDecoding() }
        return try XCTUnwrap(SPUUserUpdateState(coder: decoder))
    }

    func testMenuUpdateAttributedTitleIncludesVersionsAndBoldsTargetVersion() {
        let current = "0.11.0"
        let target = "0.12.0"
        let attr = AppDelegate.makeMenuUpdateAttributedTitle(currentVersion: current, newVersion: target)
        let plain = attr.string

        XCTAssertTrue(plain.contains(current))
        XCTAssertTrue(plain.contains(target))
        XCTAssertTrue(plain.contains("→"))
        XCTAssertFalse(plain.contains("  "), "标题不应包含连续双空格: \(plain)")

        let targetRange = (plain as NSString).range(of: target)
        XCTAssertNotEqual(targetRange.location, NSNotFound)

        var effectiveRange = NSRange(location: 0, length: 0)
        let targetFont = attr.attribute(.font, at: targetRange.location, effectiveRange: &effectiveRange) as? NSFont
        XCTAssertNotNil(targetFont)
        let isBold = targetFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
        XCTAssertTrue(isBold, "新版本号应具有粗体特性")

        // 验证前缀不是粗体
        let prefixFont = attr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let prefixIsBold = prefixFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
        XCTAssertFalse(prefixIsBold, "前缀文本不应为粗体")
    }

    func testVersionTransitionAttributedStringIncludesVersionsAndBoldsTargetVersion() {
        let current = "0.11.0"
        let target = "0.12.0"
        let attr = AppDelegate.makeVersionTransitionAttributedString(currentVersion: current, newVersion: target)
        let plain = attr.string

        XCTAssertTrue(plain.contains(current))
        XCTAssertTrue(plain.contains(target))
        XCTAssertTrue(plain.contains("→"))
        XCTAssertFalse(plain.contains("  "), "版本转换说明不应包含连续双空格: \(plain)")

        let targetRange = (plain as NSString).range(of: target)
        XCTAssertNotEqual(targetRange.location, NSNotFound)

        let targetFont = attr.attribute(.font, at: targetRange.location, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(targetFont)
        let isBold = targetFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
        XCTAssertTrue(isBold, "目标版本号应为粗体")

        let targetColor = attr.attribute(.foregroundColor, at: targetRange.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(targetColor, NSColor.labelColor)

        // 验证旧版本为 secondaryLabelColor
        let currentColor = attr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(currentColor, NSColor.secondaryLabelColor)
    }

    func testInstallButtonAttributedTitleIncludesVersionsAndBoldsTargetVersion() {
        let current = "0.11.0"
        let target = "0.12.0"
        let attr = AppDelegate.makeInstallButtonAttributedTitle(currentVersion: current, newVersion: target)
        let plain = attr.string

        XCTAssertTrue(plain.contains(current))
        XCTAssertTrue(plain.contains(target))
        XCTAssertFalse(plain.contains("  "), "按钮标题不应包含连续双空格: \(plain)")

        let targetRange = (plain as NSString).range(of: target)
        XCTAssertNotEqual(targetRange.location, NSNotFound)

        let targetFont = attr.attribute(.font, at: targetRange.location, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(targetFont)
        let isBold = targetFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
        XCTAssertTrue(isBold, "按钮中目标版本号应为粗体")

        // 全文应为白色字体
        let targetColor = attr.attribute(.foregroundColor, at: targetRange.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(targetColor, NSColor.white)
        let prefixColor = attr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(prefixColor, NSColor.white)
    }
}
