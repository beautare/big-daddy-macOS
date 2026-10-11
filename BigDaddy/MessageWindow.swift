import AppKit
import SwiftUI

/// 对话窗口的状态。MessageCenter 持有它、往里写最新对话；SwiftUI 视图只读它和调回调。
@MainActor
final class ChatViewModel: ObservableObject {
    @Published var conversation = ChatConversation()
    @Published var isSending = false
    @Published var errorText: String?

    /// 返回 nil 表示成功，否则是给孩子看的错误文案
    var sendText: ((String) async -> String?)?
    var requestTime: ((Int, String) async -> String?)?

    func send(_ text: String) async -> Bool {
        guard let sendText, !isSending else { return false }
        isSending = true
        errorText = await sendText(text)
        isSending = false
        return errorText == nil
    }

    func request(minutes: Int, reason: String) async -> Bool {
        guard let requestTime, !isSending else { return false }
        isSending = true
        errorText = await requestTime(minutes, reason)
        isSending = false
        return errorText == nil
    }
}

/// 孩子这边的对话窗口：平铺的气泡流（不嵌套、不引用，回复就是在末尾追加一条），
/// 家长在左、自己在右；底部是回复框和"申请时间约定"。
struct ChatHistoryView: View {
    @ObservedObject var model: ChatViewModel
    @State private var draft = ""
    @State private var reason = ChatText.defaultRequestReason
    @State private var minutes = 10

    private var conversation: ChatConversation { model.conversation }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Localization.string(zh: "和家长的消息", en: "Messages with your parent"))
                    .font(.headline)
                Label(ChatText.lifecycleNotice(hours: conversation.retentionHours), systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        if conversation.messages.isEmpty {
                            Text(Localization.string(zh: "还没有消息", en: "No messages yet"))
                                .font(.callout)
                                .foregroundColor(.secondary)
                                .padding(.top, 40)
                        }
                        ForEach(conversation.messages) { message in
                            ChatRow(message: message).id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onAppear { scrollToEnd(proxy) }
                .onChange(of: conversation.messages.count) { _ in scrollToEnd(proxy) }
            }

            Divider()
            composer.padding(12)

            if conversation.timeRequestEnabled {
                Divider()
                timeRequest.padding(12)
            }
        }
        .frame(width: 380, height: 540)
    }

    @ViewBuilder
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if conversation.canSendText {
                HStack(spacing: 6) {
                    ForEach(ChatText.quickReplies, id: \.self) { phrase in
                        Button(phrase) { Task { _ = await model.send(phrase) } }
                            .controlSize(.small)
                            .disabled(model.isSending)
                    }
                }
                HStack {
                    TextField(Localization.string(zh: "写点什么…", en: "Write something…"), text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sendDraft)
                    Button(Localization.string(zh: "发送", en: "Send"), action: sendDraft)
                        .disabled(model.isSending || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let hint = replyHint {
                    Text(hint).font(.caption2).foregroundColor(.secondary)
                }
            } else {
                Text(ChatText.blockedReason(conversation.sendBlockedReason, conversation: conversation))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let error = model.errorText {
                Text(error).font(.caption).foregroundColor(.red)
            }
        }
    }

    @ViewBuilder
    private var timeRequest: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(conversation.requestWillExtend
                 ? Localization.string(zh: "时间快到了？向家长申请延长", en: "Almost out of time? Ask for more")
                 : Localization.string(zh: "想多用一会儿电脑？向家长申请", en: "Need more time? Ask your parent"))
                .font(.subheadline.weight(.semibold))
            if conversation.canRequestTime {
                Picker("", selection: $minutes) {
                    ForEach(conversation.requestMinuteOptions, id: \.self) { option in
                        Text(Localization.string(zh: "\(option) 分钟", en: "\(option) min")).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack {
                    // 理由必填：家长批不批，很大程度上看孩子要这段时间做什么。预填一句短的默认值，
                    // 孩子赶时间也能一键发出，想多说两句就改掉它。
                    TextField(Localization.string(zh: "理由（必填）", en: "Reason (required)"), text: $reason)
                        .textFieldStyle(.roundedBorder)
                    Button(conversation.requestWillExtend
                           ? Localization.string(zh: "申请延长", en: "Ask to extend")
                           : Localization.string(zh: "发送申请", en: "Ask")) {
                        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            if await model.request(minutes: minutes, reason: trimmed) {
                                reason = ChatText.defaultRequestReason
                            }
                        }
                    }
                    .disabled(model.isSending || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text(ChatText.blockedReason(conversation.timeRequestBlockedReason, conversation: conversation))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var replyHint: String? {
        guard conversation.mode == "PARENT_ONLY", let left = conversation.repliesLeft,
              let endsAt = conversation.replyWindowEndsAt else { return nil }
        let end = ChatText.clock(Date(timeIntervalSince1970: TimeInterval(endsAt) / 1000))
        return Localization.string(zh: "还能回复 \(left) 条 · \(end) 前有效", en: "\(left) replies left · until \(end)")
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            if await model.send(text) { draft = "" }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = conversation.messages.last else { return }
        DispatchQueue.main.async { proxy.scrollTo(last.id, anchor: .bottom) }
    }
}

private struct ChatRow: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if !message.isFromParent { Spacer(minLength: 60) }
            VStack(alignment: message.isFromParent ? .leading : .trailing, spacing: 3) {
                if message.isTimeRequest {
                    requestCard
                } else {
                    Text(message.text ?? "")
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(message.isFromParent ? Color(nsColor: .controlBackgroundColor) : Color.accentColor)
                        .foregroundColor(message.isFromParent ? .primary : .white)
                        .cornerRadius(12)
                }
                Text(ChatText.clock(message.sentDate))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if message.isFromParent { Spacer(minLength: 60) }
        }
    }

    private var requestCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(message.isExtension
                  ? Localization.string(zh: "申请延长 \(message.minutes ?? 0) 分钟", en: "Asked for \(message.minutes ?? 0) more min")
                  : Localization.string(zh: "申请 \(message.minutes ?? 0) 分钟", en: "Asked for \(message.minutes ?? 0) min"),
                  systemImage: "hourglass")
                .font(.callout.weight(.semibold))
            if let text = message.text, !text.isEmpty {
                Text(text).font(.callout)
            }
            Text(ChatText.requestStatus(message.requestStatus, extension: message.isExtension))
                .font(.caption)
                .foregroundColor(statusColor)
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.5)))
    }

    private var statusColor: Color {
        switch message.requestStatus {
        case "APPROVED": return .green
        case "DECLINED", "EXPIRED": return .secondary
        default: return .orange
        }
    }
}

/// 对话窗口本身。孩子从菜单栏主动打开，所以这里激活 App、正常拿焦点。
@MainActor
final class MessageWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let model: ChatViewModel
    var onClose: (() -> Void)?

    var isOpen: Bool { window?.isVisible == true }

    init(model: ChatViewModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 540),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = Localization.string(zh: "消息", en: "Messages")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ChatHistoryView(model: model))
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        model.errorText = nil
        onClose?()
    }
}
