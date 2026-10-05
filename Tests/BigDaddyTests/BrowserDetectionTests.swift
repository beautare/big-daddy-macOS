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
}
