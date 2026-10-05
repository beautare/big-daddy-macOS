import XCTest
@testable import BigDaddy

final class AppDisplayNameTests: XCTestCase {
    /// 模拟各 bundle 的 Info.plist 名字，取自真实安装：CodexCLI.app 自己也写着"ChatGPT"，
    /// Cursor 的 "Cursor Helper (Plugin).app" 里写的是 "Electron Helper (Plugin)"。
    private let names: [String: String] = [
        "/Applications/ChatGPT.app": "ChatGPT",
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app": "ChatGPT",
        "/Applications/Cursor.app": "Cursor",
        "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app": "Electron Helper (Plugin)",
        "/Applications/Google Chrome.app": "Google Chrome",
    ]

    private func name(_ path: String?, _ identifier: String = "com.example.tool") -> String {
        BigDaddyClient.displayName(atPath: path, fallback: identifier, bundleName: { self.names[$0] })
    }

    func testTopLevelAppUsesItsOwnName() {
        XCTAssertEqual(name("/Applications/ChatGPT.app"), "ChatGPT")
    }

    /// 嵌套程序用文件名，不用它 Info.plist 里的名字——否则和外层 App 重名
    func testNestedAppIsNamedAfterItsHostAndFileName() {
        XCTAssertEqual(name("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app"), "ChatGPT · CodexCLI")
    }

    func testNestedExecutableIsNamedAfterItsHost() {
        XCTAssertEqual(name("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"), "ChatGPT · codex")
    }

    func testInnerNameAlreadyCarryingHostNameStaysAsIs() {
        XCTAssertEqual(name("/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app"),
                       "Cursor Helper (Plugin)")
        XCTAssertEqual(name("/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app"),
                       "Google Chrome Helper")
    }

    func testFallsBackToLastIdentifierSegmentWithoutAnyBundleName() {
        XCTAssertEqual(name(nil, "com.example.tool"), "tool")
        XCTAssertEqual(name("/usr/local/bin/tool", "com.example.tool"), "tool")
    }
}
