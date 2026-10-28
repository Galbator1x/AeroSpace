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

    func testLayoutDoesNotReplaceQueuedRestoreWithPositionOnlyRelocation() async throws {
        let workspace = Workspace.get(byName: "hidden-layout")
        let window = DeferredRevealWindow(id: 9971, workspace: workspace)
        let target = FloatingGeometry(x: 100, y: 50, width: 900, height: 700)
        prepareReopenedGeometry(target, for: window)
        window.setReopenedGeometryFrame(target)
        XCTAssertFalse(workspace.isVisible)
        try await workspace.layoutWorkspace()
        window.drainFrames()
        let actual = try await window.getAxRect(.cancellable)
        XCTAssertEqual(actual.map(FloatingGeometry.init), target)
        XCTAssertNotNil(window.pendingReopenedGeometry)
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
        try await redetected.unhideFromCorner()
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
        let bounds = workspace.workspaceMonitorInfo.rect
        window.prevUnhiddenProportionalPositionInsideWorkspaceRect = CGPoint(x: 100 / bounds.width, y: 50 / bounds.height)
        prepareReopenedGeometry(FloatingGeometry(x: 200, y: 80, width: 1100, height: 800), for: window)
        XCTAssertFalse(invalidateAmbiguousReopenedGeometry([window], windowCount: 1))
        XCTAssertNotNil(window.pendingReopenedGeometry)
        XCTAssertTrue(invalidateAmbiguousReopenedGeometry([window, other], windowCount: 2))
        XCTAssertNil(window.pendingReopenedGeometry)
        XCTAssertFalse(other.needsReopenedGeometryDecision)
        XCTAssertTrue(window.isHiddenInCorner)
        try await window.unhideFromCorner()
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

    func testCancelledQueuedRevealStillUnhidesWindow() async throws {
        let workspace = Workspace.get(byName: "Q")
        let window = DeferredRevealWindow(id: 9999, workspace: workspace)
        let bounds = workspace.workspaceMonitorInfo.rect
        window.prevUnhiddenProportionalPositionInsideWorkspaceRect = CGPoint(x: 100 / bounds.width, y: 50 / bounds.height)
        prepareReopenedGeometry(FloatingGeometry(x: 200, y: 80, width: 1100, height: 800), for: window)
        try await window.unhideFromCorner()
        invalidateAmbiguousReopenedGeometry([window], windowCount: 1, appCount: 2)
        window.drainFrames()
        try await window.unhideFromCorner()
        window.drainFrames()
        XCTAssertEqual(FloatingGeometry(window.rect), FloatingGeometry(x: 100, y: 50, width: 600, height: 400))
        XCTAssertNil(window.pendingReopenedGeometry)
    }

    func testAmbiguityCancelsAwaitedRevealAndFallsBackToReturnPosition() async throws {
        let workspace = Workspace.get(byName: "Q")
        let window = DeferredRevealWindow(id: 9999, workspace: workspace)
        let bounds = workspace.workspaceMonitorInfo.rect
        let position = CGPoint(x: 100 / bounds.width, y: 50 / bounds.height)
        window.prevUnhiddenProportionalPositionInsideWorkspaceRect = position
        window.blockReveal = true
        prepareReopenedGeometry(FloatingGeometry(x: 200, y: 80, width: 1100, height: 800), for: window)
        let reveal = Task { @MainActor in try await window.unhideFromCorner() }
        try await window.started.await(.cancellable)
        XCTAssertEqual(window.prevUnhiddenProportionalPositionInsideWorkspaceRect, position)
        invalidateAmbiguousReopenedGeometry([window], windowCount: 1, appCount: 2)
        try await reveal.value
        window.drainFrames()
        XCTAssertEqual(FloatingGeometry(window.rect), FloatingGeometry(x: 100, y: 50, width: 600, height: 400))
        XCTAssertNil(window.pendingReopenedGeometry)
        XCTAssertFalse(window.isHiddenInCorner)
    }

    func testParentCancellationKeepsRevealReturnPosition() async throws {
        let workspace = Workspace.get(byName: "Q")
        let window = DeferredRevealWindow(id: 9999, workspace: workspace)
        let bounds = workspace.workspaceMonitorInfo.rect
        let position = CGPoint(x: 100 / bounds.width, y: 50 / bounds.height)
        window.prevUnhiddenProportionalPositionInsideWorkspaceRect = position
        window.blockReveal = true
        prepareReopenedGeometry(FloatingGeometry(x: 200, y: 80, width: 1100, height: 800), for: window)
        let reveal = Task { @MainActor in try await window.unhideFromCorner() }
        try await window.started.await(.cancellable)
        reveal.cancel()
        do {
            try await reveal.value
            XCTFail("Expected parent cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(window.prevUnhiddenProportionalPositionInsideWorkspaceRect, position)
        window.cancelReopenedGeometry()
        try await window.unhideFromCorner()
        window.drainFrames()
        XCTAssertEqual(FloatingGeometry(window.rect), FloatingGeometry(x: 100, y: 50, width: 600, height: 400))
    }

    func testSuccessfulRevealClearsReturnPositionAfterAcknowledgement() async throws {
        let workspace = Workspace.get(byName: "Q")
        let window = DeferredRevealWindow(id: 9999, workspace: workspace)
        let position = CGPoint(x: 0.1, y: 0.1)
        window.prevUnhiddenProportionalPositionInsideWorkspaceRect = position
        window.blockReveal = true
        let wanted = FloatingGeometry(x: 200, y: 80, width: 1100, height: 800)
        prepareReopenedGeometry(wanted, for: window)
        let reveal = Task { @MainActor in try await window.unhideFromCorner() }
        try await window.started.await(.cancellable)
        XCTAssertEqual(window.prevUnhiddenProportionalPositionInsideWorkspaceRect, position)
        await window.release.signalToAll()
        try await reveal.value
        XCTAssertEqual(FloatingGeometry(window.rect), wanted)
        XCTAssertFalse(window.isHiddenInCorner)
    }

    func testOverlappingRevealsCancelAllSupersededWrites() async throws {
        let workspace = Workspace.get(byName: "Q")
        let window = DeferredRevealWindow(id: 9999, workspace: workspace)
        let bounds = workspace.workspaceMonitorInfo.rect
        let position = CGPoint(x: 100 / bounds.width, y: 50 / bounds.height)
        window.prevUnhiddenProportionalPositionInsideWorkspaceRect = position
        window.blockReveal = true
        prepareReopenedGeometry(FloatingGeometry(x: 200, y: 80, width: 1100, height: 800), for: window)
        let first = Task { @MainActor in try await window.unhideFromCorner() }
        try await window.started.await(.cancellable)
        let second = Task { @MainActor in try await window.unhideFromCorner() }
        try await window.secondStarted.await(.cancellable)
        try await first.value
        XCTAssertEqual(window.prevUnhiddenProportionalPositionInsideWorkspaceRect, position)
        invalidateAmbiguousReopenedGeometry([window], windowCount: 1, appCount: 2)
        try await second.value
        await window.release.signalToAll()
        window.drainFrames()
        XCTAssertEqual(window.successfulApplications, 0)
        XCTAssertEqual(FloatingGeometry(window.rect), FloatingGeometry(x: 100, y: 50, width: 600, height: 400))
    }

    func testNewParkingInvalidatesSuspendedReveal() async throws {
        let workspace = Workspace.get(byName: "Q")
        let window = DeferredRevealWindow(id: 9999, workspace: workspace)
        window.prevUnhiddenProportionalPositionInsideWorkspaceRect = CGPoint(x: 0.1, y: 0.1)
        window.blockReveal = true
        prepareReopenedGeometry(FloatingGeometry(x: 200, y: 80, width: 1100, height: 800), for: window)
        let reveal = Task { @MainActor in try await window.unhideFromCorner() }
        try await window.started.await(.cancellable)
        window.cancelReopenedGeometryReveal()
        let newerPosition = CGPoint(x: 0.2, y: 0.3)
        window.prevUnhiddenProportionalPositionInsideWorkspaceRect = newerPosition
        try await reveal.value
        await window.release.signalToAll()
        window.drainFrames()
        XCTAssertEqual(window.prevUnhiddenProportionalPositionInsideWorkspaceRect, newerPosition)
        XCTAssertEqual(window.successfulApplications, 0)
        XCTAssertEqual(window.rect.topLeftX, 1919)
        window.cancelReopenedGeometry()
    }

    func testExplicitCommandDoesNotRunOldRevealFallback() async throws {
        let workspace = Workspace.get(byName: "Q")
        let window = DeferredRevealWindow(id: 9999, workspace: workspace)
        window.prevUnhiddenProportionalPositionInsideWorkspaceRect = CGPoint(x: 0.1, y: 0.1)
        window.blockReveal = true
        prepareReopenedGeometry(FloatingGeometry(x: 200, y: 80, width: 1100, height: 800), for: window)
        let reveal = Task { @MainActor in try await window.unhideFromCorner() }
        try await window.started.await(.cancellable)
        let command = parseCommand("fullscreen --window-id 9999 on", allowExecAndForget: true, allowEval: true).cmdOrNil!
        _ = await command.run(.defaultEnv, .emptyStdin)
        let fullscreen = FloatingGeometry(x: 0, y: 0, width: 1920, height: 1080)
        window.setAxFrame(fullscreen.point, fullscreen.size)
        try await reveal.value
        window.drainFrames()
        XCTAssertEqual(FloatingGeometry(window.rect), fullscreen)
        XCTAssertEqual(window.successfulApplications, 0)
    }

}

private final class DeferredRevealWindow: Window {
    var rect = Rect(topLeftX: 1919, topLeftY: 1079, width: 600, height: 400)
    private var frames: [(job: RunLoopJob, point: CGPoint?, size: CGSize?)] = []
    var blockReveal = false
    let started = AwaitableOneTimeBroadcastLatch()
    let secondStarted = AwaitableOneTimeBroadcastLatch()
    private var applicationsStarted = 0
    var successfulApplications = 0
    let release = AwaitableOneTimeBroadcastLatch()

    @MainActor init(id: UInt32, workspace: Workspace) {
        super.init(id: id, TestApp.shared, lastFloatingSize: CGSize(width: 600, height: 400),
            parent: workspace.floatingWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        TestApp.shared._windows.append(self)
    }

    override func setAxFrame(_ point: CGPoint?, _ size: CGSize?) {
        frames.last?.job.cancel()
        let job = RunLoopJob(.cancellable)
        frames.append((job, point, size))
        if size != nil { reopenedGeometryFrameJob = job }
    }

    @MainActor func drainFrames() {
        for frame in frames where !frame.job.isCancelled {
            if let point = frame.point {
                rect.topLeftX = point.x
                rect.topLeftY = point.y
            }
            if let size = frame.size {
                rect.width = size.width
                rect.height = size.height
            }
        }
        frames = []
    }

    @MainActor override func setAxFrameBeforeFocus(_ geometry: FloatingGeometry) async throws -> Bool {
        if blockReveal {
            applicationsStarted += 1
            await started.signalToAll()
            if applicationsStarted == 2 { await secondStarted.signalToAll() }
            try await release.await(.cancellable)
        }
        successfulApplications += 1
        setAxFrame(geometry.point, geometry.size)
        if blockReveal { drainFrames() }
        return geometry.approximatelyEquals(FloatingGeometry(rect))
    }

    @MainActor override func getAxRect(_ cm: CancellationMode) async throws -> Rect? { rect }
    override var isHiddenInCorner: Bool { prevUnhiddenProportionalPositionInsideWorkspaceRect != nil }
}
