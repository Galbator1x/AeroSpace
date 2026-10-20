@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class PersistentFloatingGeometryTest: XCTestCase {
    func testNewWindowIDUsesDurableGeometryAndRejectsParkingCoordinates() throws {
        setUpWorkspacesForTests()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("geometry.json")
        let bounds = FloatingGeometry(x: 0, y: 0, width: 1920, height: 1080)
        let wanted = FloatingGeometry(x: 286, y: 49, width: 1116, height: 907)
        var store = try FloatingGeometryStore(url: url)
        try store.remember(wanted, for: "example.App", visibleBounds: bounds, parked: false)
        let corner = FloatingGeometry(x: 1919, y: 1079, width: 1116, height: 907)
        try store.remember(corner, for: "example.App", visibleBounds: bounds, parked: true)
        try store.remember(corner, for: "example.App", visibleBounds: bounds, parked: false)
        let reloaded = try FloatingGeometryStore(url: url)
        XCTAssertEqual(reloaded.geometry(for: "example.App"), wanted)
        XCTAssertEqual(reloaded.lookup("example.App", liveWindowCount: 0), .pending)
        XCTAssertEqual(reloaded.lookup("example.App", liveWindowCount: nil), .pending)
        XCTAssertEqual(reloaded.lookup("example.App", liveWindowCount: 1), .ready(wanted))
        XCTAssertEqual(reloaded.lookup("example.App", liveWindowCount: 2), .ambiguous)
        let newWindow = TestWindow.new(id: 9999, parent: Workspace.get(byName: "E").floatingWindowsContainer)
        prepareReopenedGeometry(wanted, for: newWindow)
        XCTAssertEqual(newWindow.pendingReopenedGeometry, wanted)
        XCTAssertEqual(newWindow.lastFloatingSize, wanted.size)
        XCTAssertEqual(newWindow.prevUnhiddenProportionalPositionInsideWorkspaceRect,
                       CGPoint(x: 286.0 / 1920, y: 49.0 / 1080))
    }

    func testRestoreClampsToCurrentMonitor() {
        let wanted = FloatingGeometry(x: 1800, y: 900, width: 1400, height: 900)
        let monitor = FloatingGeometry(x: 0, y: 34, width: 1000, height: 700)
        XCTAssertEqual(wanted.clamped(to: monitor), monitor)
    }
    func testEarlyFrameIsAwaitedAndFailuresPreservePendingRestore() async throws {
        setUpWorkspacesForTests()
        let window = TestWindow.new(id: 9999, parent: Workspace.get(byName: "E").floatingWindowsContainer)
        let wanted = FloatingGeometry(x: 286, y: 49, width: 1116, height: 907)
        prepareReopenedGeometry(wanted, for: window)
        let failed = try await applyPreparedGeometryBeforeFocus(to: window) { _ in false }
        XCTAssertFalse(failed)
        XCTAssertNotNil(window.prevUnhiddenProportionalPositionInsideWorkspaceRect)
        do {
            _ = try await applyPreparedGeometryBeforeFocus(to: window) { _ in throw CancellationError() }
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertNotNil(window.prevUnhiddenProportionalPositionInsideWorkspaceRect)
        var completed = false
        let applied = try await applyPreparedGeometryBeforeFocus(to: window) { geometry in
            XCTAssertEqual(geometry, wanted)
            XCTAssertNotNil(window.prevUnhiddenProportionalPositionInsideWorkspaceRect)
            await Task.yield()
            completed = true
            return true
        }
        XCTAssertTrue(applied)
        XCTAssertTrue(completed)
        XCTAssertNil(window.prevUnhiddenProportionalPositionInsideWorkspaceRect)
    }

}
