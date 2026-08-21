import XCTest
@testable import BigDaddy

/// 补发队列的内存镜像（PendingQueue.cache）的行为约束。
///
/// 这套测试存在的理由：镜像是一次纯性能改造引入的（原先每个入口都整份读盘 + AES-GCM
/// 解密 + 每行 JSON/ISO8601 解析，补发排空因此是 O(n²)），而它护着的是**断网期间攒下的
/// 记录**——镜像和磁盘一旦分叉，代价是家长永远看不到的一段时间线，或者同一批记录被重复
/// 补报。所以这里的每条断言都跨一次 resetForTesting()（= 模拟进程重启后重新读盘），
/// 光测内存里自洽是不够的。
final class PendingQueueTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingQueueTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        PendingQueue.testFileURLOverride = directory.appendingPathComponent("pending-heartbeats.jsonl")
        PendingQueue.resetForTesting()
    }

    override func tearDownWithError() throws {
        PendingQueue.testFileURLOverride = nil
        PendingQueue.resetForTesting()
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testEnqueueThenDepthCountsEntries() {
        XCTAssertEqual(PendingQueue.depth, 0)

        PendingQueue.enqueue(body(event: "A"))
        PendingQueue.enqueue(body(event: "B"))

        XCTAssertEqual(PendingQueue.depth, 2)
    }

    /// 镜像必须是磁盘的忠实副本：重启（resetForTesting）之后条数和内容都不能变。
    func testEntriesSurviveReload() {
        PendingQueue.enqueue(body(event: "A"))
        PendingQueue.enqueue(body(event: "B"))

        PendingQueue.resetForTesting()

        XCTAssertEqual(PendingQueue.depth, 2)
        XCTAssertEqual(eventNames(PendingQueue.peekOldest(limit: 10)), ["A", "B"])
    }

    /// 补发的顺序契约：peekOldest 给最老的，removeFirst 摘掉的必须正是刚补发成功的那条。
    func testPeekOldestReturnsOldestAndRemoveFirstDropsIt() {
        PendingQueue.enqueue(body(event: "A"))
        PendingQueue.enqueue(body(event: "B"))
        PendingQueue.enqueue(body(event: "C"))

        XCTAssertEqual(eventNames(PendingQueue.peekOldest(limit: 1)), ["A"])

        PendingQueue.removeFirst(1)

        XCTAssertEqual(eventNames(PendingQueue.peekOldest(limit: 1)), ["B"])
        XCTAssertEqual(PendingQueue.depth, 2)
    }

    /// 摘除必须**真的落盘**，不能只在内存里消失——否则崩溃重启后这批记录会被重复补报。
    /// 这是内存镜像最危险的失败模式，单独钉一条。
    func testRemoveFirstIsPersisted() {
        PendingQueue.enqueue(body(event: "A"))
        PendingQueue.enqueue(body(event: "B"))
        PendingQueue.removeFirst(1)

        PendingQueue.resetForTesting()

        XCTAssertEqual(PendingQueue.depth, 1)
        XCTAssertEqual(eventNames(PendingQueue.peekOldest(limit: 10)), ["B"])
    }

    /// 超出 24 小时保留窗口的条目按龄丢弃，且判龄依据是 body 里的 reportedAt
    /// （镜像在加载时把它解析好，此后裁剪只比较 Date）。
    func testEntriesOlderThanRetentionWindowArePruned() {
        PendingQueue.enqueue(body(event: "OLD", reportedAt: Date(timeIntervalSinceNow: -25 * 60 * 60)))
        PendingQueue.enqueue(body(event: "FRESH"))

        XCTAssertEqual(eventNames(PendingQueue.peekOldest(limit: 10)), ["FRESH"])

        PendingQueue.resetForTesting()

        XCTAssertEqual(eventNames(PendingQueue.peekOldest(limit: 10)), ["FRESH"],
                       "重新读盘之后裁剪结果必须一致，不能因为镜像重建就把过期条目放回来")
    }

    /// 解析不出 reportedAt 的条目**永不过期**：宁可多补一条，不要静默丢。
    func testEntryWithoutParsableTimestampIsKept() {
        PendingQueue.enqueue(["eventType": "NO_TIMESTAMP"])

        XCTAssertEqual(PendingQueue.depth, 1)

        PendingQueue.resetForTesting()

        XCTAssertEqual(PendingQueue.depth, 1)
    }

    /// 回归测试：磁盘持续写不进去（磁盘满/权限问题）时，removeFirst 必须如实报告失败，
    /// 且磁盘上的队首**没有**被真的摘掉。
    ///
    /// 这条钉的是一个真实发生过的 bug：removeFirst 曾经不管落盘成不成功都直接返回，
    /// drainPendingQueue 因此会把这条"其实还在磁盘上"的记录当成新的队首重新读到、
    /// 再发一次——服务端确认成功、摘除又落盘失败、再读到同一条——每隔几秒重复上报
    /// 同一条记录，没有自然终止条件。用只读目录模拟持续写失败：只要 removeFirst
    /// 老实报告 false，调用方（drainPendingQueue）就会跟网络失败一视同仁地退避，
    /// 不会陷入这个循环。
    func testRemoveFirstReportsFailureAndLeavesDiskUntouchedWhenPersistFails() throws {
        PendingQueue.enqueue(body(event: "A"))
        PendingQueue.enqueue(body(event: "B"))

        // 去掉目录的写权限：atomic write 需要在同目录建临时文件再 rename，
        // 目录只读时这一步必然失败——不依赖某个具体系统调用报错方式，是最贴近
        // 真实"磁盘满/权限被收回"场景的模拟方式。
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let removed = PendingQueue.removeFirst(1)
        // 无论测试本身通过与否，都要把权限改回来，否则 tearDown 删不掉这个目录。
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        XCTAssertFalse(removed, "落盘失败时 removeFirst 必须报告 false，不能假装摘除已经生效")

        // 重新读盘（模拟下一次访问）：A 必须还在队首，没有被真的摘掉。
        PendingQueue.resetForTesting()
        XCTAssertEqual(eventNames(PendingQueue.peekOldest(limit: 10)), ["A", "B"],
                       "磁盘写失败时，磁盘上的内容不该发生变化")
    }

    private func body(event: String, reportedAt: Date = Date()) -> [String: Any] {
        [
            "eventType": event,
            "reportedAt": BigDaddyDateFormatter.iso8601.string(from: reportedAt)
        ]
    }

    private func eventNames(_ bodies: [[String: Any]]) -> [String] {
        bodies.compactMap { $0["eventType"] as? String }
    }
}
