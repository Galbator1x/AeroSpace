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
