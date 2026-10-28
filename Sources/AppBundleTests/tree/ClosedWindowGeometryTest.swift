@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class ClosedWindowGeometryTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetClosedWindowsCache()
    }

    func testRedetectionRestoresCornerPositionInsteadOfLearningParkingPosition() async throws {
        try await checkRedetection(earlySnapshot: false)
    }

    func testEarlierVisibleSnapshotDoesNotDiscardLaterHiddenPosition() async throws {
        try await checkRedetection(earlySnapshot: true)
    }

    func testRedetectionPreservesVisibleAndHiddenWorkspacesInMonitorTree() async throws {
        let visible = Workspace.get(byName: "visible")
        let hidden = Workspace.get(byName: "hidden")
        let original = TestWindow.new(id: 2011, parent: hidden.floatingWindowsContainer)
        let visibleWindow = TestWindow.new(id: 2012, parent: visible.floatingWindowsContainer)
        XCTAssertTrue(mainMonitorInfo.setVisibleWorkspace(visible))
        let target = FloatingGeometry(x: 100, y: 50, width: 600, height: 400)
        prepareReopenedGeometry(target, for: original)
        original.prevUnhiddenProportionalPositionInsideWorkspaceRect = CGPoint(x: 0.1, y: 0.2)
        cacheClosedWindowIfNeeded()
        let pending = original.reopenedGeometry
        original.unbindFromParent()
        TestApp.shared.windows = [visibleWindow]
        let redetected = TestWindow.new(id: 2011, parent: visible.floatingWindowsContainer)

        let restored = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: redetected)
        XCTAssertTrue(restored)
        XCTAssertTrue(redetected.nodeWorkspace === hidden)
        XCTAssertTrue(visibleWindow.nodeWorkspace === visible)
        XCTAssertTrue(mainMonitorInfo.visibleWorkspace === visible)
        XCTAssertTrue(visible.isVisible)
        XCTAssertFalse(hidden.isVisible)
        XCTAssertEqual(redetected.reopenedGeometry, pending)
        XCTAssertEqual(redetected.prevUnhiddenProportionalPositionInsideWorkspaceRect, CGPoint(x: 0.1, y: 0.2))
        XCTAssertTrue(hidden.parent === visible.parent)
    }

    private func checkRedetection(earlySnapshot: Bool) async throws {
        let workspace = Workspace.get(byName: "Q")
        let original = TestWindow.new(id: 1943, parent: workspace.floatingWindowsContainer)
        let position = CGPoint(x: 110.0 / 1710.0, y: 34.0 / 1107.0)
        if earlySnapshot { cacheClosedWindowIfNeeded() }
        original.prevUnhiddenProportionalPositionInsideWorkspaceRect = position
        original.lastFloatingSize = CGSize(width: 1345, height: 1054)
        let existing = TestWindow.new(id: 893, parent: workspace.floatingWindowsContainer)
        existing.prevUnhiddenProportionalPositionInsideWorkspaceRect = CGPoint(x: 0.1, y: 0.1)
        cacheClosedWindowIfNeeded()
        existing.prevUnhiddenProportionalPositionInsideWorkspaceRect = CGPoint(x: 0.2, y: 0.3)
        original.unbindFromParent()
        TestApp.shared.windows = [existing]

        let redetected = TestWindow.new(id: 1943, parent: workspace.floatingWindowsContainer)
        XCTAssertNil(redetected.prevUnhiddenProportionalPositionInsideWorkspaceRect)
        let restored = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: redetected)
        XCTAssertTrue(restored)
        XCTAssertEqual(redetected.prevUnhiddenProportionalPositionInsideWorkspaceRect, position)
        XCTAssertEqual(redetected.lastFloatingSize, CGSize(width: 1345, height: 1054))
        XCTAssertEqual(existing.prevUnhiddenProportionalPositionInsideWorkspaceRect, CGPoint(x: 0.2, y: 0.3))
    }
}
