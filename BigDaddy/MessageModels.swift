import Foundation

/// 随 /client/config 下发的短消息摘要。客户端只拿 revision 判断"要不要去拉一次对话"，
/// 正文从不出现在配置里，也就从不跟着 ConfigStore 落盘。
struct ClientMessagingSummary: Codable {
    var mode: String
    var timeRequestEnabled: Bool
    var revision: String?
}

extension ClientMessagingSummary: Equatable {
    /// 刻意不比 revision：它在每一条消息往来时都会变，若参与相等性比较，ClientConfig 的
    /// `config != previous` 就会在聊天期间不停判定"配置变了"，误触发 rebuildMenu 和
    /// CONFIG_UPDATED 心跳——与 TimeSession 只比 sessionId 是同一个顾虑。
    static func == (lhs: ClientMessagingSummary, rhs: ClientMessagingSummary) -> Bool {
        lhs.mode == rhs.mode && lhs.timeRequestEnabled == rhs.timeRequestEnabled
    }
}

/// 对话里的一条消息。时间都是 epoch 毫秒。
struct ChatMessage: Codable, Equatable, Identifiable {
    let id: String
    /// PARENT | CHILD
    let sender: String
    /// TEXT | TIME_REQUEST
    let kind: String
    let text: String?
    let minutes: Int?
    /// PENDING | APPROVED | DECLINED | EXPIRED（仅 TIME_REQUEST）
    let requestStatus: String?
    let sentAt: Int64
    let expiresAt: Int64
    let deliveredAt: Int64?
    let readAt: Int64?
    let decidedAt: Int64?
    /// 仅 TIME_REQUEST：START = 新开一段；EXTEND = 在进行中的约定上延长
    let requestMode: String?

    var isFromParent: Bool { sender == "PARENT" }
    var isTimeRequest: Bool { kind == "TIME_REQUEST" }
    var isExtension: Bool { requestMode == "EXTEND" }
    var sentDate: Date { Date(timeIntervalSince1970: TimeInterval(sentAt) / 1000) }
    var expiresDate: Date { Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1000) }
}

/// Mac 看到的整段对话 + 服务端算好的"现在能不能发"。规则只在服务端写一份
/// （MessagingPolicy），这里只照着判定结果渲染。
struct ChatConversation: Codable, Equatable {
    var mode: String = "OFF"
    var timeRequestEnabled: Bool = false
    var revision: String?
    var canSendText: Bool = false
    var sendBlockedReason: String?
    var replyWindowEndsAt: Int64?
    var repliesLeft: Int?
    var canRequestTime: Bool = false
    /// 此刻有进行中的约定：这次申请的是"延长"
    var requestWillExtend: Bool = false
    var timeRequestBlockedReason: String?
    var timeRequestRetryAt: Int64?
    var requestMinuteOptions: [Int] = [5, 10, 15, 20, 30]
    var retentionHours: Int = 24
    var maxTextLength: Int = 100
    var messages: [ChatMessage] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "OFF"
        timeRequestEnabled = try c.decodeIfPresent(Bool.self, forKey: .timeRequestEnabled) ?? false
        revision = try c.decodeIfPresent(String.self, forKey: .revision)
        canSendText = try c.decodeIfPresent(Bool.self, forKey: .canSendText) ?? false
        sendBlockedReason = try c.decodeIfPresent(String.self, forKey: .sendBlockedReason)
        replyWindowEndsAt = try c.decodeIfPresent(Int64.self, forKey: .replyWindowEndsAt)
        repliesLeft = try c.decodeIfPresent(Int.self, forKey: .repliesLeft)
        canRequestTime = try c.decodeIfPresent(Bool.self, forKey: .canRequestTime) ?? false
        requestWillExtend = try c.decodeIfPresent(Bool.self, forKey: .requestWillExtend) ?? false
        timeRequestBlockedReason = try c.decodeIfPresent(String.self, forKey: .timeRequestBlockedReason)
        timeRequestRetryAt = try c.decodeIfPresent(Int64.self, forKey: .timeRequestRetryAt)
        requestMinuteOptions = try c.decodeIfPresent([Int].self, forKey: .requestMinuteOptions) ?? [5, 10, 15, 20, 30]
        retentionHours = try c.decodeIfPresent(Int.self, forKey: .retentionHours) ?? 24
        maxTextLength = try c.decodeIfPresent(Int.self, forKey: .maxTextLength) ?? 100
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
    }

    /// 家长消息里孩子还没点过「知道了 / 回复」、也没打开过对话窗口的
    var unreadParentMessages: [ChatMessage] {
        messages.filter { $0.isFromParent && $0.readAt == nil }
    }

    /// 菜单里要不要出现"消息"入口：通信关闭且不允许申请时间时，孩子这边什么都不该看到
    var hasAnyEntry: Bool {
        mode != "OFF" || timeRequestEnabled || !messages.isEmpty
    }
}

/// 服务端错误码 → 给孩子看的话。服务端只回错误码（见 MessagingPolicy / BigDaddyMessagingService），
/// 文案在这里本地化。
enum ChatText {
    static func blockedReason(_ code: String?, conversation: ChatConversation) -> String {
        switch code {
        case "MESSAGING_OFF":
            return Localization.string(zh: "家长关闭了消息功能", en: "Your parent turned messages off")
        case "NO_PARENT_MESSAGE", "REPLY_WINDOW_CLOSED":
            return Localization.string(
                zh: "家长发来消息后的 30 分钟内可以回复",
                en: "You can reply within 30 minutes after your parent writes"
            )
        case "REPLY_LIMIT_REACHED":
            return Localization.string(zh: "这条消息的回复次数用完了", en: "No replies left for this message")
        case "RATE_LIMITED":
            return Localization.string(zh: "发得太快了，稍后再试", en: "Too fast — try again in a moment")
        case "REQUEST_PENDING":
            return Localization.string(zh: "已发出申请，等家长回复…", en: "Request sent — waiting for your parent…")
        case "COOLDOWN":
            if let retryAt = conversation.timeRequestRetryAt {
                let minutes = max(1, Int(ceil((Double(retryAt) / 1000 - Date().timeIntervalSince1970) / 60)))
                return Localization.string(zh: "\(minutes) 分钟后可以再申请", en: "You can ask again in \(minutes) min")
            }
            return Localization.string(zh: "稍后可以再申请", en: "You can ask again later")
        case "SESSION_TOO_EARLY":
            // 约定还剩不少时间：最后 5 分钟才能申请延长
            if let retryAt = conversation.timeRequestRetryAt {
                let minutes = max(1, Int(ceil((Double(retryAt) / 1000 - Date().timeIntervalSince1970) / 60)))
                return Localization.string(
                    zh: "约定还没到最后 5 分钟，\(minutes) 分钟后可以申请延长",
                    en: "You can ask for more time in the last 5 minutes — in \(minutes) min"
                )
            }
            return Localization.string(zh: "约定的最后 5 分钟可以申请延长", en: "You can ask for more time in the last 5 minutes")
        case "TIME_REQUEST_DISABLED":
            return Localization.string(zh: "家长没有开启时间申请", en: "Time requests are turned off")
        case "MESSAGE_TOO_LONG":
            return Localization.string(zh: "太长了，最多 \(conversation.maxTextLength) 个字", en: "Too long — \(conversation.maxTextLength) characters max")
        case "MESSAGE_EMPTY":
            return Localization.string(zh: "写点什么再发吧", en: "Type something first")
        case nil:
            return ""
        default:
            return Localization.string(zh: "没发出去，请稍后再试", en: "Couldn't send — please try again")
        }
    }

    static func requestStatus(_ status: String?, extension isExtension: Bool = false) -> String {
        switch status {
        case "APPROVED" where isExtension: return Localization.string(zh: "家长同意了，约定已延长", en: "Approved — time extended")
        case "APPROVED": return Localization.string(zh: "家长同意了", en: "Approved")
        case "DECLINED": return Localization.string(zh: "这次没有同意", en: "Not this time")
        case "EXPIRED": return Localization.string(zh: "没等到回复，已失效", en: "No answer — expired")
        default: return Localization.string(zh: "等待家长回复…", en: "Waiting for your parent…")
        }
    }

    static func lifecycleNotice(hours: Int) -> String {
        Localization.string(
            zh: "消息发出 \(hours) 小时后自动消失，消失后找不回来",
            en: "Messages disappear \(hours) hours after they're sent and can't be recovered"
        )
    }

    /// 时间申请理由的预填值：短、中性，孩子可以直接发，也可以改成具体的事
    static var defaultRequestReason: String {
        Localization.string(zh: "想再用一会儿", en: "A little more time, please")
    }

    /// 孩子端的常用回复。内置、不可编辑：最常见的就这几句，一键发出比打字快。
    static var quickReplies: [String] {
        [
            Localization.string(zh: "好的", en: "OK"),
            Localization.string(zh: "马上", en: "Coming"),
            Localization.string(zh: "再给我 5 分钟", en: "5 more minutes?"),
            Localization.string(zh: "我在写作业", en: "Doing homework")
        ]
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d HH:mm"
        return formatter.string(from: date)
    }
}
