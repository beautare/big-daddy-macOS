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

struct ClientConfig: Codable {
    var bound: Bool = false
    var configVersion: Int = 1
    var screenshotIntervalMins: Int = 5
    var telegramBotToken: String?
    var telegramChatId: String?
    var compressQuality: Double = 0.6
    var compressMaxWidth: Int = 1280
    var aiEnabled: Bool = false
    var allowScreenshotAiProcessing: Bool = false
    var exitPasswordHash: String?
    var heartbeatActiveSeconds: Int = 60
    var heartbeatIdleSeconds: Int = 900
    var idleThresholdSeconds: Int = 180
    var hasPendingCommand: Bool = false
}

final class BigDaddyClient {
    static var lastSharedInstance: BigDaddyClient?

    let baseURL = URL(string: Bundle.main.object(forInfoDictionaryKey: "BigDaddyAPIBaseURL") as? String ?? "http://localhost:8009/api/v1")!
    let identity: DeviceIdentity
    var config = ClientConfig()
    var lastHeartbeatDescription = "not sent"
    private var previousCrashAt: Date?

    init() {
        self.identity = IdentityStore.load()
        BigDaddyClient.lastSharedInstance = self
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
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            "hostname": Host.current().localizedName ?? "Mac",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        _ = try? await request(path: "/bigdaddy/client/register", method: "POST", body: body, signed: false)
    }

    func refreshConfig() async {
        guard let data = try? await request(path: "/bigdaddy/client/config", method: "GET", body: nil, signed: true),
              let response = try? JSONDecoder.bigDaddy.decode(ApiResponse<ClientConfig>.self, from: data) else { return }
        config = response.data
    }

    func sendHeartbeat(event: EventType) async {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let body: [String: Any] = [
            "appVersion": version,
            "eventType": event.rawValue,
            "lastHeartbeatAt": ISO8601DateFormatter().string(from: Date()),
            "lastScreenshotAt": NSNull(),
            "cpuUsage": 0,
            "memoryUsageMb": currentMemoryMb(),
            "activeAppName": NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
            "activeWindowTitle": "",
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

    func captureAndSendScreenshot(reason: String) async {
        guard let token = config.telegramBotToken, let chatId = config.telegramChatId, !token.isEmpty, !chatId.isEmpty else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return
        }
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else { return }
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
        await sendTelegramPhoto(jpeg, token: token, chatId: chatId, reason: reason)
    }

    func pollCommands() async {
        guard let data = try? await request(path: "/bigdaddy/client/commands?limit=10", method: "GET", body: nil, signed: true),
              let response = try? JSONDecoder.bigDaddy.decode(ApiResponse<[Command]>.self, from: data) else { return }
        for command in response.data where command.type == "TAKE_SCREENSHOT_NOW" {
            await captureAndSendScreenshot(reason: "command")
            await ack(commandId: command.commandId, status: "SUCCEEDED", message: "Screenshot command processed")
        }
    }

    func verifyExitPassword(_ value: String) -> Bool {
        guard config.exitPasswordHash != nil else { return true }
        return !value.isEmpty
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

    private func sendTelegramPhoto(_ data: Data, token: String, chatId: String, reason: String) async {
        let boundary = "BigDaddy-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.telegram.org/bot\(token)/sendPhoto")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.appendMultipartField(name: "chat_id", value: chatId, boundary: boundary)
        body.appendMultipartField(name: "caption", value: "BigDaddy screenshot: \(reason)", boundary: boundary)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"screenshot.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        _ = try? await URLSession.shared.data(for: request)
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

struct ApiResponse<T: Codable>: Codable {
    let code: Int
    let message: String
    let data: T
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
