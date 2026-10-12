import AppKit

/// 孩子这一端的短消息协调者：什么时候拉对话、哪条家长消息该弹旗帜、窗口和旗帜的回调
/// 怎么接到网络请求上。
///
/// 对话只放在内存里——不写 UserDefaults、不写 ConfigStore、不进 AuditLog 的正文。
/// AuditLog 只记"收到/发出一条消息"这件事本身。退出 App 就没了，下次启动重新拉；
/// 服务端那份 24 小时后也会消失。
@MainActor
final class MessageCenter {
    private let client: BigDaddyClient
    private let flag = MessageFlag()
    private let model = ChatViewModel()
    private lazy var window = MessageWindowController(model: model)
    private var fetchInFlight = false
    private var fetchAgain = false
    /// 已经弹过旗帜的家长消息。只在内存里；重启后仍未读的会再弹一次，这正是想要的。
    private var presentedMessageIds = Set<String>()
    /// "X 分钟后可以申请"到点时自动再拉一次。服务端的判定只在拉取时算一次，不重拉的话
    /// 孩子开着窗口等，时间到了界面也不会自己变成可申请。
    private var retryTimer: Timer?

    /// 拿状态栏图标和时间约定旗帜做定位参照，由 AppDelegate 注入
    var anchorProvider: (() -> NSStatusItem?)?
    var timeFlagProvider: (() -> TimeAgreementFlag?)?
    /// 对话有变化（未读数、入口是否该出现）：AppDelegate 据此重建菜单
    var onChange: (() -> Void)?

    private(set) var conversation: ChatConversation?

    init(client: BigDaddyClient) {
        self.client = client
        flag.onAcknowledge = { [weak self] in self?.acknowledgeUnread() }
        flag.onOpenHistory = { [weak self] in self?.openWindow() }
        flag.onSend = { [weak self] text in await self?.send(text: text) }
        model.sendText = { [weak self] text in await self?.send(text: text) }
        model.requestTime = { [weak self] minutes, reason in await self?.requestTime(minutes: minutes, reason: reason) }
    }

    /// 菜单里那一项的标题；nil = 不该出现（未绑定、旧后端、家长把两样都关了且没有残留消息）
    var menuTitle: String? {
        guard client.config.bound, let summary = client.config.messaging else { return nil }
        let unread = conversation?.unreadParentMessages.count ?? 0
        let visible = summary.mode != "OFF" || summary.timeRequestEnabled || conversation?.messages.isEmpty == false
        guard visible else { return nil }
        if unread > 0 {
            return Localization.string(zh: "💬 消息（\(unread) 条未读）…", en: "💬 Messages (\(unread) unread)…")
        }
        return Localization.string(zh: "💬 消息 / 申请时间…", en: "💬 Messages / Ask for time…")
    }

    /// 门铃或 revision 变化时调用。并发进来的请求合并成"做完这次再做一次"。
    func refresh() {
        guard client.config.bound else { return }
        if fetchInFlight {
            fetchAgain = true
            return
        }
        fetchInFlight = true
        Task { @MainActor in
            defer {
                fetchInFlight = false
                if fetchAgain {
                    fetchAgain = false
                    refresh()
                }
            }
            if let latest = await client.fetchMessages() {
                apply(latest)
            }
        }
    }

    func openWindow() {
        window.show()
        // 打开窗口 = 孩子看到了所有家长消息
        acknowledgeUnread()
        flag.dismiss()
    }

    /// 解绑：清掉内存里的一切，收起旗帜和窗口
    func reset() {
        conversation = nil
        presentedMessageIds.removeAll()
        retryTimer?.invalidate()
        retryTimer = nil
        model.conversation = ChatConversation()
        flag.dismiss()
        window.close()
        onChange?()
    }

    // MARK: - 状态应用

    private func apply(_ latest: ChatConversation) {
        let previous = conversation
        conversation = latest
        model.conversation = latest
        scheduleRetryRefresh(latest)
        announceDecisions(previous: previous, latest: latest)
        presentNewestUnreadIfNeeded(latest)
        onChange?()
    }

    private func scheduleRetryRefresh(_ conversation: ChatConversation) {
        retryTimer?.invalidate()
        retryTimer = nil
        guard let retryAt = conversation.timeRequestRetryAt else { return }
        let delay = max(1, TimeInterval(retryAt) / 1000 - Date().timeIntervalSince1970 + 1)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    /// 有没看过的家长消息就弹旗帜（窗口开着时不弹——孩子已经在看了）。
    private func presentNewestUnreadIfNeeded(_ conversation: ChatConversation) {
        let unread = conversation.unreadParentMessages
        if window.isOpen {
            if !unread.isEmpty { acknowledgeUnread() }
            return
        }
        guard let newest = unread.last, let anchor = anchorProvider?() else {
            // 别处已经读过（例如在窗口里），旗帜还挂着的话收起来
            if unread.isEmpty, flag.shownMessageId != nil { flag.dismiss() }
            return
        }
        let isNew = !presentedMessageIds.contains(newest.id)
        guard isNew || flag.shownMessageId == newest.id else { return }
        presentedMessageIds.formUnion(unread.map(\.id))
        if isNew {
            AuditLog.record("MESSAGE_RECEIVED 收到家长的一条消息")
        }
        flag.presentParentMessage(
            newest,
            moreUnread: unread.count - 1,
            canReply: conversation.canSendText,
            replyHint: replyHint(conversation),
            anchor: anchor,
            avoiding: timeFlagProvider?()
        )
    }

    /// 申请的结果。批准时时间约定旗帜自己会滑出来（那才是权威的倒计时），这里只在
    /// 没批准时说一声，免得孩子一直等。
    private func announceDecisions(previous: ChatConversation?, latest: ChatConversation) {
        guard let previous, let anchor = anchorProvider?() else { return }
        let before = Dictionary(uniqueKeysWithValues: previous.messages.map { ($0.id, $0.requestStatus) })
        for message in latest.messages where message.isTimeRequest && !message.isFromParent {
            guard before[message.id] == "PENDING", message.requestStatus != "PENDING" else { continue }
            AuditLog.record("TIME_REQUEST_DECIDED \(message.requestStatus ?? "?")")
            if message.requestStatus == "DECLINED" {
                flag.presentNotice(
                    title: Localization.string(zh: "时间申请", en: "Time request"),
                    body: message.isExtension
                        ? Localization.string(
                            zh: "这次家长没有同意延长 \(message.minutes ?? 0) 分钟",
                            en: "Your parent said no to extending by \(message.minutes ?? 0) min this time"
                        )
                        : Localization.string(
                            zh: "这次家长没有同意你申请的 \(message.minutes ?? 0) 分钟",
                            en: "Your parent said no to \(message.minutes ?? 0) more minutes this time"
                        ),
                    symbol: "hourglass", tint: .secondaryLabelColor,
                    anchor: anchor, avoiding: timeFlagProvider?()
                )
            }
        }
    }

    private func replyHint(_ conversation: ChatConversation) -> String? {
        guard conversation.mode == "PARENT_ONLY", let left = conversation.repliesLeft else { return nil }
        return Localization.string(zh: "还能回复 \(left) 条 · 30 分钟内有效", en: "\(left) replies left · within 30 min")
    }

    // MARK: - 动作

    private func acknowledgeUnread() {
        guard let ids = conversation?.unreadParentMessages.map(\.id), !ids.isEmpty else { return }
        Task { @MainActor in
            if let latest = await client.markMessagesRead(ids) {
                conversation = latest
                model.conversation = latest
                onChange?()
            }
        }
    }

    private func send(text: String) async -> String? {
        do {
            let latest = try await client.sendChildMessage(kind: "TEXT", text: text, minutes: nil)
            AuditLog.record("MESSAGE_SENT 给家长发了一条消息")
            // 回复了 = 也看到了家长的消息
            presentedMessageIds.formUnion(latest.unreadParentMessages.map(\.id))
            conversation = latest
            model.conversation = latest
            acknowledgeUnread()
            onChange?()
            return nil
        } catch {
            return errorText(error)
        }
    }

    private func requestTime(minutes: Int, reason: String) async -> String? {
        do {
            let latest = try await client.sendChildMessage(kind: "TIME_REQUEST", text: reason, minutes: minutes)
            AuditLog.record("TIME_REQUESTED 申请了 \(minutes) 分钟")
            conversation = latest
            model.conversation = latest
            onChange?()
            return nil
        } catch {
            return errorText(error)
        }
    }

    private func errorText(_ error: Error) -> String {
        let code = (error as? BigDaddyAPIError)?.serverMessage
        // 被拒后顺手刷新一次：多半是服务端状态（回复窗口、申请状态）和本地看到的不一致了
        refresh()
        return ChatText.blockedReason(code ?? "NETWORK", conversation: conversation ?? ChatConversation())
    }
}
