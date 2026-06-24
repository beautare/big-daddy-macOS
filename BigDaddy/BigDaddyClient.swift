import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

enum EventType: String, Codable {
    case start = "START"
    case heartbeat = "HEARTBEAT"
    case idle = "IDLE"
    case resume = "RESUME"
    case shutdown = "SHUTDOWN"
    case forceKill = "FORCE_KILL"
}

struct DeviceIdentity {
    let fingerprint: String
    let secretHash: String
}

struct ClientConfig: Codable, Equatable {
    var bound: Bool = false
    var configVersion: Int = 1
    var screenshotIntervalMins: Int = 5
    var destinationEmail: String?
    var compressQuality: Double = 0.6
    var compressMaxWidth: Int = 1280
    var aiEnabled: Bool = false
    var allowScreenshotAiProcessing: Bool = false
    var exitPasswordHash: String?
    var heartbeatActiveSeconds: Int = 60
    var heartbeatIdleSeconds: Int = 900
    var idleThresholdSeconds: Int = 180
    var hasPendingCommand: Bool = false

    init() {
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bound = try container.decodeIfPresent(Bool.self, forKey: .bound) ?? false
        configVersion = try container.decodeIfPresent(Int.self, forKey: .configVersion) ?? 1
        screenshotIntervalMins = try container.decodeIfPresent(Int.self, forKey: .screenshotIntervalMins) ?? 5
        destinationEmail = try container.decodeIfPresent(String.self, forKey: .destinationEmail)
        compressQuality = try container.decodeIfPresent(Double.self, forKey: .compressQuality) ?? 0.6
        compressMaxWidth = try container.decodeIfPresent(Int.self, forKey: .compressMaxWidth) ?? 1280
        aiEnabled = try container.decodeIfPresent(Bool.self, forKey: .aiEnabled) ?? false
        allowScreenshotAiProcessing = try container.decodeIfPresent(Bool.self, forKey: .allowScreenshotAiProcessing) ?? false
        exitPasswordHash = try container.decodeIfPresent(String.self, forKey: .exitPasswordHash)
        heartbeatActiveSeconds = try container.decodeIfPresent(Int.self, forKey: .heartbeatActiveSeconds) ?? 60
        heartbeatIdleSeconds = try container.decodeIfPresent(Int.self, forKey: .heartbeatIdleSeconds) ?? 900
        idleThresholdSeconds = try container.decodeIfPresent(Int.self, forKey: .idleThresholdSeconds) ?? 180
        hasPendingCommand = try container.decodeIfPresent(Bool.self, forKey: .hasPendingCommand) ?? false
    }
}

final class BigDaddyClient {
    static var lastSharedInstance: BigDaddyClient?

    let baseURL = URL(string: Bundle.main.object(forInfoDictionaryKey: "BigDaddyAPIBaseURL") as? String ?? "http://localhost:8009/api/v1")!
    let identity: DeviceIdentity
    var config: ClientConfig
    var lastHeartbeatDescription = "not sent"
    var bindToken: String?
    private var previousCrashAt: Date?

    init() {
        self.identity = IdentityStore.load()
        self.config = ConfigStore.load() ?? ClientConfig()
        BigDaddyClient.lastSharedInstance = self
    }

    var configFilePath: String {
        ConfigStore.configFileURL.path
    }

    var hasScreenshotDestination: Bool {
        guard let email = config.destinationEmail else { return false }
        return !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isIdle: Bool {
        let idleSeconds = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
        return idleSeconds > Double(config.idleThresholdSeconds)
    }

    func prepareRuntime() {
        let lock = Self.lockFileURL
        if let data = try? Data(contentsOf: lock), let value = String(data: data, encoding: .utf8), let timestamp = TimeInterval(value) {
            previousCrashAt = Date(timeIntervalSince1970: timestamp)
        }
        try? FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(Date().timeIntervalSince1970)".data(using: .utf8)?.write(to: lock)
    }

    func consumePreviousCrash() -> Date? {
        let crash = previousCrashAt
        previousCrashAt = nil
        return crash
    }

    func register() async {
        let body: [String: Any] = [
            "deviceFingerprint": identity.fingerprint,
            "deviceSecretHash": identity.secretHash,
            "appVersion": Bundle.self.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            "hostname": Host.current().localizedName ?? "Mac",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        if let data = try? await request(path: "/bigdaddy/client/register", method: "POST", body: body, signed: false),
           let response = try? JSONDecoder.bigDaddy.decode(ApiResponse<DeviceResponse>.self, from: data) {
            self.bindToken = response.data.bindToken
        }
    }

    @discardableResult
    func refreshConfig() async -> Bool {
        guard let data = try? await request(path: "/bigdaddy/client/config", method: "GET", body: nil, signed: true),
              let response = try? JSONDecoder.bigDaddy.decode(ApiResponse<ClientConfig>.self, from: data) else { return false }
        let previous = config
        let remote = response.data
        if remote.bound {
            config = remote
            ConfigStore.save(config)
        } else if config.bound {
            config = ClientConfig()
            ConfigStore.save(config)
        } else {
            config.bound = false
            config.hasPendingCommand = false
        }
        return config != previous
    }

    func sendHeartbeat(event: EventType) async {
        let version = Bundle.self.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let activeApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let windowTitle = getActiveWindowTitle()
        let activeUrl = getActiveBrowserUrl(appName: activeApp)
        
        let body: [String: Any] = [
            "appVersion": version,
            "eventType": event.rawValue,
            "lastHeartbeatAt": ISO8601DateFormatter().string(from: Date()),
            "lastScreenshotAt": NSNull(),
            "cpuUsage": 0,
            "memoryUsageMb": currentMemoryMb(),
            "activeAppName": activeApp,
            "activeWindowTitle": windowTitle,
            "activeUrl": activeUrl,
            "previousCrashAt": previousCrashAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "reportedAt": ISO8601DateFormatter().string(from: Date()),
            "metadata": ["screenRecordingGranted": CGPreflightScreenCaptureAccess()]
        ]
        _ = try? await request(path: "/bigdaddy/client/heartbeat", method: "POST", body: body, signed: true)
        lastHeartbeatDescription = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    }

    func sendShutdownSync() {
        Task.detached {
            await self.sendHeartbeat(event: .shutdown)
            try? FileManager.default.removeItem(at: Self.lockFileURL)
        }
    }

    private var lastImagePixels: [UInt8]?

    func isImageSimilarToLast(cgImage: CGImage) -> Bool {
        let width = 8
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return false
        }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let lastPixels = lastImagePixels else {
            lastImagePixels = pixels
            return false
        }
        lastImagePixels = pixels
        
        var diffSum: Int = 0
        for i in 0..<pixels.count {
            diffSum += abs(Int(pixels[i]) - Int(lastPixels[i]))
        }
        let averageDiff = Double(diffSum) / Double(pixels.count)
        NSLog("BigDaddy: Screenshot similarity diff score = \(averageDiff)")
        return averageDiff < 8.0
    }

    func getActiveBrowserUrl(appName: String) -> String {
        var scriptString = ""
        if appName.contains("Google Chrome") || appName.contains("Chrome") {
            scriptString = """
            tell application "Google Chrome"
                if (count of windows) > 0 then
                    return URL of active tab of first window
                end if
            end tell
            return ""
            """
        } else if appName.contains("Safari") {
            scriptString = """
            tell application "Safari"
                if (count of windows) > 0 then
                    return URL of current tab of first window
                end if
            end tell
            return ""
            """
        } else {
            return ""
        }
        
        if let script = NSAppleScript(source: scriptString) {
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if error == nil {
                return result.stringValue ?? ""
            }
        }
        return ""
    }

    func getActiveWindowTitle() -> String {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return "" }
        let pid = frontApp.processIdentifier
        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        guard let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return "" }
        for info in windowListInfo {
            if let windowOwnerPID = info[kCGWindowOwnerPID as String] as? Int, windowOwnerPID == pid {
                if let layer = info[kCGWindowLayer as String] as? Int, layer == 0 {
                    if let title = info[kCGWindowName as String] as? String {
                        return title
                    }
                }
            }
        }
        return ""
    }

    func uploadScreenshot(imageData: Data, activeApp: String, windowTitle: String, activeUrl: String) async throws -> Data {
        let method = "POST"
        let boundary = "BigDaddy-Upload-\(UUID().uuidString)"
        var components = URLComponents(url: baseURL.appendingPathComponent("/bigdaddy/client/screenshot"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "activeAppName", value: activeApp),
            URLQueryItem(name: "activeWindowTitle", value: windowTitle.isEmpty ? nil : windowTitle),
            URLQueryItem(name: "activeUrl", value: activeUrl.isEmpty ? nil : activeUrl)
        ]
        
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(identity.fingerprint, forHTTPHeaderField: "X-Device-Fingerprint")
        
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let nonce = UUID().uuidString
        let pathWithQuery = url.path + (url.query.map { "?\($0)" } ?? "")
        let emptyHash = SHA256.hash(data: Data()).hex
        let canonical = "\(method)\n\(pathWithQuery)\n\(emptyHash)\n\(timestamp)\n\(nonce)"
        
        let key = SymmetricKey(data: identity.secretHash.data(using: .utf8)!)
        let signature = HMAC<SHA256>.authenticationCode(for: canonical.data(using: .utf8)!, using: key).data.base64URLEncodedString()
        
        request.setValue(timestamp, forHTTPHeaderField: "X-Device-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-Device-Nonce")
        request.setValue(signature, forHTTPHeaderField: "X-Device-Signature")
        
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"screenshot.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    func captureAndSendScreenshot(reason: String) async {
        guard hasScreenshotDestination else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return
        }
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else { return }
        
        if isImageSimilarToLast(cgImage: image) {
            NSLog("BigDaddy: Screenshot is similar to the last one, skip sending.")
            return
        }

        let bitmap = NSBitmapImageRep(cgImage: image)
        let width = CGFloat(config.compressMaxWidth)
        let scale = min(1, width / CGFloat(bitmap.pixelsWide))
        let targetSize = NSSize(width: CGFloat(bitmap.pixelsWide) * scale, height: CGFloat(bitmap.pixelsHigh) * scale)
        let nsImage = NSImage(size: targetSize)
        nsImage.lockFocus()
        NSImage(cgImage: image, size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)).draw(in: NSRect(origin: .zero, size: targetSize))
        nsImage.unlockFocus()
        
        guard let tiff = nsImage.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: config.compressQuality]) ?? Data()
        
        let activeApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let windowTitle = getActiveWindowTitle()
        let activeUrl = getActiveBrowserUrl(appName: activeApp)
        
        _ = try? await uploadScreenshot(imageData: jpeg, activeApp: activeApp, windowTitle: windowTitle, activeUrl: activeUrl)
    }

    func pollCommands() async {
        guard config.bound else { return }
        guard let data = try? await request(path: "/bigdaddy/client/commands?limit=10", method: "GET", body: nil, signed: true),
              let response = try? JSONDecoder.bigDaddy.decode(ApiResponse<[Command]>.self, from: data) else { return }
        for command in response.data where command.type == "TAKE_SCREENSHOT_NOW" {
            await captureAndSendScreenshot(reason: "command")
            await ack(commandId: command.commandId, status: "SUCCEEDED", message: "Screenshot command processed")
        }
    }

    func verifyExitPassword(_ value: String) async -> Bool {
        guard config.bound else {
            return true
        }
        guard config.exitPasswordHash != nil else {
            return true
        }
        let body: [String: Any] = [
            "exitPassword": value
        ]
        do {
            let data = try await request(path: "/bigdaddy/client/verify-exit", method: "POST", body: body, signed: true)
            if let response = try? JSONDecoder.bigDaddy.decode(ApiResponse<Bool>.self, from: data) {
                return response.data
            }
        } catch {
            NSLog("BigDaddy: verifyExitPassword request failed: \(error.localizedDescription)")
        }
        return false
    }

    func saveLocalDestinationEmail(_ email: String) {
        config.bound = false
        config.destinationEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        ConfigStore.save(config)
        
        Task {
            let body: [String: Any] = [
                "destinationEmail": config.destinationEmail ?? ""
            ]
            _ = try? await request(path: "/bigdaddy/client/config", method: "POST", body: body, signed: true)
        }
    }

    func clearLocalDestinationEmail() {
        config.destinationEmail = nil
        ConfigStore.save(config)
        
        Task {
            let body: [String: Any] = [
                "destinationEmail": ""
            ]
            _ = try? await request(path: "/bigdaddy/client/config", method: "POST", body: body, signed: true)
        }
    }

    static func sharedForceKillPing() {
        lastSharedInstance?.sendShutdownSync()
    }

    private func ack(commandId: String, status: String, message: String) async {
        let body: [String: Any] = [
            "status": status,
            "message": message,
            "completedAt": ISO8601DateFormatter().string(from: Date())
        ]
        _ = try? await request(path: "/bigdaddy/client/commands/\(commandId)/ack", method: "POST", body: body, signed: true)
    }

    private func request(path: String, method: String, body: [String: Any]?, signed: Bool) async throws -> Data {
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: baseURL.absoluteString + normalizedPath) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var bodyData = Data()
        if let body {
            bodyData = try JSONSerialization.data(withJSONObject: body)
            request.httpBody = bodyData
        }
        request.setValue(identity.fingerprint, forHTTPHeaderField: "X-Device-Fingerprint")
        if signed {
            let timestamp = String(Int(Date().timeIntervalSince1970))
            let nonce = UUID().uuidString
            let canonical = "\(method)\n\(url.path)\(url.query.map { "?\($0)" } ?? "")\n\(SHA256.hash(data: bodyData).hex)\n\(timestamp)\n\(nonce)"
            let key = SymmetricKey(data: identity.secretHash.data(using: .utf8)!)
            let signature = HMAC<SHA256>.authenticationCode(for: canonical.data(using: .utf8)!, using: key).data.base64URLEncodedString()
            request.setValue(timestamp, forHTTPHeaderField: "X-Device-Timestamp")
            request.setValue(nonce, forHTTPHeaderField: "X-Device-Nonce")
            request.setValue(signature, forHTTPHeaderField: "X-Device-Signature")
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private func currentMemoryMb() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1024.0 / 1024.0 : 0
    }

    private static var lockFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BigDaddy/runtime.lock")
    }
}

enum ConfigStore {
    static var configFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BigDaddy/config.json")
    }

    static func load() -> ClientConfig? {
        guard let data = try? Data(contentsOf: configFileURL) else { return nil }
        return try? JSONDecoder.bigDaddy.decode(ClientConfig.self, from: data)
    }

    static func save(_ config: ClientConfig) {
        do {
            try FileManager.default.createDirectory(at: configFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configFileURL, options: .atomic)
        } catch {
            NSLog("BigDaddy failed to save config: \(error.localizedDescription)")
        }
    }
}

struct ApiResponse<T: Codable>: Codable {
    let code: Int
    let message: String
    let data: T
}

struct DeviceResponse: Codable {
    let deviceFingerprint: String
    let deviceName: String?
    let status: String
    let latestEvent: String?
    let appVersion: String?
    let lastHeartbeatAt: Date?
    let lastScreenshotAt: Date?
    let boundAt: Date?
    let bindToken: String?
}

struct Command: Codable {
    let commandId: String
    let type: String
}

enum IdentityStore {
    static func load() -> DeviceIdentity {
        let secret = keychainValue(key: "deviceSecret") ?? UUID().uuidString + UUID().uuidString
        setKeychainValue(secret, key: "deviceSecret")
        let platform = IOPlatformUUID.read() ?? Host.current().localizedName ?? "BigDaddyMac"
        let fingerprint = SHA256.hash(data: platform.data(using: .utf8)!).hex
        let secretHash = SHA256.hash(data: secret.data(using: .utf8)!).hex
        return DeviceIdentity(fingerprint: fingerprint, secretHash: secretHash)
    }

    private static func keychainValue(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "BigDaddy",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func setKeychainValue(_ value: String, key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "BigDaddy",
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = value.data(using: .utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

enum IOPlatformUUID {
    static func read() -> String? {
        let task = Process()
        task.launchPath = "/usr/sbin/ioreg"
        task.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(separator: "\n").first { $0.contains("IOPlatformUUID") }?
            .split(separator: "\"").dropFirst(3).first.map(String.init)
    }
}

extension JSONDecoder {
    static var bigDaddy: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension SHA256.Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension HMAC<SHA256>.MAC {
    var data: Data { Data(self) }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }
}
