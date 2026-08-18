import Foundation

/// 时间约定截止点的跨进程持久化——只存"离线冷启动能不能安全恢复旗帜"需要的最小信息，
/// **不是**完整的 ClientConfig.timeSession 快照。那份的 remainingSeconds 是相对量，
/// 只在服务端算出它那一刻成立，见 BigDaddyClient.init() 里作废 ConfigStore 里
/// timeSession 的那段注释；这里存的 wallDeadline 是绝对墙钟时刻，跨越关机一整晚这类
/// 不可知时长依然成立，才是能安全恢复的原因。
///
/// 与 ConfigStore 分开落盘：ConfigStore 落的是服务端策略本身（家长在家长中心配的一切），
/// 这里落的是本地派生量，混在一起会让"这个值到底谁写的、谁读的、多久失效"变得含糊。
struct PersistedTimeSessionAnchor: Codable {
    let sessionId: String
    let wallDeadline: Date
    let grantedSeconds: Int
    /// 家长写给孩子的留言，一并存下来才能让离线冷启动恢复出来的旗帜看着完整，
    /// 不是一个没头没尾的倒计时。
    let note: String?
}

enum TimeSessionAnchorStore {
    static var fileURL: URL {
        ConfigStore.configFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("time-session-anchor.json")
    }

    static func load() -> PersistedTimeSessionAnchor? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder.bigDaddy.decode(PersistedTimeSessionAnchor.self, from: data)
    }

    static func save(_ anchor: PersistedTimeSessionAnchor) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.bigDaddy.encode(anchor)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("BigDaddy failed to save time session anchor: \(error.localizedDescription)")
        }
    }

    /// 会话结束（到点/中断/替换）或成功刷新后确认没有进行中的会话时调用，避免下次冷启动
    /// 读到一份早已作废的旧记录。
    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
