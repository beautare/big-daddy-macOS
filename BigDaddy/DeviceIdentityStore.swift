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

enum IdentityStore {
    static func load() -> DeviceIdentity {
        print("BigDaddy: IdentityStore.load started")
        // 不再依赖 Keychain 持久化：开发构建每次 swift build / Xcode 运行的代码签名都不同，
        // 读不到上一个构建创建的 Keychain 条目会静默重造 secret；设备一旦绑定，重造即永久
        // 验签失败（后端拒绝已绑定设备换钥）。改用 Application Support 下 0600 权限的文件
        // 持久化，跨构建、跨签名都稳定。
        let secret: String
        if let fromFile = fileSecret() {
            secret = fromFile
        } else {
            secret = generateSecret()
            saveFileSecret(secret)
        }
        print("BigDaddy: deviceSecret ready")
        let platform = IOPlatformUUID.read() ?? Host.current().localizedName ?? "BigDaddyMac"
        print("BigDaddy: platform UUID read complete")
        let fingerprint = SHA256.hash(data: platform.data(using: .utf8)!).hex
        let secretHash = SHA256.hash(data: secret.data(using: .utf8)!).hex
        print("BigDaddy: IdentityStore.load completed, fingerprint: \(fingerprint)")
        return DeviceIdentity(fingerprint: fingerprint, secretHash: secretHash)
    }

    /// 生成密码学安全的 32 字节随机 deviceSecret（用 SecRandomCopyBytes，而不是拼接
    /// 两个 UUID 字符串这种可预测格式），十六进制编码后作为 String 存入文件，
    /// 与现有消费方（SHA256 取 secretHash、HMAC 签名）完全兼容，无需改动下游逻辑。
    private static func generateSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            // 极罕见的降级路径：系统随机数生成失败时退回旧格式，保证指纹生成流程
            // 不会因此崩溃或阻塞设备绑定。
            return UUID().uuidString + UUID().uuidString
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static var secretFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BigDaddy/device-secret")
    }

    private static func fileSecret() -> String? {
        guard let raw = try? String(contentsOf: secretFileURL, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func saveFileSecret(_ secret: String) {
        try? FileManager.default.createDirectory(
            at: secretFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? secret.data(using: .utf8)?.write(to: secretFileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretFileURL.path)
    }
}

enum IOPlatformUUID {
    static func read() -> String? {
        print("BigDaddy: IOPlatformUUID.read started")
        let task = Process()
        task.launchPath = "/usr/sbin/ioreg"
        task.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            print("BigDaddy: ioreg task launched successfully")
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let uuid = output.split(separator: "\n").first { $0.contains("IOPlatformUUID") }?
                .split(separator: "\"").dropFirst(3).first.map(String.init)
            print("BigDaddy: ioreg task read completed, uuid is nil: \(uuid == nil)")
            return uuid
        } catch {
            print("BigDaddy Error: Failed to run ioreg task: \(error.localizedDescription)")
            return nil
        }
    }
}
