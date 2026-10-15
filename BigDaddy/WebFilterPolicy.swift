import Foundation

struct WebFilterRule: Codable, Equatable {
    let domain: String
    let includeSubdomains: Bool
    let category: String?
    let weeklyPlanId: String?

    init(domain: String, includeSubdomains: Bool, category: String? = nil, weeklyPlanId: String? = nil) {
        self.domain = domain
        self.includeSubdomains = includeSubdomains
        self.category = category
        self.weeklyPlanId = weeklyPlanId
    }
}

struct WeeklyAccessWindow: Codable, Equatable {
    let daysOfWeek: [Int] // ISO weekday: Monday = 1
    let startMinute: Int
    let endMinute: Int
}

struct WeeklyAccessPlan: Codable, Equatable {
    let id: String
    let name: String
    let enabled: Bool
    let timeZone: String
    let windows: [WeeklyAccessWindow]

    private var calendar: Calendar? {
        guard let zone = TimeZone(identifier: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    func isOpen(at now: Date) -> Bool {
        guard enabled, let calendar else { return false }
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        let day = ((parts.weekday! + 5) % 7) + 1
        let minute = parts.hour! * 60 + parts.minute!
        return windows.contains { $0.daysOfWeek.contains(day) && minute >= $0.startMinute && minute < $0.endMinute }
    }

    func nextBoundary(after now: Date) -> Date? {
        guard enabled, let calendar else { return nil }
        var dates: [Date] = []
        let today = calendar.startOfDay(for: now)
        for offset in 0...7 {
            let date = calendar.date(byAdding: .day, value: offset, to: today)!
            let day = ((calendar.component(.weekday, from: date) + 5) % 7) + 1
            for window in windows where window.daysOfWeek.contains(day) {
                for minute in [window.startMinute, window.endMinute] {
                    let boundary: Date?
                    if minute == 1440 {
                        boundary = calendar.date(byAdding: .day, value: 1, to: date)
                    } else {
                        boundary = calendar.date(bySettingHour: minute / 60, minute: minute % 60,
                                                 second: 0, of: date)
                    }
                    if let boundary, boundary > now { dates.append(boundary) }
                }
            }
        }
        return dates.min()
    }
}

enum WebFilterMode: String, Codable {
    case blockSelected = "BLOCK_SELECTED"
    case allowSelected = "ALLOW_SELECTED"
}

struct WebFilterConfiguration: Codable, Equatable {
    var enabled: Bool = false
    var revision: Int64 = 0
    var blockedDomains: [WebFilterRule] = []
    var mode: WebFilterMode = .blockSelected
    var allowedDomains: [WebFilterRule] = []
    var appRules: [AppNetworkRule] = []
    var weeklyPlans: [WeeklyAccessPlan] = []
    var weeklyPlansBlockedUntilEpochMillis: Int64? = nil // -1: paused until parent resumes
    var temporaryAllowedUntilEpochMillis: Int64? = nil

    private enum CodingKeys: String, CodingKey {
        case enabled, revision, blockedDomains, mode, allowedDomains, appRules, weeklyPlans,
             weeklyPlansBlockedUntilEpochMillis, temporaryAllowedUntilEpochMillis
    }

    init(enabled: Bool = false, revision: Int64 = 0, blockedDomains: [WebFilterRule] = [],
         mode: WebFilterMode = .blockSelected, allowedDomains: [WebFilterRule] = [],
         appRules: [AppNetworkRule] = [],
         weeklyPlans: [WeeklyAccessPlan] = [], weeklyPlansBlockedUntilEpochMillis: Int64? = nil,
         temporaryAllowedUntilEpochMillis: Int64? = nil) {
        self.enabled = enabled
        self.revision = revision
        self.blockedDomains = blockedDomains
        self.mode = mode
        self.allowedDomains = allowedDomains
        self.appRules = appRules
        self.weeklyPlans = weeklyPlans
        self.weeklyPlansBlockedUntilEpochMillis = weeklyPlansBlockedUntilEpochMillis
        self.temporaryAllowedUntilEpochMillis = temporaryAllowedUntilEpochMillis
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        revision = try container.decode(Int64.self, forKey: .revision)
        blockedDomains = try container.decode([WebFilterRule].self, forKey: .blockedDomains)
        mode = try container.decodeIfPresent(WebFilterMode.self, forKey: .mode) ?? .blockSelected
        allowedDomains = try container.decodeIfPresent([WebFilterRule].self, forKey: .allowedDomains) ?? []
        appRules = try container.decodeIfPresent([AppNetworkRule].self, forKey: .appRules) ?? []
        weeklyPlans = try container.decodeIfPresent([WeeklyAccessPlan].self, forKey: .weeklyPlans) ?? []
        weeklyPlansBlockedUntilEpochMillis = try container.decodeIfPresent(Int64.self, forKey: .weeklyPlansBlockedUntilEpochMillis)
        temporaryAllowedUntilEpochMillis = try container.decodeIfPresent(Int64.self, forKey: .temporaryAllowedUntilEpochMillis)
    }
}

/// 软件联网的三档，与网站的三种待遇同一套说法。
enum AppNetworkAccess: String, Codable {
    case always = "ALWAYS"
    case agreement = "AGREEMENT"
    case never = "NEVER"
}

/// 发起一条连接的程序的代码签名身份，由过滤扩展从 sourceAppAuditToken 解析而来。
/// sourceAppAuditToken 标识的是**负责这条连接的 App**：nsurlsessiond 代某个 App 下载，
/// 算在那个 App 头上——这正是按软件管联网要的语义。
struct AppIdentity: Hashable {
    let signingIdentifier: String
    /// 开发者团队 ID；未签名或临时签名的程序为 nil
    let teamIdentifier: String?
    /// Apple 自带程序（满足 `anchor apple`）。任何软件联网规则都不作用于它
    let isPlatformBinary: Bool
    /// BigDaddy 自己：主程序、过滤扩展、Sparkle 的更新辅助进程。由扩展用"同一开发者团队签名"
    /// 的 code requirement 校验得出，不认签名标识符——标识符谁都能起，团队签名冒充不了。
    var isBigDaddy = false

    /// Apple 自带的浏览器入口：Safari 全家（技术预览版、它的辅助进程都以此开头）、WebKit 的
    /// 网络进程（万一连接被归到它名下而不是宿主 App）、模拟器里的 Safari。
    private static let appleBrowserPrefixes = ["com.apple.Safari", "com.apple.WebKit", "com.apple.mobilesafari"]

    /// 系统服务：除浏览器之外的 Apple 自带程序。Apple 自带的浏览器虽然也是系统程序，却是孩子
    /// 浏览网页的地方，必须照常执行网站规则。
    var isSystemService: Bool {
        isPlatformBinary && !Self.appleBrowserPrefixes.contains { signingIdentifier.hasPrefix($0) }
    }
}

/// 按代码签名身份管一个软件能不能联网。
struct AppNetworkRule: Codable, Equatable {
    let signingIdentifier: String
    let teamIdentifier: String?
    let displayName: String
    let access: AppNetworkAccess
    var weeklyPlanId: String? = nil

    /// 团队 ID 必须一致（防止同名标识符冒充）；签名标识符相等，或以"标识符."开头——
    /// 后者连带管住同前缀的辅助进程（com.valvesoftware.steam.helper），又不会误中
    /// com.valvesoftware.steamfoo。
    func matches(_ identity: AppIdentity) -> Bool {
        identity.teamIdentifier == teamIdentifier
            && (identity.signingIdentifier == signingIdentifier
                || identity.signingIdentifier.hasPrefix(signingIdentifier + "."))
    }
}

/// 最近联过网的软件，家长从这份清单里挑软件。扩展只知道签名身份和程序路径，
/// 展示名和"是不是浏览器"由主 App 按 bundlePath 补上再上报。
struct AppNetworkActivity: Codable, Equatable {
    let signingIdentifier: String
    let teamIdentifier: String?
    let bundlePath: String?
    var lastSeenAt: Date
    var connectionCount: Int
    var blockedCount: Int
}

/// 软件规则对一条连接的结论
enum AppNetworkVerdict {
    /// 没有规则管它（或它受保护），完全交给网站规则
    case none
    /// 不能联网
    case block
    /// 随时可以联网，或约定期间的 AGREEMENT 软件，以及系统服务和 BigDaddy 自己：
    /// 不再看"名单之外"的默认值，也不要求认出主机名
    case bypass
}

/// 白名单拦截到的网站只作为家长的候选项：客户端绝不因此自动放行。
/// 一个网站（主域名）一条；hosts 是这个网站下最近被挡的具体网址，最近的在前。
struct WebFilterAccessRequest: Codable, Equatable {
    let domain: String
    let lastBlockedAt: Date
    /// 尝试次数：同一网站 1 分钟内被挡多次只算一次，见 BlockedSiteLog
    let count: Int
    let hosts: [String]

    init(domain: String, lastBlockedAt: Date, count: Int, hosts: [String] = []) {
        self.domain = domain
        self.lastBlockedAt = lastBlockedAt
        self.count = count
        self.hosts = hosts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domain = try container.decode(String.self, forKey: .domain)
        lastBlockedAt = try container.decode(Date.self, forKey: .lastBlockedAt)
        count = try container.decode(Int.self, forKey: .count)
        // 升级空窗里旧版扩展发来的回执没有这个字段
        hosts = try container.decodeIfPresent([String].self, forKey: .hosts) ?? []
    }
}

/// "名单之外都打不开"时被挡下、等家长决定的网站。
///
/// 按主域名记：一个网页往往连着十几个 CDN、统计、字体网址，按具体网址记的话一个网页就能把
/// 名额占满，孩子真正想看的那个网站反而被挤掉；家长处理时也是按主域名放行的。次数记"尝试"
/// 而不是"连接"：同一网站 1 分钟内被挡多次只算一次，家长看到"试过 5 次"才大致等于孩子在
/// 5 个时间点想打开它。名额和保留时长与服务端 BigDaddyDtos 的同名常量一致。
struct BlockedSiteLog {
    static let maxSites = 50
    static let maxHostsPerSite = 5
    static let attemptInterval: TimeInterval = 60
    static let retention: TimeInterval = 7 * 24 * 3600

    private struct Entry {
        var hosts: [String]
        var count: Int
        var lastBlockedAt: Date
        var lastCountedAt: Date
    }

    private var entries: [String: Entry] = [:]

    var isEmpty: Bool { entries.isEmpty }

    mutating func record(_ hostname: String, at now: Date) {
        let host = DomainName.normalize(hostname)
        guard !host.isEmpty else { return }
        let site = DomainName.site(of: host)
        if var entry = entries[site] {
            if now.timeIntervalSince(entry.lastCountedAt) >= Self.attemptInterval {
                entry.count += 1
                entry.lastCountedAt = now
            }
            entry.lastBlockedAt = now
            entry.hosts = Array(([host] + entry.hosts.filter { $0 != host }).prefix(Self.maxHostsPerSite))
            entries[site] = entry
        } else {
            entries[site] = Entry(hosts: [host], count: 1, lastBlockedAt: now, lastCountedAt: now)
        }
        dropExpired(now: now)
        while entries.count > Self.maxSites,
              let oldest = entries.min(by: { $0.value.lastBlockedAt < $1.value.lastBlockedAt })?.key {
            entries.removeValue(forKey: oldest)
        }
    }

    /// 新策略到达时调用：家长已经处理过的网址（放行、设成约定时间或任何时候都不行）立刻让出
    /// 名额；一个网站下的网址都处理完了，整条移除。
    mutating func prune(keeping needsApproval: (String) -> Bool, now: Date) {
        for (site, entry) in entries {
            let pending = entry.hosts.filter(needsApproval)
            if pending.isEmpty {
                entries.removeValue(forKey: site)
            } else if pending != entry.hosts {
                entries[site]?.hosts = pending
            }
        }
        dropExpired(now: now)
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    /// 最近被挡的在前，上报给服务端
    var requests: [WebFilterAccessRequest] {
        entries
            .map { WebFilterAccessRequest(domain: $0.key, lastBlockedAt: $0.value.lastBlockedAt, count: $0.value.count, hosts: $0.value.hosts) }
            .sorted { $0.lastBlockedAt == $1.lastBlockedAt ? $0.domain < $1.domain : $0.lastBlockedAt > $1.lastBlockedAt }
    }

    private mutating func dropExpired(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.lastBlockedAt) < Self.retention }
    }
}

struct WebFilterPolicySnapshot: Codable, Equatable {
    /// 4：加入按对象关联的每周开放计划。
    /// 5："只放名单里的"不再挡系统服务和 BigDaddy 自己（服务端只对 5 及以上开放这个模式）。
    static let schemaVersion = 5

    let schemaVersion: Int
    let enabled: Bool
    let revision: Int64
    let blockedDomains: [WebFilterRule]
    let mode: WebFilterMode
    let allowedDomains: [WebFilterRule]
    let appRules: [AppNetworkRule]
    let weeklyPlans: [WeeklyAccessPlan]
    let weeklyPlansBlockedUntilEpochMillis: Int64?
    let temporaryAllowedUntilEpochMillis: Int64?
    let managementHost: String?
    let managementAppIdentifier: String?
    let appliedAt: Date

    /// blockedDomains 的预归一化索引。**不参与编码，也不参与相等判断**——它完全由
    /// blockedDomains 决定，是同一份数据的另一种摆法，编进 vendorConfiguration 只会
    /// 让线上格式凭空多出一份冗余，参与 == 则会让"同样的规则"因为索引内部顺序不同
    /// 而判成不等（那会把 reloadPolicy 末尾的 `policy == nextPolicy` 守卫弄坏）。
    /// 所以 CodingKeys 里没有它，== 也是手写的。
    private let alwaysBlockedMatcher: DomainMatcher
    private let entertainmentMatcher: DomainMatcher
    private let allowedMatcher: DomainMatcher

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, enabled, revision, blockedDomains, mode, allowedDomains, appRules,
             weeklyPlans, weeklyPlansBlockedUntilEpochMillis, temporaryAllowedUntilEpochMillis, managementHost, managementAppIdentifier, appliedAt
    }

    init(
        configuration: WebFilterConfiguration,
        isDeviceBound: Bool,
        managementHost: String? = nil,
        managementAppIdentifier: String? = nil,
        appliedAt: Date = Date()
    ) {
        self.schemaVersion = Self.schemaVersion
        self.enabled = isDeviceBound && configuration.enabled
        self.revision = configuration.revision
        self.blockedDomains = configuration.blockedDomains
        self.mode = configuration.mode
        self.allowedDomains = configuration.allowedDomains
        self.appRules = configuration.appRules
        self.weeklyPlans = configuration.weeklyPlans
        self.weeklyPlansBlockedUntilEpochMillis = configuration.weeklyPlansBlockedUntilEpochMillis
        self.temporaryAllowedUntilEpochMillis = configuration.temporaryAllowedUntilEpochMillis
        self.managementHost = managementHost
        self.managementAppIdentifier = managementAppIdentifier
        self.appliedAt = appliedAt
        self.alwaysBlockedMatcher = DomainMatcher(rules: configuration.blockedDomains.filter { $0.category != "ENTERTAINMENT" })
        self.entertainmentMatcher = DomainMatcher(rules: configuration.blockedDomains.filter { $0.category == "ENTERTAINMENT" })
        self.allowedMatcher = DomainMatcher(rules: configuration.allowedDomains)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        revision = try container.decode(Int64.self, forKey: .revision)
        blockedDomains = try container.decode([WebFilterRule].self, forKey: .blockedDomains)
        mode = try container.decodeIfPresent(WebFilterMode.self, forKey: .mode) ?? .blockSelected
        allowedDomains = try container.decodeIfPresent([WebFilterRule].self, forKey: .allowedDomains) ?? []
        appRules = try container.decodeIfPresent([AppNetworkRule].self, forKey: .appRules) ?? []
        weeklyPlans = try container.decodeIfPresent([WeeklyAccessPlan].self, forKey: .weeklyPlans) ?? []
        weeklyPlansBlockedUntilEpochMillis = try container.decodeIfPresent(Int64.self, forKey: .weeklyPlansBlockedUntilEpochMillis)
        temporaryAllowedUntilEpochMillis = try container.decodeIfPresent(Int64.self, forKey: .temporaryAllowedUntilEpochMillis)
        managementHost = try container.decodeIfPresent(String.self, forKey: .managementHost)
        managementAppIdentifier = try container.decodeIfPresent(String.self, forKey: .managementAppIdentifier)
        appliedAt = try container.decode(Date.self, forKey: .appliedAt)
        alwaysBlockedMatcher = DomainMatcher(rules: blockedDomains.filter { $0.category != "ENTERTAINMENT" })
        entertainmentMatcher = DomainMatcher(rules: blockedDomains.filter { $0.category == "ENTERTAINMENT" })
        allowedMatcher = DomainMatcher(rules: allowedDomains)
    }

    static func == (lhs: WebFilterPolicySnapshot, rhs: WebFilterPolicySnapshot) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.enabled == rhs.enabled
            && lhs.revision == rhs.revision
            && lhs.blockedDomains == rhs.blockedDomains
            && lhs.mode == rhs.mode
            && lhs.allowedDomains == rhs.allowedDomains
            && lhs.appRules == rhs.appRules
            && lhs.weeklyPlans == rhs.weeklyPlans
            && lhs.weeklyPlansBlockedUntilEpochMillis == rhs.weeklyPlansBlockedUntilEpochMillis
            && lhs.temporaryAllowedUntilEpochMillis == rhs.temporaryAllowedUntilEpochMillis
            && lhs.managementHost == rhs.managementHost
            && lhs.managementAppIdentifier == rhs.managementAppIdentifier
            && lhs.appliedAt == rhs.appliedAt
    }

    var requiresKnownHostname: Bool { enabled && mode == .allowSelected }

    func permitsManagementConnection(hostname: String, isManagementApp: Bool) -> Bool {
        guard enabled, mode == .allowSelected,
              let managementHost else { return false }
        return isManagementApp && DomainName.normalize(hostname) == DomainName.normalize(managementHost)
    }

    /// 时间约定进行中：「约好的时间里才可以」的网站和 AGREEMENT 档的软件放行
    func isTemporarilyAllowed(at now: Date) -> Bool {
        temporaryAllowedUntilEpochMillis.map { now.timeIntervalSince1970 * 1000 < Double($0) } ?? false
    }

    func isAllowed(planId: String?, at now: Date) -> Bool {
        if let blockedUntil = weeklyPlansBlockedUntilEpochMillis,
           blockedUntil == -1 || now.timeIntervalSince1970 * 1000 < Double(blockedUntil) { return false }
        if isTemporarilyAllowed(at: now) { return true }
        return weeklyPlans.first { $0.id == planId }?.isOpen(at: now) ?? false
    }

    func nextReevaluation(after now: Date) -> Date? {
        guard enabled else { return nil }
        var dates = weeklyPlans.compactMap { $0.nextBoundary(after: now) }
        for deadline in [temporaryAllowedUntilEpochMillis, weeklyPlansBlockedUntilEpochMillis].compactMap({ $0 }) {
            let date = Date(timeIntervalSince1970: Double(deadline) / 1000)
            if date > now { dates.append(date) }
        }
        return dates.min()
    }

    /// 软件规则的结论。系统程序和 BigDaddy 自己永远不受软件规则约束（服务端也会拒绝这类规则，
    /// 这里是执行端的兜底）。
    ///
    /// 系统服务和 BigDaddy 自己还按"随时可以联网"对待：不受"名单之外都打不开"约束，家长
    /// 明确列出的「任何时候都不行」「约好的时间里才可以」照样拦。少了这一条，一开"只放名单
    /// 里的"，DNS、iCloud、系统更新、推送、时间同步连同 BigDaddy 自己的更新全被挡掉——名单里
    /// 的网站也因为解析不了域名而打不开。Safari 不在此列，见 AppIdentity.isSystemService。
    func appVerdict(for identity: AppIdentity?, at now: Date = Date()) -> AppNetworkVerdict {
        guard enabled, let identity else { return .none }
        if identity.isSystemService || identity.isBigDaddy { return .bypass }
        guard !identity.isPlatformBinary,
              !identity.signingIdentifier.hasPrefix("vip.bigdaddy."),
              let rule = appRules.first(where: { $0.matches(identity) }) else { return .none }
        switch rule.access {
        case .never: return .block
        case .agreement: return isAllowed(planId: rule.weeklyPlanId, at: now) ? .bypass : .block
        case .always: return .bypass
        }
    }

    /// 判定顺序（app_network_rules_spec.md §2.4）：任何时候都不行的网站 → 软件不能联网 →
    /// 约好的时间里才可以的网站 → 软件随时可以联网 → 随时可以的网站 → 名单之外的默认值。
    /// 网站「任何时候都不行」排在软件规则之前：家长明确说了不行的网站，不能因为某个软件
    /// 被设成随时可以联网就被绕过。
    func blocks(hostname: String, identity: AppIdentity? = nil, at now: Date = Date()) -> Bool {
        guard enabled else { return false }
        let candidate = DomainName.normalize(hostname)
        if alwaysBlockedMatcher.matches(candidate) { return true }
        let app = appVerdict(for: identity, at: now)
        if app == .block { return true }
        if entertainmentMatcher.matches(candidate) {
            let matching = blockedDomains.first { rule in
                rule.category == "ENTERTAINMENT" && DomainMatcher(rules: [rule]).matches(candidate)
            }
            return !isAllowed(planId: matching?.weeklyPlanId, at: now)
        }
        if app == .bypass { return false }
        return mode == .allowSelected && !allowedMatcher.matches(candidate)
    }

    /// 只有白名单外的普通域名才值得请求家长允许。始终禁止和限时娱乐网站保留各自的规则，
    /// 不能混进“需要允许”的列表，免得家长一键把安全例外加回白名单。
    func needsParentApproval(hostname: String) -> Bool {
        guard enabled, mode == .allowSelected else { return false }
        let candidate = DomainName.normalize(hostname)
        if alwaysBlockedMatcher.matches(candidate) || entertainmentMatcher.matches(candidate) {
            return false
        }
        return !allowedMatcher.matches(candidate)
    }
}

/// 域名黑名单的匹配索引：**规则侧的归一化只在策略构造时做一次**。
///
/// 为什么值得单独立一个类型：`blocks(hostname:)` 由 FilterDataProvider.handleNewFlow
/// 逐条连接调用，是全项目唯一频率没有上限的路径（这台机器上**所有**程序的每一条新
/// 连接都从那里过），而 reloadPolicy 还会拿跟踪表里最多 2048 条流各调一次。原先的写法
/// 在这条路径上对**每条规则**重算一遍 `DomainName.normalize(rule.domain)`——三次字符串
/// 堆分配——再拼一次 `".\(blocked)"` 又一次分配，可规则侧的结果是常量，策略不变它就
/// 不会变。每条连接 × 每条规则 4 次分配，全部是白烧的。
///
/// 顺带把线性扫描换成 Set 精确匹配；子域仍然只能逐条比后缀，但那部分规则通常更少，
/// 而且后缀字符串已经预先拼好了前导点。
struct DomainMatcher {
    /// 精确匹配的域名（已归一化）。注意**所有**规则都进这里，不只是 includeSubdomains
    /// 为 false 的那些——原实现对每条规则都先试一次全等，行为要一致。
    private let exact: Set<String>
    /// 需要连子域一起匹配的规则，已经预先拼好前导点（".example.com"）。
    private let dottedSuffixes: [String]

    init(rules: [WebFilterRule]) {
        var exact: Set<String> = []
        var dottedSuffixes: [String] = []
        for rule in rules {
            let domain = DomainName.normalize(rule.domain)
            exact.insert(domain)
            if rule.includeSubdomains {
                dottedSuffixes.append(".\(domain)")
            }
        }
        self.exact = exact
        self.dottedSuffixes = dottedSuffixes
    }

    /// candidate 必须是**已经过 DomainName.normalize** 的主机名。
    func matches(_ candidate: String) -> Bool {
        if exact.contains(candidate) { return true }
        return dottedSuffixes.contains { candidate.hasSuffix($0) }
    }
}

/// 一条**已经在跟踪**的连接，在策略刚刚变化之后该不该被就地掐断。
///
/// 单独抽出来不是为了复用——只有 FilterDataProvider.reloadPolicy 一个调用点——而是因为
/// 它是"家长把限制打开的那一秒，浏览器里已经开着的 YouTube 还能不能继续看"的全部判据，
/// 而那个调用点整个建立在 NEFilterSocketFlow 上，在测试里造不出来。判据留在这里才测得到。
///
/// 前提是这条流当初真的被跟踪过——也就是限制打开**之前**过滤器就已经在跑。provider 只
/// 看得到自己启动之后新建的流，系统不会把已存在的 socket 补送给它，也没有任何 API 能事后
/// 枚举或掐断它们。这就是 WebFilterController.shouldRunContentFilter 必须只看"设备已绑定"
/// 的原因，两处要一起看才完整。
enum WebFilterFlowDisposition {
    static func shouldTerminate(
        hostname: String?,
        isLikelyQUIC: Bool,
        isManagementApp: Bool = false,
        identity: AppIdentity? = nil,
        under policy: WebFilterPolicySnapshot,
        at now: Date = Date()
    ) -> Bool {
        if let hostname {
            if policy.permitsManagementConnection(hostname: hostname, isManagementApp: isManagementApp) {
                return false
            }
            return policy.blocks(hostname: hostname, identity: identity, at: now)
        }
        // 判不出主机名时，软件规则仍然能下结论：游戏的裸 IP / 自定义 UDP 连接正是靠这里管住的。
        switch policy.appVerdict(for: identity, at: now) {
        case .block: return true
        // 软件放行仍须遵守已列出的网站限制；没有网站限制时保留其 QUIC 联网能力。
        case .bypass: return isLikelyQUIC && !policy.blockedDomains.isEmpty
        case .none: break
        }
        // 判不出主机名的 QUIC。这些流多半是在策略还没启用时放行的（那期间我们不掐 QUIC，
        // 见 FilterDataProvider.handleOutboundData），限制一旦启用就必须一并掐掉，否则
        // 浏览器会一直复用它们绕过限制——正是"新标签也照样能看"的那条通道。
        return policy.requiresKnownHostname || (policy.enabled && isLikelyQUIC)
    }
}

enum DomainName {
    /// 主域名要多取一级的后缀：国家二级域，以及谁都能在下面开站的托管平台。
    /// 与 dashboard 的 blockedSites.ts、iPhone 的 WebsiteAccess 是同一份清单，三端一起改。
    static let multiLabelSuffixes: Set<String> = [
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        "com.hk", "com.tw", "org.tw", "edu.tw", "co.jp", "ne.jp", "or.jp", "co.kr", "or.kr",
        "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "edu.au", "com.sg", "edu.sg",
        "github.io", "gitlab.io", "vercel.app", "netlify.app", "pages.dev", "web.app", "firebaseapp.com",
        "herokuapp.com", "blogspot.com", "wordpress.com",
    ]

    /// 具体网址归到哪个网站（主域名）。IP 地址没有主域名可言，原样返回。
    static func site(of value: String) -> String {
        let host = normalize(value)
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if host.contains(":") || (labels.count == 4 && labels.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            return host
        }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        return labels.suffix(multiLabelSuffixes.contains(lastTwo) ? 3 : 2).joined(separator: ".")
    }

    static func normalize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutTrailingDot = trimmed.last == "." ? String(trimmed.dropLast()) : trimmed
        return withoutTrailingDot.lowercased()
    }
}

enum WebFilterPolicyTransport {
    static let policyDataKey = "BigDaddyWebFilterPolicyData"

    static func vendorConfiguration(for policy: WebFilterPolicySnapshot) throws -> [String: Any] {
        [policyDataKey: try encoder.encode(policy)]
    }

    static func policy(from vendorConfiguration: [String: Any]?) -> WebFilterPolicySnapshot? {
        guard let data = vendorConfiguration?[policyDataKey] as? Data else { return nil }
        return try? decoder.decode(WebFilterPolicySnapshot.self, from: data)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

struct WebFilterProviderAcknowledgement: Codable, Equatable {
    let policySchemaVersion: Int?
    let appliedRevision: Int64
    let ruleCount: Int
    let blockedDomains: [WebFilterRule]
    let mode: WebFilterMode
    let allowedDomains: [WebFilterRule]
    let allowedRuleCount: Int
    let appRules: [AppNetworkRule]
    let weeklyPlans: [WeeklyAccessPlan]
    let weeklyPlansBlockedUntilEpochMillis: Int64?
    let temporaryAllowedUntilEpochMillis: Int64?
    let accessRequests: [WebFilterAccessRequest]
    let appActivity: [AppNetworkActivity]
    let enforcementEnabled: Bool
    let appliedAt: Date
    /// **provider 进程自身的启动时刻**，与 appliedAt 是两件不同的事，别混用。
    ///
    /// appliedAt 每次重新应用策略都会刷新，因此它证明不了"provider 进程没重启过"——主 App
    /// 每次启动都会无条件重写一次 vendorConfiguration（见 WebFilterController.enableContentFilter），
    /// provider 收到 KVO 就 reloadPolicy 并发一份 appliedAt=now 的新回执。拿 appliedAt 去判断
    /// 进程存活，结论会**恒为否**。
    ///
    /// 这个字段只在 provider 进程构造时取一次值、此后再不改变，正好回答"这个 provider 进程
    /// 是什么时候起来的"——也就是 WebFilterController.extensionSurvivedGap 真正需要的信号。
    ///
    /// 可选是为了容忍版本错位：主 App 与系统扩展在更新期间可能短暂不同版本，旧 provider 发来
    /// 的回执没有这个字段，解码成 nil ⇒ 调用方按"问不出来"处理，而不是误判成"没存活"。
    let providerStartedAt: Date?
    /// 本扩展在"只放名单里的"时放过系统服务和 BigDaddy 自己。新扩展恒为 true；它存在的意义
    /// 是让旧扩展露馅——旧扩展会照抄主 App 送来的 schema 号，却写不出这个字段。
    let exemptsSystemServices: Bool

    private enum CodingKeys: String, CodingKey {
        case policySchemaVersion, appliedRevision, ruleCount, blockedDomains, mode, allowedDomains,
             allowedRuleCount, appRules, weeklyPlans, weeklyPlansBlockedUntilEpochMillis,
             temporaryAllowedUntilEpochMillis, accessRequests, appActivity,
             enforcementEnabled, appliedAt, providerStartedAt, exemptsSystemServices
    }

    init(
        policy: WebFilterPolicySnapshot,
        accessRequests: [WebFilterAccessRequest] = [],
        appActivity: [AppNetworkActivity] = [],
        appliedAt: Date = Date(),
        providerStartedAt: Date? = nil
    ) {
        policySchemaVersion = policy.schemaVersion
        appliedRevision = policy.revision
        ruleCount = policy.blockedDomains.count + policy.allowedDomains.count
        blockedDomains = policy.blockedDomains
        mode = policy.mode
        allowedDomains = policy.allowedDomains
        allowedRuleCount = policy.allowedDomains.count
        appRules = policy.appRules
        weeklyPlans = policy.weeklyPlans
        weeklyPlansBlockedUntilEpochMillis = policy.weeklyPlansBlockedUntilEpochMillis
        temporaryAllowedUntilEpochMillis = policy.temporaryAllowedUntilEpochMillis
        self.accessRequests = accessRequests
        self.appActivity = appActivity
        enforcementEnabled = policy.enabled
        self.appliedAt = appliedAt
        self.providerStartedAt = providerStartedAt
        exemptsSystemServices = true
    }

    /// 主 App 和系统扩展可能在更新期间短暂错位。旧扩展没有白名单字段时，按既有黑名单
    /// 语义补齐，保住策略回执；白名单能力仍由 policySchemaVersion=0 让服务端安全地拒绝。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var reportedSchema = try container.decodeIfPresent(Int.self, forKey: .policySchemaVersion)
        // 旧扩展会照抄主 App 送来的 schema 号，按它写不出的字段把能力降回去：
        // 白名单仍会挡系统服务的报 4，读不懂每周计划的报 3。
        exemptsSystemServices = try container.decodeIfPresent(Bool.self, forKey: .exemptsSystemServices) ?? false
        if (reportedSchema ?? 0) >= 5 && !exemptsSystemServices { reportedSchema = 4 }
        if (reportedSchema ?? 0) >= 4 && !container.contains(.weeklyPlans) { reportedSchema = 3 }
        policySchemaVersion = reportedSchema
        appliedRevision = try container.decode(Int64.self, forKey: .appliedRevision)
        ruleCount = try container.decode(Int.self, forKey: .ruleCount)
        blockedDomains = try container.decode([WebFilterRule].self, forKey: .blockedDomains)
        mode = try container.decodeIfPresent(WebFilterMode.self, forKey: .mode) ?? .blockSelected
        allowedDomains = try container.decodeIfPresent([WebFilterRule].self, forKey: .allowedDomains) ?? []
        allowedRuleCount = try container.decodeIfPresent(Int.self, forKey: .allowedRuleCount) ?? allowedDomains.count
        appRules = try container.decodeIfPresent([AppNetworkRule].self, forKey: .appRules) ?? []
        weeklyPlans = try container.decodeIfPresent([WeeklyAccessPlan].self, forKey: .weeklyPlans) ?? []
        weeklyPlansBlockedUntilEpochMillis = try container.decodeIfPresent(Int64.self, forKey: .weeklyPlansBlockedUntilEpochMillis)
        temporaryAllowedUntilEpochMillis = try container.decodeIfPresent(Int64.self, forKey: .temporaryAllowedUntilEpochMillis)
        accessRequests = try container.decodeIfPresent([WebFilterAccessRequest].self, forKey: .accessRequests) ?? []
        appActivity = try container.decodeIfPresent([AppNetworkActivity].self, forKey: .appActivity) ?? []
        enforcementEnabled = try container.decode(Bool.self, forKey: .enforcementEnabled)
        appliedAt = try container.decode(Date.self, forKey: .appliedAt)
        providerStartedAt = try container.decodeIfPresent(Date.self, forKey: .providerStartedAt)
    }

    func confirms(_ policy: WebFilterPolicySnapshot) -> Bool {
        appliedRevision == policy.revision
            && ruleCount == policy.blockedDomains.count + policy.allowedDomains.count
            && blockedDomains == policy.blockedDomains
            && mode == policy.mode
            && allowedDomains == policy.allowedDomains
            && allowedRuleCount == policy.allowedDomains.count
            && appRules == policy.appRules
            && weeklyPlans == policy.weeklyPlans
            && weeklyPlansBlockedUntilEpochMillis == policy.weeklyPlansBlockedUntilEpochMillis
            && temporaryAllowedUntilEpochMillis == policy.temporaryAllowedUntilEpochMillis
            && enforcementEnabled == policy.enabled
    }
}

// 回执此前经由 App Group 容器里的一个 json 传递，那条路在 root（provider）和登录用户
// （主 App）之间根本不通，已换成 XPC —— 原委见 WebFilterIPC.swift 顶部。

struct WebFilterStatusReport: Equatable {
    enum SystemExtensionState: String {
        case unavailable = "UNAVAILABLE"
        case activationRequested = "ACTIVATION_REQUESTED"
        case awaitingUserApproval = "AWAITING_USER_APPROVAL"
        case approved = "APPROVED"
        case restartRequired = "RESTART_REQUIRED"
        case failed = "FAILED"
        /// 扩展装好也批准过了，但系统里的内容过滤当前是关的——有人在「系统设置 →
        /// 登录项与扩展」或「网络 → 过滤器」里把它关掉了。必须和 unavailable
        /// （压根没装上）分开：前者是"被人关的、可以打开"，后者是"这台机器上没有"，
        /// 家长要做的事完全不同。
        case disabled = "DISABLED"
    }

    enum EnforcementState: String {
        case unknown = "UNKNOWN"
        case passThrough = "PASS_THROUGH"
        case enforcing = "ENFORCING"
    }

    let systemExtensionState: SystemExtensionState
    let policySchemaVersion: Int
    let enforcementState: EnforcementState
    let requestedRevision: Int64
    let appliedRevision: Int64
    let ruleCount: Int
    let allowedRuleCount: Int
    let accessRequests: [WebFilterAccessRequest]
    let appRuleCount: Int
    let appActivity: [AppNetworkActivity]
    let lastAppliedAt: Date?
    let error: String?
}
