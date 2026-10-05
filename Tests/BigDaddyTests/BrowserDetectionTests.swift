import XCTest
@testable import BigDaddy

final class BrowserDetectionTests: XCTestCase {
    private let webSchemes: [String: Any] = ["CFBundleURLTypes": [["CFBundleURLSchemes": ["http", "https"]]]]

    private func info(_ documentType: [String: Any]?, schemes: [String] = ["http", "https"]) -> [String: Any] {
        var info: [String: Any] = ["CFBundleURLTypes": [["CFBundleURLSchemes": schemes]]]
        if let documentType { info["CFBundleDocumentTypes"] = [documentType] }
        return info
    }

    func testChromiumStyleHTMLContentTypeIsBrowser() {
        XCTAssertTrue(BigDaddyClient.isWebBrowser(infoDictionary: info(["LSItemContentTypes": ["public.html"]])))
    }

    func testSafariStyleExtensionOrMIMEIsBrowser() {
        XCTAssertTrue(BigDaddyClient.isWebBrowser(infoDictionary: info(["CFBundleTypeExtensions": ["HTML", "htm"]])))
        XCTAssertTrue(BigDaddyClient.isWebBrowser(infoDictionary: info(["CFBundleTypeMIMETypes": ["text/html"]])))
    }

    /// ChatGPT 这类软件登记 http/https 只是为了接住网页跳转，不能因此被当成浏览器
    func testWebLinkHandlerWithoutHTMLIsNotBrowser() {
        XCTAssertFalse(BigDaddyClient.isWebBrowser(infoDictionary: webSchemes))
        XCTAssertFalse(BigDaddyClient.isWebBrowser(infoDictionary: info(["LSItemContentTypes": ["public.plain-text"]])))
    }

    func testHTMLViewerWithoutBothWebSchemesIsNotBrowser() {
        XCTAssertFalse(BigDaddyClient.isWebBrowser(infoDictionary: info(["LSItemContentTypes": ["public.html"]], schemes: ["https"])))
        XCTAssertFalse(BigDaddyClient.isWebBrowser(infoDictionary: ["CFBundleDocumentTypes": [["LSItemContentTypes": ["public.html"]]]]))
        XCTAssertFalse(BigDaddyClient.isWebBrowser(infoDictionary: nil))
    }

    /// Chrome 系浏览器的网络请求由辅助进程发出，辅助进程自己不声明能打开网页，
    /// 必须按它所在的浏览器判定，否则设成随时可以联网就绕过了网站规则
    func testHelperNestedInBrowserIsBrowser() {
        let plists: [String: [String: Any]] = [
            "/Applications/Vivaldi.app": info(["LSItemContentTypes": ["public.html"]]),
            "/Applications/Vivaldi.app/Contents/Frameworks/Vivaldi Helper.app": [:],
            "/Applications/ChatGPT.app": webSchemes,
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app": [:],
        ]
        func isBrowser(_ path: String) -> Bool {
            BigDaddyClient.isWebBrowser(atPath: path, infoDictionary: { plists[$0] })
        }
        XCTAssertTrue(isBrowser("/Applications/Vivaldi.app"))
        XCTAssertTrue(isBrowser("/Applications/Vivaldi.app/Contents/Frameworks/Vivaldi Helper.app"))
        XCTAssertFalse(isBrowser("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app"))
        XCTAssertFalse(BigDaddyClient.isWebBrowser(atPath: nil))
    }

    func testHostAppPathIsOutermostAppOnly() {
        XCTAssertEqual(BigDaddyClient.hostAppPath(of: "/Applications/Vivaldi.app/Contents/Frameworks/Vivaldi Helper.app"),
                       "/Applications/Vivaldi.app")
        XCTAssertNil(BigDaddyClient.hostAppPath(of: "/Applications/Vivaldi.app"))
        XCTAssertNil(BigDaddyClient.hostAppPath(of: "/usr/local/bin/tool"))
    }
}
