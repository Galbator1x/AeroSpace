import AppKit
import Common

@MainActor private var reopenedGeometryStore: FloatingGeometryStore? = {
    // Keep AeroSpace's automatic geometry separate from the user's explicit dotfiles saves.
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/dotfiles/aerospace-floating-geometry.json")
    do { return try FloatingGeometryStore(url: url, writer: FloatingGeometryWriter(url: url)) }
    catch { reportFloatingGeometryError("geometry store load failed: \(error)"); return nil }
}()

extension FloatingGeometry {
    init(_ rect: Rect) {
        self.init(x: rect.topLeftX, y: rect.topLeftY, width: rect.width, height: rect.height)
    }
    var point: CGPoint { CGPoint(x: x, y: y) }
    var size: CGSize { CGSize(width: width, height: height) }
}

@MainActor
func prepareReopenedGeometry(_ geometry: FloatingGeometry, for window: Window) {
    guard let workspace = window.nodeWorkspace, window.isFloating, geometry.isValid else { return }
    let bounds = workspace.workspaceMonitor.rect
    let target = geometry.clamped(to: FloatingGeometry(bounds))
    window.reopenedGeometryRetryCount = 0
    window.pendingReopenedGeometry = target
    window.lastFloatingSize = target.size
    window.prevUnhiddenProportionalPositionInsideWorkspaceRect = CGPoint(
        x: (target.x - bounds.topLeftX) / bounds.width,
        y: (target.y - bounds.topLeftY) / bounds.height,
    )
}

@MainActor
func applyPreparedGeometryBeforeFocus(
    to window: Window,
    apply: @MainActor (FloatingGeometry) async throws -> Bool
) async throws -> Bool {
    guard let target = window.pendingReopenedGeometry else { return false }
    let applied = try await apply(target)
    // Don't clear a newer restore that was prepared while the AX operation was suspended.
    if applied && window.pendingReopenedGeometry == target {
        window.prevUnhiddenProportionalPositionInsideWorkspaceRect = nil
    }
    return applied
}

extension MacWindow {
    @MainActor
    func restoreReopenedGeometry(restore: Bool) async throws {
        guard let bundle = macApp.rawAppBundleId else {
            needsReopenedGeometryDecision = false
            return
        }
        let kind = try await macApp.getAxUiElementWindowType(windowId, getWindowLevel(for: windowId), .cancellable)
        supportsReopenedGeometry = kind == .window
        guard supportsReopenedGeometry,
              !MacApp.allAppsMap.values.contains(where: { $0 !== macApp && $0.rawAppBundleId == bundle }) else {
            needsReopenedGeometryDecision = false
            return
        }
        guard restore, isFloating else { needsReopenedGeometryDecision = false; return }
        let liveCount = try await macApp.getAxWindowsCount(.cancellable)
        guard MacWindow.allWindowsMap[windowId] === self, isFloating else { return }
        let lookup = reopenedGeometryStore?.lookup(bundle, liveWindowCount: liveCount) ?? .ready(nil)
        switch lookup {
            case .pending:
                return // Retry during layout; never overwrite saved geometry before deciding.
            case .ambiguous:
                needsReopenedGeometryDecision = false
                do { try reopenedGeometryStore?.forget(bundle) }
                catch { reportFloatingGeometryError("geometry store forget failed: \(error)") }
            case .ready(let geometry):
                needsReopenedGeometryDecision = false
                guard let geometry else { return }
                prepareReopenedGeometry(geometry, for: self)
                if nodeWorkspace?.isVisible == true || macApp.nsApp.isActive {
                    _ = try await applyPreparedGeometryBeforeFocus(to: self) { target in
                        try await self.macApp.setAxFrameBeforeFocus(self.windowId, geometry: target)
                    }
                }
                if nodeWorkspace?.isVisible == true { unhideFromCorner() }
        }
    }

    @MainActor
    func rememberReopenedGeometry(_ rect: Rect, beforeParking: Bool = false) {
        guard !needsReopenedGeometryDecision, supportsReopenedGeometry, isFloating, !isFullscreen,
              let bundle = macApp.rawAppBundleId, let workspace = nodeWorkspace,
              !MacApp.allAppsMap.values.contains(where: { $0 !== macApp && $0.rawAppBundleId == bundle }) else { return }
        if macApp.managedWindowCount > 1 {
            do { try reopenedGeometryStore?.forget(bundle) }
            catch { reportFloatingGeometryError("geometry store forget failed: \(error)") }
            return
        }
        guard macApp.managedWindowCount == 1, !isHiddenInCorner,
              beforeParking || workspace.isVisible else { return }
        let geometry = FloatingGeometry(rect)
        guard confirmReopenedGeometry(geometry, for: self, visible: workspace.isVisible) else {
            if workspace.isVisible, let pending = pendingReopenedGeometry {
                setAxFrame(pending.point, pending.size)
            }
            return
        }
        do {
            try reopenedGeometryStore?.remember(geometry, for: bundle,
                visibleBounds: FloatingGeometry(workspace.workspaceMonitor.rect), parked: false)
        } catch { reportFloatingGeometryError("geometry store save failed: \(error)") }
    }
}

@MainActor
func confirmReopenedGeometry(_ actual: FloatingGeometry, for window: Window, visible: Bool) -> Bool {
    guard let pending = window.pendingReopenedGeometry else { return true }
    if actual.approximatelyEquals(pending) {
        window.pendingReopenedGeometry = nil
        return true
    }
    guard visible else { return false }
    if window.reopenedGeometryRetryCount < 3 {
        window.reopenedGeometryRetryCount += 1
        return false
    }
    // Applications may enforce their own minimum size or position. Stop fighting them.
    window.cancelReopenedGeometry()
    return true
}

extension Window {
    @MainActor
    func cancelReopenedGeometry() {
        guard pendingReopenedGeometry != nil else { return }
        pendingReopenedGeometry = nil
        prevUnhiddenProportionalPositionInsideWorkspaceRect = nil
    }
}

@MainActor
func flushReopenedGeometry() {
    reopenedGeometryStore?.flush()
}
