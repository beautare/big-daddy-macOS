import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio
import CryptoKit
import Darwin
import Foundation
import IOKit.pwr_mgt
import Network
import ScreenCaptureKit
import Security
import ServiceManagement

/// 断网容错：心跳/事件发送失败时，把请求体缓存到本地文件（内存中每行一条 JSON），
/// 绝不缓存截图字节。心跳里包含活动窗口标题、浏览器 URL 等隐私字段，落盘前用
/// AES-GCM 加密（见 PendingQueueCrypto），磁盘上不会出现明文。网络恢复后由
/// BigDaddyClient 的 NWPathMonitor 触发补发，重新签名（HMAC 时间戳必须是发送时刻的
/// 新值，不能复用失败时的旧签名）后清空。
enum PendingQueue {
    /// **仅供单测**：把队列文件挪到临时目录，避免测试踩坏用户真实的补发队列。
    /// 生产代码任何地方都不设置它；设置之后必须调 resetForTesting() 把内存镜像一并清掉，
    /// 否则会拿着上一个文件的镜像去回答新文件的问题。
    static var testFileURLOverride: URL?

    static var queueFileURL: URL {
        if let testFileURLOverride { return testFileURLOverride }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BigDaddy/pending-heartbeats.jsonl")
    }

    /// **仅供单测**：丢掉内存镜像，下次访问重新读盘。也用来模拟"进程重启"——
    /// 这正是验证"镜像和磁盘没有分叉"的唯一手段。
    static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        cache = nil
    }

    /// 解除设备绑定时物理清空本地积压队列与内存镜像，防止残留敏感行为数据泄露
    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache = []
        try? FileManager.default.removeItem(at: queueFileURL)
    }

    /// 队列的保留窗口：**按时长**而不是按条数裁剪。
    ///
    /// 此前是"最多 200 条，超了丢最老的"。200 条在中度使用下只够 30 多分钟——一次晚饭时间
    /// 的断网就开始静默丢数据，而且丢的是最早那批（最该保留的断网起点）。限速补发把排水
    /// 速度控制住了，但水池太小的话再优雅的排水也没有意义，所以这里必须一起改。
    ///
    /// 24 小时覆盖了"周末外出一天""家里宽带故障一晚"这类真实场景；再长的断网（如寒假旅行）
    /// 补回来的价值已经很低，而且补发本身要占用当下的额度。
    private static let maxAge: TimeInterval = 24 * 60 * 60
    /// 文件体积的硬上限，防止极端高频事件在 24 小时里堆出一个巨大的文件。
    /// 按"1 分钟心跳 + 密集应用切换"估算，正常一天远到不了这个量级。
    private static let maxEntries = 5000

    /// 队列文件的串行化锁：补发循环在后台任务里读写，实时心跳失败时会从别的线程追加，
    /// 两者都是"整份读出→改→整份写回"，不加锁会互相覆盖（丢事件或写出坏行）。
    /// 内存镜像 cache 同样只在这把锁里读写。
    private static let lock = NSLock()

    /// 一条队列条目：原始 JSON 行，外加**加载时解析一次**的 reportedAt。
    ///
    /// 把 reportedAt 跟着行一起存下来，是为了让按龄裁剪退化成纯 Date 比较。原先每次
    /// 裁剪都要把每一行重新 JSONSerialization 解析一遍、再 ISO8601 解析一次时间戳，
    /// 而裁剪在每个入口（depth/peek/remove/enqueue）都要跑一次。
    private struct Entry {
        /// 进程内唯一标识，只活在内存镜像里、不落盘。补发确认时按它摘除，而不是按"队首"位置：
        /// 请求在途期间队首可能被按龄裁剪或被 maxEntries 挤掉，位置早就不是发出去的那一条了。
        let id: UInt64
        let line: String
        /// 解析不出来时为 nil ⇒ 这条永不过期。宁可多补一条，不要静默丢。
        let reportedAt: Date?
    }

    /// 调用方必须已持有 lock。
    private static var nextEntryID: UInt64 = 0
    private static func makeEntry(_ line: String) -> Entry {
        nextEntryID += 1
        return Entry(id: nextEntryID, line: line, reportedAt: reportedAt(of: line))
    }

    /// peekOldestEntry 交给补发循环的句柄：确认送达后拿 id 调 remove(id:)。
    struct PeekedEntry {
        let id: UInt64
        let body: [String: Any]
    }

    /// 队列的内存镜像；nil = 还没从磁盘加载过。**本进程是这个文件的唯一写者**
    /// （多开会被 shouldExitAsDuplicate 挡掉），所以镜像可以当作权威，不必回头校验磁盘。
    ///
    /// 这是本类型性能上唯一要紧的地方。补发循环每处理一条就要 peekOldestEntry + remove
    /// 各一次，而它们原先各自都是"整文件读 + AES-GCM 解密 + 每行 JSON 解析 + 每行
    /// ISO8601 解析"——队列放满 5000 条时，排空一次就是 5000 轮 × 约一万次解析。加上
    /// 心跳里还要读两次 depth，而心跳由每次前台切换应用触发（见 startActivitySwitchTracking），
    /// 这个 O(n²) 是这个 App 最容易被真实用户撞上的性能坑。
    private static var cache: [Entry]?

    static func enqueue(_ body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let line = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        var entries = currentEntries()
        entries.append(makeEntry(line))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        persist(entries)
    }

    /// 当前积压条数。随心跳上报给后端（metadata.pendingQueueDepth），家长端据此显示
    /// "正在补传 N 条"——补发要花几十分钟，没有这个数字的话家长只会看到时间线在自己
    /// 眼前不断长出新内容，读起来像系统不可靠。
    static var depth: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentEntries().count
    }

    /// 读取**最老的** limit 条但不移除（只读视图，补发循环用 peekOldestEntry）。
    ///
    /// 不用"全取出→失败再塞回"的老写法：那样一旦补发中途失败（限流、网络再断），
    /// 塞回去的顺序和原始顺序就不一致了，而家长端的连续折叠依赖时间有序。
    /// 保持"读→确认成功→再摘除"的顺序，失败时队列原样不动。
    static func peekOldest(limit: Int) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return currentEntries().prefix(limit).compactMap { decode($0.line) }
    }

    /// 最老的一条（连同它的 id）但不移除。补发成功后由调用方拿 id 调 remove(id:)。
    static func peekOldestEntry() -> PeekedEntry? {
        lock.lock()
        defer { lock.unlock() }
        for entry in currentEntries() {
            if let body = decode(entry.line) { return PeekedEntry(id: entry.id, body: body) }
        }
        return nil
    }

    /// 摘掉 peekOldestEntry 交出去的那一条（已确认送达，或被服务端明确拒收）。返回是否真的落盘成功。
    ///
    /// **必须按 id 摘，不能按位置摘**：请求在途的几秒里，这条可能刚好跨过 24 小时保留期
    /// 被 currentEntries() 裁掉，或被 enqueue 的 maxEntries 上限挤掉。此前的 removeFirst(1)
    /// 会在裁剪之后再删"新的队首"——一条还没发出去的记录就这样静默丢了。
    /// 这条已经不在队列里时什么也不用做，直接返回 true。
    ///
    /// 仍然是**每摘一条落盘一次**，没有攒批：补发的语义是"服务端已经确认收下了这一条"，
    /// 把落盘推迟就等于在崩溃窗口里留下重复上报的机会。
    ///
    /// 返回值存在的理由：如果这次落盘失败（磁盘满/权限问题，见 persist 的注释），
    /// 磁盘上的这条其实**没有**被摘掉，下次读盘还会读到。调用方（drainPendingQueue）
    /// 靠这个返回值判断"摘除到底有没有真的生效"，失败时必须停手，否则会把已经发送
    /// 成功的同一条记录每隔几秒重发一次，没有自然终止条件。
    @discardableResult
    static func remove(id: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var entries = currentEntries()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return true }
        entries.remove(at: index)
        return persist(entries)
    }

    private static func decode(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// 一行的 reportedAt。只在这条行**进入内存镜像**的那一刻调用一次——要么是
    /// enqueue 新追加的，要么是 loadFromDisk 首次读盘时的。
    ///
    /// 按 body 里的 reportedAt 判龄，而不是文件写入时间：那是事件真正发生的时刻，也正是
    /// 补发上去之后家长在时间线上看到的时刻；用文件时间无法区分同一个文件里新旧混杂的条目。
    private static func reportedAt(of line: String) -> Date? {
        guard let obj = decode(line),
              let stamp = obj["reportedAt"] as? String else { return nil }
        return BigDaddyDateFormatter.iso8601.date(from: stamp)
    }

    /// 调用方必须已持有 lock。返回**已按保留窗口裁剪过**的当前队列，并把裁剪结果留在镜像里。
    /// 裁剪只比较 Date，不碰磁盘也不解析任何 JSON。
    ///
    /// 跟原来一样，裁剪只发生在内存里：磁盘上的过期条目要等下一次 persist() 才真正消失。
    private static func currentEntries() -> [Entry] {
        let cutoff = Date().addingTimeInterval(-maxAge)
        let pruned = (cache ?? loadFromDisk()).filter { entry in
            guard let reportedAt = entry.reportedAt else { return true }
            return reportedAt > cutoff
        }
        cache = pruned
        return pruned
    }

    /// 调用方必须已持有 lock。整份读盘并把每行的 reportedAt 解析出来——**每行只在这里
    /// 解析一次**，此后都靠内存镜像。进程生命周期内正常只走一次。
    private static func loadFromDisk() -> [Entry] {
        readLines().map(makeEntry)
    }

    /// 调用方必须已持有 lock。落盘成功才更新镜像。返回是否真的落盘成功——
    /// remove(id:) 靠它判断"摘除有没有真的生效"，见该函数的注释。
    @discardableResult
    private static func persist(_ entries: [Entry]) -> Bool {
        guard write(entries.map(\.line)) else {
            // 落盘失败（磁盘满、权限、密钥读不出来）。write 是原子写，失败时磁盘上仍是上一次
            // 成功落盘的内容，而镜像此刻也正是那份（本次改动只在局部变量 entries 里，没有
            // 赋给 cache）——所以**保留镜像不动**，它依然忠实于磁盘。
            //
            // 不能像以前那样置 nil 重新读盘：重新读盘会给每条分配新 id，补发循环手里那条
            // 在途条目的旧 id 就对不上了，remove(id:) 找不到它会当作"已经不在"返回成功，
            // 结果这条留在队首被重复补发。
            return false
        }
        cache = entries
        return true
    }

    /// 先按新的 AES-GCM 加密格式解密；如果失败（多半是磁盘上还留着升级前的旧版本
    /// 明文 JSONL 文件），一次性按明文兼容读取。读到的内容会在下一次 write()（无论是
    /// enqueue 追加新条目，还是补发摘除队首）时按新格式重新落盘，之后就不再需要兼容分支。
    private static func readLines() -> [String] {
        guard let data = try? Data(contentsOf: queueFileURL) else { return [] }
        if let text = decrypt(data) {
            return text.split(separator: "\n").map(String.init)
        }
        if let text = String(data: data, encoding: .utf8) {
            NSLog("BigDaddy: pending queue file is legacy plaintext format, will re-encrypt on next write")
            return text.split(separator: "\n").map(String.init)
        }
        return []
    }

    /// 落盘。返回是否确实写成功——调用方（persist）靠它决定内存镜像还能不能信。
    private static func write(_ lines: [String]) -> Bool {
        let url = queueFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n")
        guard let sealed = encrypt(text) else { return false }
        do {
            try sealed.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("BigDaddy: pending queue write failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func encrypt(_ text: String) -> Data? {
        guard let plaintext = text.data(using: .utf8) else { return nil }
        let key = PendingQueueCrypto.loadOrCreateKey()
        guard let sealedBox = try? AES.GCM.seal(plaintext, using: key) else { return nil }
        return sealedBox.combined
    }

    private static func decrypt(_ data: Data) -> String? {
        let key = PendingQueueCrypto.loadOrCreateKey()
        guard let sealedBox = try? AES.GCM.SealedBox(combined: data),
              let plaintext = try? AES.GCM.open(sealedBox, using: key) else { return nil }
        return String(data: plaintext, encoding: .utf8)
    }
}

/// 补发队列的加密密钥：与设备身份的 deviceSecret 分开、单独存一份文件，
/// 首次使用时生成一个真正随机的 256-bit 对称密钥并持久化，之后每次启动直接复用同一把
/// 密钥，保证之前落盘的队列文件在下次读取时依然能解密。不走 Keychain：这把密钥只保护
/// 本地暂存、尚未补发的队列数据，不涉及跟后端的身份验签，文件持久化即可。
enum PendingQueueCrypto {
    private static var keyFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BigDaddy/pending-queue-key")
    }

    /// 进程内只读一次盘。上面那句"每次启动直接复用同一把密钥"说的就是这个意思——
    /// 原先每次 encrypt/decrypt 都要重新读一遍密钥文件，而补发排空时这两个操作每条
    /// 记录都要各走一次。密钥一旦确定，本进程生命周期内不会再变（真被外部换掉了，
    /// 之前落盘的队列本来也解不开了）。
    private static let keyLock = NSLock()
    private static var cachedKey: SymmetricKey?

    static func loadOrCreateKey() -> SymmetricKey {
        keyLock.lock()
        defer { keyLock.unlock() }
        if let cachedKey { return cachedKey }
        let key = loadOrCreateKeyFromDisk()
        cachedKey = key
        return key
    }

    private static func loadOrCreateKeyFromDisk() -> SymmetricKey {
        if let data = try? Data(contentsOf: keyFileURL), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let newKey = SymmetricKey(size: .bits256)
        let data = newKey.withUnsafeBytes { Data($0) }
        try? FileManager.default.createDirectory(
            at: keyFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: keyFileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFileURL.path)
        return newKey
    }
}
