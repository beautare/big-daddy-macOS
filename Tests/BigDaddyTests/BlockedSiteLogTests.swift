import XCTest
@testable import BigDaddy

final class BlockedSiteLogTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// 与 dashboard 的 blockedSites.test.mjs、iPhone 的 BlockedSitesTests 同一组用例：三端的主域名算法必须一致
    func testSiteOfMatchesDashboardAndIPhone() {
        XCTAssertEqual(DomainName.site(of: "cdn.static.xueersi.com"), "xueersi.com")
        XCTAssertEqual(DomainName.site(of: "www.smartedu.cn"), "smartedu.cn")
        XCTAssertEqual(DomainName.site(of: "basic.smartedu.com.cn"), "smartedu.com.cn")
        XCTAssertEqual(DomainName.site(of: "alice.github.io"), "alice.github.io")
        XCTAssertEqual(DomainName.site(of: "192.168.1.10"), "192.168.1.10")
        XCTAssertEqual(DomainName.site(of: "localhost"), "localhost")
    }

    func testAddressesOfOneSiteShareOneRowNewestFirstCappedAtFive() {
        var log = BlockedSiteLog()
        for (offset, host) in ["a", "b", "c", "d", "e", "f"].enumerated() {
            log.record("\(host).kastatic.org", at: start.addingTimeInterval(Double(offset)))
        }
        log.record("B.kastatic.org.", at: start.addingTimeInterval(10))

        XCTAssertEqual(log.requests.count, 1)
        XCTAssertEqual(log.requests[0].domain, "kastatic.org")
        XCTAssertEqual(log.requests[0].hosts, ["b.kastatic.org", "f.kastatic.org", "e.kastatic.org", "d.kastatic.org", "c.kastatic.org"])
    }

    /// 一个网页一次加载会挡下好多连接，只算一次尝试；隔了一分钟再挡才算第二次
    func testBlocksWithinAMinuteCountAsOneAttempt() {
        var log = BlockedSiteLog()
        for second in stride(from: 0, to: 120, by: 10) {
            log.record("www.youtube.com", at: start.addingTimeInterval(Double(second)))
        }
        XCTAssertEqual(log.requests[0].count, 2)
        XCTAssertEqual(log.requests[0].lastBlockedAt, start.addingTimeInterval(110))
    }

    func testKeepsTheFiftyMostRecentSitesAndForgetsOnesOlderThanAWeek() {
        var log = BlockedSiteLog()
        for index in 0..<60 {
            log.record("site\(index).com", at: start.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(log.requests.count, 50)
        XCTAssertEqual(log.requests.first?.domain, "site59.com")
        XCTAssertFalse(log.requests.contains { $0.domain == "site9.com" })

        log.record("later.com", at: start.addingTimeInterval(BlockedSiteLog.retention + 30))
        XCTAssertEqual(log.requests.map(\.domain).first, "later.com")
        XCTAssertFalse(log.requests.contains { $0.domain == "site10.com" })
    }

    /// 家长处理过的网址在下一次策略到达时让出名额；一个网站下全处理完就整条移除
    func testPruneDropsAddressesTheParentAlreadyDecided() {
        var log = BlockedSiteLog()
        log.record("www.x.com", at: start)
        log.record("cdn.x.com", at: start.addingTimeInterval(1))
        log.record("www.y.com", at: start.addingTimeInterval(2))

        log.prune(keeping: { $0 != "www.x.com" && !$0.hasSuffix("y.com") }, now: start.addingTimeInterval(3))

        XCTAssertEqual(log.requests.map(\.domain), ["x.com"])
        XCTAssertEqual(log.requests[0].hosts, ["cdn.x.com"])
    }

    /// 升级空窗里旧版扩展的回执没有 hosts，新版主程序照样要能解出来
    func testRequestFromOldExtensionWithoutHostsStillDecodes() throws {
        let json = #"{"domain":"docs.school.edu","lastBlockedAt":"2026-10-15T08:00:00Z","count":2}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let request = try decoder.decode(WebFilterAccessRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.hosts, [])
        XCTAssertEqual(request.count, 2)
    }
}
