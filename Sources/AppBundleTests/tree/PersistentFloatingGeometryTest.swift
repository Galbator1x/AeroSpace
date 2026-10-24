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
        XCTAssertNil(newWindow.lastFloatingSize)
        XCTAssertNil(newWindow.prevUnhiddenProportionalPositionInsideWorkspaceRect)
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
        XCTAssertNotNil(window.pendingReopenedGeometry)
        do {
            _ = try await applyPreparedGeometryBeforeFocus(to: window) { _ in throw CancellationError() }
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertNotNil(window.pendingReopenedGeometry)
        var completed = false
        let applied = try await applyPreparedGeometryBeforeFocus(to: window) { geometry in
            XCTAssertEqual(geometry, wanted)
            XCTAssertNotNil(window.pendingReopenedGeometry)
            await Task.yield()
            completed = true
            return true
        }
        XCTAssertTrue(applied)
        XCTAssertTrue(completed)
        XCTAssertNil(window.prevUnhiddenProportionalPositionInsideWorkspaceRect)
    }

    func testApplicationAdjustedFrameStopsRetrying() {
        setUpWorkspacesForTests()
        let window = TestWindow.new(id: 9999, parent: Workspace.get(byName: "E").floatingWindowsContainer)
        let wanted = FloatingGeometry(x: 286, y: 49, width: 1116, height: 907)
        let adjusted = FloatingGeometry(x: 286, y: 49, width: 1200, height: 907)
        prepareReopenedGeometry(wanted, for: window)
        XCTAssertFalse(confirmReopenedGeometry(adjusted, for: window, visible: false))
        XCTAssertEqual(window.reopenedGeometry.pending?.retryCount, 0)
        for _ in 0..<3 {
            XCTAssertFalse(confirmReopenedGeometry(adjusted, for: window, visible: true))
        }
        XCTAssertTrue(confirmReopenedGeometry(adjusted, for: window, visible: true))
        XCTAssertNil(window.pendingReopenedGeometry)
        XCTAssertNil(window.prevUnhiddenProportionalPositionInsideWorkspaceRect)
        XCTAssertTrue(confirmReopenedGeometry(adjusted, for: window, visible: true))
    }

    func testQueuedPersistenceKeepsLatestSnapshotAndForget() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("geometry.json")
        let queue = DispatchQueue(label: "test.geometry-writer")
        let writer = FloatingGeometryWriter(url: url, queue: queue)
        var store = try FloatingGeometryStore(url: url, writer: writer)
        let bounds = FloatingGeometry(x: 0, y: 0, width: 1920, height: 1080)
        queue.suspend()
        do {
            defer { queue.resume() }
            for x in 0..<100 {
                try store.remember(FloatingGeometry(x: Double(x), y: 50, width: 1000, height: 800),
                                   for: "example.App", visibleBounds: bounds, parked: false)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(store.geometry(for: "example.App")?.x, 99)
        }
        writer.flush()
        XCTAssertEqual(try FloatingGeometryStore(url: url).geometry(for: "example.App"),
                       store.geometry(for: "example.App"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try store.forget("example.App")
        writer.flush()
        XCTAssertNil(try FloatingGeometryStore(url: url).geometry(for: "example.App"))
    }

    func testFailedQueuedWriteCanBeFlushedAfterRecovery() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A regular file where the parent directory should be forces the first write to fail.
        try Data().write(to: folder)
        let url = folder.appendingPathComponent("geometry.json")
        let writer = FloatingGeometryWriter(url: url)
        var store = try FloatingGeometryStore(url: url, writer: writer)
        let bounds = FloatingGeometry(x: 0, y: 0, width: 1920, height: 1080)
        let wanted = FloatingGeometry(x: 200, y: 80, width: 1000, height: 800)
        try store.remember(wanted, for: "example.App", visibleBounds: bounds, parked: false)
        writer.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.removeItem(at: folder)
        writer.flush()
        XCTAssertEqual(try FloatingGeometryStore(url: url).geometry(for: "example.App"), wanted)
    }

    func testUserManipulationCancelsPendingRestore() {
        setUpWorkspacesForTests()
        let window = TestWindow.new(id: 9999, parent: Workspace.get(byName: "E").floatingWindowsContainer)
        prepareReopenedGeometry(FloatingGeometry(x: 200, y: 80, width: 1000, height: 800), for: window)
        window.cancelReopenedGeometry()
        XCTAssertNil(window.pendingReopenedGeometry)
        XCTAssertNil(window.prevUnhiddenProportionalPositionInsideWorkspaceRect)
        let userFrame = FloatingGeometry(x: 300, y: 90, width: 1100, height: 800)
        XCTAssertTrue(confirmReopenedGeometry(userFrame, for: window, visible: true))
    }

    func testUnchangedGeometryRetriesAfterTemporaryWriteFailure() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder)
        let url = folder.appendingPathComponent("geometry.json")
        let queue = DispatchQueue(label: "test.geometry-retry")
        let writer = FloatingGeometryWriter(url: url, queue: queue)
        var store = try FloatingGeometryStore(url: url, writer: writer)
        let bounds = FloatingGeometry(x: 0, y: 0, width: 1920, height: 1080)
        let wanted = FloatingGeometry(x: 200, y: 80, width: 1000, height: 800)
        try store.remember(wanted, for: "example.App", visibleBounds: bounds, parked: false)
        queue.sync {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.removeItem(at: folder)
        try await Task.sleep(for: .milliseconds(1100))
        try store.remember(wanted, for: "example.App", visibleBounds: bounds, parked: false)
        queue.sync {}
        XCTAssertEqual(try FloatingGeometryStore(url: url).geometry(for: "example.App"), wanted)
    }

    func testPendingRestoreRebasesToAnotherMonitor() {
        setUpWorkspacesForTests()
        let window = TestWindow.new(id: 9999, parent: Workspace.get(byName: "E").floatingWindowsContainer)
        let wanted = FloatingGeometry(x: 286, y: 49, width: 1116, height: 907)
        prepareReopenedGeometry(wanted, for: window)
        var restore = window.reopenedGeometry.pending!
        restore.retryCount = 2
        window.reopenedGeometry = .pending(restore)
        let otherMonitor = FloatingGeometry(x: 1920, y: 0, width: 1280, height: 720)
        window.rebaseReopenedGeometry(to: otherMonitor)
        let target = FloatingGeometry(x: 2084, y: 0, width: 1116, height: 720)
        XCTAssertEqual(window.pendingReopenedGeometry, target)
        XCTAssertEqual(window.reopenedGeometry.pending?.bounds, otherMonitor)
        XCTAssertNil(window.lastFloatingSize)
        XCTAssertEqual(window.reopenedGeometry.pending?.retryCount, 0)
        XCTAssertNil(window.prevUnhiddenProportionalPositionInsideWorkspaceRect)
        XCTAssertTrue(confirmReopenedGeometry(target, for: window, visible: true))
        XCTAssertNil(window.reopenedGeometry.pending?.bounds)
    }

    func testMonitorRebaseDoesNotMarkVisibleWindowHidden() {
        setUpWorkspacesForTests()
        let window = TestWindow.new(id: 9999, parent: Workspace.get(byName: "E").floatingWindowsContainer)
        prepareReopenedGeometry(FloatingGeometry(x: 200, y: 80, width: 1000, height: 800), for: window)
        window.prevUnhiddenProportionalPositionInsideWorkspaceRect = nil
        window.rebaseReopenedGeometry(to: FloatingGeometry(x: -1920, y: -200, width: 1920, height: 1080))
        XCTAssertEqual(window.pendingReopenedGeometry,
                       FloatingGeometry(x: -1720, y: -120, width: 1000, height: 800))
        XCTAssertNil(window.prevUnhiddenProportionalPositionInsideWorkspaceRect)
        window.cancelReopenedGeometry()
        XCTAssertNil(window.reopenedGeometry.pending?.bounds)
    }

}
