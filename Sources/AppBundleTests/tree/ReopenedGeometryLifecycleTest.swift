@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class ReopenedGeometryLifecycleTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetClosedWindowsCache()
    }

    func testRedetectionRetainsPendingRestore() async throws {
        let workspace = Workspace.get(byName: "Q")
        let original = TestWindow.new(id: 1943, parent: workspace.floatingWindowsContainer)
        original.lastFloatingSize = CGSize(width: 600, height: 400)
        original.prevUnhiddenProportionalPositionInsideWorkspaceRect = CGPoint(x: 0.1, y: 0.1)
        let wanted = FloatingGeometry(x: 200, y: 80, width: 1100, height: 800)
        prepareReopenedGeometry(wanted, for: original)
        var restore = original.reopenedGeometry.pending!
        restore.retryCount = 2
        original.reopenedGeometry = .pending(restore)
        cacheClosedWindowIfNeeded()
        original.unbindFromParent()
        TestApp.shared.windows = []

        let redetected = TestWindow.new(id: 1943, parent: workspace.floatingWindowsContainer,
            rect: Rect(topLeftX: 1919, topLeftY: 1079, width: 600, height: 400))
        let restored = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: redetected)
        XCTAssertTrue(restored)
        XCTAssertEqual(redetected.pendingReopenedGeometry, wanted)
        XCTAssertEqual(redetected.reopenedGeometry.pending?.retryCount, 2)
        redetected.unhideFromCorner()
        let actual = try await redetected.getAxRect(.nonCancellable)
        XCTAssertEqual(actual.map(FloatingGeometry.init), wanted)
    }

    func testFullscreenCancelsPendingRestore() async throws {
        let window = TestWindow.new(id: 9999, parent: Workspace.get(byName: "Q").floatingWindowsContainer)
        prepareReopenedGeometry(FloatingGeometry(x: 200, y: 80, width: 1100, height: 800), for: window)
        let command = parseCommand("fullscreen --window-id 9999 on", allowExecAndForget: true, allowEval: true).cmdOrNil!
        let result = await command.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode.rawValue, 0)
        XCTAssertTrue(window.isFullscreen)
        XCTAssertNil(window.pendingReopenedGeometry)
    }

    func testMouseCancelsDeferredDecision() async throws {
        let window = TestWindow.new(id: 9999, parent: Workspace.get(byName: "E").floatingWindowsContainer)
        _ = try await decideReopenedGeometry(for: window) { .pending }
        XCTAssertTrue(window.needsReopenedGeometryDecision)
        window.cancelReopenedGeometry()
        var lookedUp = false
        _ = try await decideReopenedGeometry(for: window) {
            lookedUp = true
            return .ready(FloatingGeometry(x: 200, y: 80, width: 1100, height: 800))
        }
        XCTAssertFalse(lookedUp)
        XCTAssertFalse(window.needsReopenedGeometryDecision)
        XCTAssertNil(window.pendingReopenedGeometry)
    }

    func testMouseCancelsSuspendedDecision() async throws {
        let window = TestWindow.new(id: 9999, parent: Workspace.get(byName: "E").floatingWindowsContainer)
        let decision = try await decideReopenedGeometry(for: window) {
            await Task.yield()
            window.cancelReopenedGeometry()
            return .ready(FloatingGeometry(x: 200, y: 80, width: 1100, height: 800))
        }
        XCTAssertNil(decision)
        XCTAssertFalse(window.needsReopenedGeometryDecision)
        XCTAssertNil(window.pendingReopenedGeometry)
    }

    func testAmbiguityCancelsTargetsAndPreservesActualParkingGeometry() async throws {
        let workspace = Workspace.get(byName: "Q")
        let window = TestWindow.new(id: 9999, parent: workspace.floatingWindowsContainer,
            rect: Rect(topLeftX: 1919, topLeftY: 1079, width: 600, height: 400))
        let other = TestWindow.new(id: 9998, parent: workspace.floatingWindowsContainer)
        window.lastFloatingSize = CGSize(width: 600, height: 400)
        let bounds = workspace.workspaceMonitor.rect
        window.prevUnhiddenProportionalPositionInsideWorkspaceRect = CGPoint(x: 100 / bounds.width, y: 50 / bounds.height)
        prepareReopenedGeometry(FloatingGeometry(x: 200, y: 80, width: 1100, height: 800), for: window)
        XCTAssertFalse(invalidateAmbiguousReopenedGeometry([window], windowCount: 1))
        XCTAssertNotNil(window.pendingReopenedGeometry)
        XCTAssertTrue(invalidateAmbiguousReopenedGeometry([window, other], windowCount: 2))
        XCTAssertNil(window.pendingReopenedGeometry)
        XCTAssertFalse(other.needsReopenedGeometryDecision)
        XCTAssertTrue(window.isHiddenInCorner)
        window.unhideFromCorner()
        let actual = try await window.getAxRect(.nonCancellable)
        XCTAssertEqual(actual.map(FloatingGeometry.init), FloatingGeometry(x: bounds.topLeftX + 100, y: bounds.topLeftY + 50, width: 600, height: 400))
    }

    func testDuplicateAppInstanceCancelsRestore() {
        let window = TestWindow.new(id: 9999, parent: Workspace.get(byName: "Q").floatingWindowsContainer)
        prepareReopenedGeometry(FloatingGeometry(x: 200, y: 80, width: 1100, height: 800), for: window)
        XCTAssertTrue(invalidateAmbiguousReopenedGeometry([window], windowCount: 1, appCount: 2))
        XCTAssertNil(window.pendingReopenedGeometry)
    }

    func testCancelledApplicationCannotCompleteANewerIdenticalRestore() async throws {
        let window = TestWindow.new(id: 9999, parent: Workspace.get(byName: "Q").floatingWindowsContainer)
        let wanted = FloatingGeometry(x: 200, y: 80, width: 1100, height: 800)
        prepareReopenedGeometry(wanted, for: window)
        let parked = CGPoint(x: 0.1, y: 0.1)
        let applied = try await applyPreparedGeometryBeforeFocus(to: window) { _ in
            window.cancelReopenedGeometry()
            prepareReopenedGeometry(wanted, for: window)
            window.prevUnhiddenProportionalPositionInsideWorkspaceRect = parked
            return true
        }
        XCTAssertFalse(applied)
        XCTAssertEqual(window.prevUnhiddenProportionalPositionInsideWorkspaceRect, parked)
        XCTAssertEqual(window.pendingReopenedGeometry, wanted)
    }

    func testCacheRetainsCancelledDecision() async throws {
        let workspace = Workspace.get(byName: "Q")
        let original = TestWindow.new(id: 1943, parent: workspace.floatingWindowsContainer)
        original.cancelReopenedGeometry()
        cacheClosedWindowIfNeeded()
        original.unbindFromParent()
        TestApp.shared.windows = []
        let redetected = TestWindow.new(id: 1943, parent: workspace.floatingWindowsContainer)
        _ = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: redetected)
        XCTAssertFalse(redetected.needsReopenedGeometryDecision)
    }

    func testMouseCancelsInFlightApplicationAndQueuedFrame() async throws {
        let window = TestWindow.new(id: 9999, parent: Workspace.get(byName: "Q").floatingWindowsContainer)
        prepareReopenedGeometry(FloatingGeometry(x: 200, y: 80, width: 1100, height: 800), for: window)
        let frameJob = RunLoopJob(.cancellable)
        window.reopenedGeometryFrameJob = frameJob
        let applied = try await applyPreparedGeometryBeforeFocus(to: window) { _ in
            window.cancelReopenedGeometry()
            try Task.checkCancellation()
            XCTFail("Cancelled AX work must stop")
            return true
        }
        XCTAssertFalse(applied)
        XCTAssertTrue(frameJob.isCancelled)
        XCTAssertNil(window.reopenedGeometryApplication)
        XCTAssertNil(window.pendingReopenedGeometry)
    }

    func testRestoreCancellationDoesNotSwallowParentCancellation() async throws {
        let window = TestWindow.new(id: 9999, parent: Workspace.get(byName: "Q").floatingWindowsContainer)
        prepareReopenedGeometry(FloatingGeometry(x: 200, y: 80, width: 1100, height: 800), for: window)
        var parent: Task<Bool, any Error>?
        parent = Task { @MainActor in
            try await applyPreparedGeometryBeforeFocus(to: window) { _ in
                parent!.cancel()
                window.cancelReopenedGeometry()
                try Task.checkCancellation()
                return true
            }
        }
        do {
            _ = try await parent!.value
            XCTFail("Expected parent cancellation")
        } catch is CancellationError {}
        XCTAssertNil(window.reopenedGeometryApplication)
    }
}
