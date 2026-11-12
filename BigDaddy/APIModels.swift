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

struct ApiResponse<T: Codable>: Codable {
    let code: Int
    let message: String
    let data: T
}

/// 只含业务码和消息的响应信封：错误响应的 data 为 null，无法按 ApiResponse<T> 解析
struct ApiEnvelope: Codable {
    let code: Int
    let message: String
}

/// HTTP 状态码非 2xx 时 request() 抛出的错误：区分"服务器明确拒绝"和"网络传输失败"，
/// 前者（尤其 401）不该被调用方当成可重试的临时故障静默吞掉。
struct BigDaddyAPIError: LocalizedError {
    let statusCode: Int
    let serverMessage: String?
    /// 服务端 Retry-After 响应头（秒）。限流过滤器在 429 时会带上它，补发循环据此
    /// 自适应节奏，而不是靠客户端写死的常量猜服务端还剩多少额度。
    let retryAfterSeconds: Int?

    init(statusCode: Int, serverMessage: String?, retryAfterSeconds: Int? = nil) {
        self.statusCode = statusCode
        self.serverMessage = serverMessage
        self.retryAfterSeconds = retryAfterSeconds
    }

    var errorDescription: String? { serverMessage ?? "HTTP \(statusCode)" }
    /// 签名接口返回 401 只可能是 BigDaddyDeviceAuthService 里的认证失败
    /// （设备未注册/无 secret/签名不对/时间戳超窗），语义上等价于 register() 报告的
    /// credentialsValid=false，都意味着本机手上的凭据当下用不了。
    var isAuthFailure: Bool { statusCode == 401 }
    /// 被限流。与网络故障的处理必须分开：事件照样要进补发队列（不能丢），但重试节奏
    /// 得听服务端的，而且不该像网络恢复那样立刻重试。
    var isRateLimited: Bool { statusCode == 429 }
}

/// 携带后端 message 的业务错误，让弹窗能直接展示真实原因而不是笼统的"绑定码无效"
struct BigDaddyServerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
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
    let credentialsValid: Bool?
    let bound: Bool?
}

struct Command: Codable {
    let commandId: String
    let type: String
}

struct HeartbeatResponse: Codable {
    let syncToken: String?
    let hasPendingCommand: Bool?
}

struct ScreenshotUploadResponse: Codable {
    let delivered: Bool?
    let emailStatus: String?
    let telegramStatus: String?
    let reason: String?
}
