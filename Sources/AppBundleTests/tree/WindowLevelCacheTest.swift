@testable import AppBundle
import XCTest

@MainActor
final class WindowLevelCacheTest: XCTestCase {
    func testConcurrentCacheMissesResumeAllWaiters() async throws {
        let started = AwaitableOneTimeBroadcastLatch()
        let release = AwaitableOneTimeBroadcastLatch()
        let firstId: UInt32 = 0xffffffe1
        let secondId: UInt32 = 0xffffffe2
        let first = Task { @MainActor in
            try await getWindowLevel(for: firstId, .cancellable) {
                await started.signalToAll()
                try! await release.await(.nonCancellable)
                return [firstId: .normalWindow, secondId: .alwaysOnTopWindow]
            }
        }
        try await started.await(.cancellable)
        let second = Task { @MainActor in
            try await getWindowLevel(for: secondId, .cancellable) {
                XCTFail("Concurrent cache misses must share the in-flight computation")
                return [:]
            }
        }
        // Drain the main-actor queue while computation is held, so the second request joins it.
        await Task { @MainActor in }.value
        await release.signalToAll()
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult, .normalWindow)
        XCTAssertEqual(secondResult, .alwaysOnTopWindow)
    }
}
