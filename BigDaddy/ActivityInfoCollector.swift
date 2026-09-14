import Foundation

/// 浏览器无响应时仍要发送存活信号。超时后最多保留一个后台采集，不堆积 Apple Event。
final class ActivityInfoCollector: @unchecked Sendable {
    typealias Info = (title: String, url: String)
    private let lock = NSLock()
    private var running = false
    private var generation = 0
    private var pending: CheckedContinuation<Info, Never>?

    func capture(timeout: TimeInterval = 1, collect: @escaping @Sendable () -> Info) async -> Info {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !running else {
                lock.unlock()
                continuation.resume(returning: ("", ""))
                return
            }
            running = true
            generation += 1
            let currentGeneration = generation
            pending = continuation
            lock.unlock()
            let deadline = DispatchWorkItem { [self] in finish(("", ""), completed: false, generation: currentGeneration) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
            DispatchQueue.global(qos: .utility).async { [self] in
                let info = collect()
                deadline.cancel()
                finish(info, completed: true, generation: currentGeneration)
            }
        }
    }

    private func finish(_ info: Info, completed: Bool, generation: Int) {
        lock.lock()
        guard self.generation == generation else {
            lock.unlock()
            return
        }
        let continuation = pending
        pending = nil
        if completed { running = false }
        lock.unlock()
        continuation?.resume(returning: info)
    }
}
