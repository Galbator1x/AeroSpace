import Foundation

// The lock protects pending snapshots; only the serial queue touches the file.
final class FloatingGeometryWriter: @unchecked Sendable {
    private let url: URL
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: [String: FloatingGeometry]?
    private var scheduled = false
    private var retryAfter: TimeInterval = 0
    private var reportedFailure = false // Only accessed on the serial queue.

    init(url: URL, queue: DispatchQueue = DispatchQueue(label: "aerospace.floating-geometry", qos: .utility)) {
        self.url = url
        self.queue = queue
    }

    func submit(_ entries: [String: FloatingGeometry]) {
        lock.lock()
        pending = entries
        scheduleIfNeeded()
        lock.unlock()
    }

    func retryIfNeeded() {
        lock.lock()
        scheduleIfNeeded()
        lock.unlock()
    }

    // Called with the lock held. A failed write is retried on a later event, at most once per second.
    private func scheduleIfNeeded() {
        guard pending != nil, !scheduled, ProcessInfo.processInfo.systemUptime >= retryAfter else { return }
        scheduled = true
        queue.async { self.drain() }
    }

    func flush() {
        queue.sync { self.drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            let snapshot = pending
            pending = nil
            if snapshot == nil { scheduled = false }
            lock.unlock()
            guard let snapshot else { return }
            do {
                try FloatingGeometryStore.write(snapshot, to: url)
                reportedFailure = false
                lock.lock()
                retryAfter = 0
                lock.unlock()
            } catch {
                lock.lock()
                if pending == nil { pending = snapshot }
                scheduled = false
                retryAfter = ProcessInfo.processInfo.systemUptime + 1
                lock.unlock()
                if !reportedFailure { reportFloatingGeometryError("geometry store save failed: \(error)") }
                reportedFailure = true
                return
            }
        }
    }
}
