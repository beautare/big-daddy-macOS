import Foundation

/// 内容过滤 provider ↔ 主 App 的策略回执通道。
///
/// **为什么不是共享文件。** 这条通道最早用的是 App Group 容器里的一个 json：provider
/// 应用完策略就写一份回执，主 App 读出来当作 appliedRevision 上报给家长端。它从来
/// 没有通过过一次——NEFilterDataProvider 由系统以 **root** 启动，主 App 跑在登录用户
/// 下，而 `containerURL(forSecurityApplicationGroupIdentifier:)` 解析的是**调用进程所属
/// 用户**的 `~/Library/Group Containers/`。于是 provider 写的是
/// `/var/root/Library/Group Containers/<group>/…`，主 App 读的是
/// `/Users/<用户>/Library/Group Containers/<group>/…`，两个文件永不相交。
///
/// 症状是纯粹的假象：拦截其实一直生效（策略走 `NEFilterProviderConfiguration.vendorConfiguration`，
/// 与这条回执通道无关），只有"实际版本"恒为 0，家长端因此永远停在"策略同步中"。
/// 所以修的是回执，不是过滤本身。
///
/// **Mach 服务名。** NetworkExtension 要求 `NEMachServiceName` 必须以 App Group id 打头，
/// 系统才会替扩展注册这个 mach 服务；打包脚本按同一规则生成并逐字校验（见 package.sh），
/// 两端因此拿到的一定是同一个字符串。
@objc protocol WebFilterProviderXPC {
    /// 回执用 `Data` 传而不是直接传结构体：`NSXPCInterface` 只吃 NSSecureCoding，
    /// 让两端共用同一个 Codable 模型，比再维护一份 @objc 镜像类型便宜得多。
    /// provider 还没应用过任何策略时回 nil——这是真话，不要用零值伪装成"已应用"。
    func currentAcknowledgement(withReply reply: @escaping (Data?) -> Void)

    /// 主 App 把新策略直接推给正在跑的 provider，绕开 NEFilterManager.saveToPreferences()
    /// 之后系统自己那条配置分发管线——那条路实测把更新送到一个已经在跑的进程可能要一两
    /// 分钟，见 WebFilterController.enableContentFilter 里"抄近路"那段注释和
    /// FilterDataProvider.applyPolicy 的注释。
    ///
    /// data 是 WebFilterPolicyTransport.encode(_:) 编出来的裸 WebFilterPolicySnapshot 字节。
    /// reply 只回答"这次调用本身有没有走通"（解码成功、且确实调用了处理闭包），不代表策略
    /// 一定被采纳——更旧的策略会被 WebFilterPolicyReplacement 挡在门外，那属于正常丢弃，
    /// 不是失败，调用方不需要也不应该区分这两种情况。
    func applyPolicy(_ data: Data, withReply reply: @escaping (Bool) -> Void)
}

enum WebFilterIPC {
    /// mach 服务名 = App Group id + 这个后缀。改这里必须同步改 package.sh 里的
    /// FILTER_MACH_SERVICE_NAME，脚本会在打包时逐字比对，对不上直接失败。
    static let machServiceSuffix = ".BigDaddyWebFilter"

    /// 主 App 侧：从自己的 Info.plist 里的 App Group id 推导。
    static func machServiceName(bundle: Bundle = .main) -> String? {
        guard let group = appGroupIdentifier(bundle: bundle) else { return nil }
        return machServiceName(appGroupIdentifier: group)
    }

    static func machServiceName(appGroupIdentifier: String) -> String {
        appGroupIdentifier + machServiceSuffix
    }

    /// 扩展侧：以系统实际注册的那个名字为准（Info.plist 的 NetworkExtension.NEMachServiceName），
    /// 取不到再退回推导值。监听方用错名字会静默地谁也连不上，这里多一层以实际注册为准的读取。
    static func providerMachServiceName(bundle: Bundle = .main) -> String? {
        if let networkExtension = bundle.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any],
           let declared = networkExtension["NEMachServiceName"] as? String,
           !declared.isEmpty {
            return declared
        }
        return machServiceName(bundle: bundle)
    }

    static func appGroupIdentifier(bundle: Bundle = .main) -> String? {
        guard let group = bundle.object(forInfoDictionaryKey: "BigDaddyAppGroupIdentifier") as? String,
              !group.isEmpty
        else {
            return nil
        }
        return group
    }

    /// 从 App Group id 里切出团队标识：签名构建下它形如 `L2GSNW7RA2.group.vip.bigdaddy.shared`。
    /// 本地 `CODESIGN_IDENTITY="-"` 的调试构建没有这段前缀（package.sh 里 TEAM_IDENTIFIER_PREFIX
    /// 为空），返回 nil，调用方据此跳过签名校验——否则本地跑起来的两个进程永远互相拒绝。
    static func teamIdentifier(bundle: Bundle = .main) -> String? {
        guard let group = appGroupIdentifier(bundle: bundle) else { return nil }
        return teamIdentifier(appGroupIdentifier: group)
    }

    static func teamIdentifier(appGroupIdentifier: String) -> String? {
        let prefix = String(appGroupIdentifier.prefix(while: { $0 != "." }))
        return prefix.isEmpty || prefix == "group" ? nil : prefix
    }

    /// 只认同一个开发者团队签出来的对端。主 App 现在会经这条通道向 provider 推送策略
    /// （applyPolicy），校验不到位的后果不再局限于"读到假回执"，而是别的进程能够直接
    /// 篡改过滤策略——团队号既然就摆在 App Group id 里，这道检查不能省。
    ///
    /// 串必须是合法的 code requirement —— `setCodeSigningRequirement` 遇到非法串会抛
    /// ObjC 异常，Swift 这边接不住，直接就是崩溃。所以这里只做固定模板 + 团队号插值，
    /// 团队号本身又是从 App Group id 里切出来的，不接受任何外部输入。
    static func codeSigningRequirement(bundle: Bundle = .main) -> String? {
        guard let team = teamIdentifier(bundle: bundle) else { return nil }
        return requirement(teamIdentifier: team)
    }

    static func codeSigningRequirement(appGroupIdentifier: String) -> String? {
        guard let team = teamIdentifier(appGroupIdentifier: appGroupIdentifier) else { return nil }
        return requirement(teamIdentifier: team)
    }

    private static func requirement(teamIdentifier team: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}

enum WebFilterAcknowledgementCodec {
    static func encode(_ acknowledgement: WebFilterProviderAcknowledgement) -> Data? {
        try? encoder.encode(acknowledgement)
    }

    static func decode(_ data: Data) -> WebFilterProviderAcknowledgement? {
        try? decoder.decode(WebFilterProviderAcknowledgement.self, from: data)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - 扩展侧：监听

/// provider 进程里的回执服务端。只回答一个问题，不接受任何指令。
final class WebFilterProviderIPCListener: NSObject, NSXPCListenerDelegate, WebFilterProviderXPC {
    private let listener: NSXPCListener
    private let codeSigningRequirement: String?
    private let lock = NSLock()
    private var acknowledgement: WebFilterProviderAcknowledgement?
    /// FilterDataProvider 落地一份推送来的策略的地方。放闭包而不是让这个类直接持有
    /// FilterDataProvider 的私有状态（trackedFlows/policyLock）——IPC 这一层不该知道
    /// 过滤器内部怎么记账，它只负责把字节从 mach service 那头搬过来。
    var onPolicyPushed: ((WebFilterPolicySnapshot) -> Void)?

    init(machServiceName: String, codeSigningRequirement: String?) {
        self.listener = NSXPCListener(machServiceName: machServiceName)
        self.codeSigningRequirement = codeSigningRequirement
        super.init()
        listener.delegate = self
    }

    func start() {
        listener.resume()
    }

    /// provider 每次真正应用完一份策略就调一次。存内存不落盘：provider 重启后回执理应
    /// 归零，等它重新读到 vendorConfiguration 再重新确认——沿用上一条进程的回执等于
    /// 替一个还没干活的 provider 打包票。
    func publish(_ acknowledgement: WebFilterProviderAcknowledgement) {
        lock.lock()
        self.acknowledgement = acknowledgement
        lock.unlock()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        if let requirement = codeSigningRequirement, #available(macOS 13.0, *) {
            newConnection.setCodeSigningRequirement(requirement)
        }
        newConnection.exportedInterface = NSXPCInterface(with: WebFilterProviderXPC.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func currentAcknowledgement(withReply reply: @escaping (Data?) -> Void) {
        lock.lock()
        let current = acknowledgement
        lock.unlock()
        reply(current.flatMap(WebFilterAcknowledgementCodec.encode))
    }

    func applyPolicy(_ data: Data, withReply reply: @escaping (Bool) -> Void) {
        guard let policy = WebFilterPolicyTransport.decode(data) else {
            reply(false)
            return
        }
        // onPolicyPushed 只在 FilterDataProvider.startFilter 里、provider 真正起来之后
        // 才会被设上；理论上 XPC 消息不可能在这之前就送到（listener.resume() 也是那时候
        // 才调用），这里仍然按 nil 处理而不是硬解包，纯粹是防御性写法。
        onPolicyPushed?(policy)
        reply(true)
    }
}

// MARK: - 主 App 侧：连接

/// 主 App 侧的回执客户端。连接懒建、断了就作废，下次问的时候重连——provider 会随
/// 系统扩展的启停反复上下线，长连接必须能自愈，否则一次断开就等于回执永久失联。
final class WebFilterProviderConnection: @unchecked Sendable {
    private let machServiceName: String?
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    init(machServiceName: String? = WebFilterIPC.machServiceName()) {
        self.machServiceName = machServiceName
    }

    func acknowledgement() async -> WebFilterProviderAcknowledgement? {
        guard let connection = ensureConnection() else { return nil }
        return await withCheckedContinuation { continuation in
            let box = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                NSLog("BigDaddy: web filter provider unreachable: \(error.localizedDescription)")
                box.resume(nil)
            } as? WebFilterProviderXPC
            guard let proxy else {
                box.resume(nil)
                return
            }
            proxy.currentAcknowledgement { data in
                box.resume(data.flatMap(WebFilterAcknowledgementCodec.decode))
            }
        }
    }

    /// 把一份策略直接推给正在跑的 provider。见 WebFilterProviderXPC.applyPolicy 的注释——
    /// 这是绕开系统配置分发管线延迟的加速通道，不是持久化路径。返回 false 只表示"没能把
    /// 这次调用送到"（provider 不在线、连接失败），调用方不该把它当错误处理：下面走
    /// NEFilterManager 的正常流程仍然会把同一份策略送到位，只是慢一点。
    func pushPolicy(_ policy: WebFilterPolicySnapshot) async -> Bool {
        guard let connection = ensureConnection(), let data = WebFilterPolicyTransport.encode(policy) else {
            return false
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let box = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                NSLog("BigDaddy: web filter provider unreachable while pushing policy: \(error.localizedDescription)")
                box.resume(false)
            } as? WebFilterProviderXPC
            guard let proxy else {
                box.resume(false)
                return
            }
            proxy.applyPolicy(data) { success in box.resume(success) }
        }
    }

    private func ensureConnection() -> NSXPCConnection? {
        guard let machServiceName else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: WebFilterProviderXPC.self)
        if let requirement = WebFilterIPC.codeSigningRequirement(), #available(macOS 13.0, *) {
            connection.setCodeSigningRequirement(requirement)
        }
        connection.invalidationHandler = { [weak self] in self?.clear() }
        connection.interruptionHandler = { [weak self] in self?.clear() }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func clear() {
        lock.lock()
        connection = nil
        lock.unlock()
    }
}

/// `withCheckedContinuation` 只允许恢复一次，而 XPC 有两条都可能先到的回调路径
/// （reply 和 errorHandler）。用它把"谁先到谁生效"这件事收进一个地方。
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
