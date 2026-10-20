import AppKit
import Common

@MainActor private var reopenedGeometryStore: FloatingGeometryStore? = {
    // Keep AeroSpace's automatic geometry separate from the user's explicit dotfiles saves.
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/dotfiles/aerospace-floating-geometry.json")
    do { return try FloatingGeometryStore(url: url) }
    catch { cornerTrace("geometry store load failed: \(error)"); return nil }
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
        guard isFloating, let bundle = macApp.rawAppBundleId else {
            needsReopenedGeometryDecision = false
            return
        }
        let kind = try await macApp.getAxUiElementWindowType(windowId, getWindowLevel(for: windowId), .cancellable)
        supportsReopenedGeometry = kind == .window
        guard supportsReopenedGeometry, isFloating,
              MacApp.allAppsMap.values.filter({ $0.rawAppBundleId == bundle }).count == 1 else {
            needsReopenedGeometryDecision = false
            return
        }
        guard restore else { needsReopenedGeometryDecision = false; return }
        let liveCount = try await macApp.getAxWindowsCount(.cancellable)
        guard MacWindow.allWindowsMap[windowId] === self, isFloating else { return }
        let lookup = reopenedGeometryStore?.lookup(bundle, liveWindowCount: liveCount) ?? .ready(nil)
        cornerTrace("reopen lookup id=\(windowId) app=\(bundle) cached=\(macApp.managedWindowCount) live=\(String(describing: liveCount)) result=\(lookup)")
        switch lookup {
            case .pending:
                return // Retry during layout; never overwrite saved geometry before deciding.
            case .ambiguous:
                needsReopenedGeometryDecision = false
                do { try reopenedGeometryStore?.forget(bundle) }
                catch { cornerTrace("geometry store forget failed: \(error)") }
            case .ready(let geometry):
                needsReopenedGeometryDecision = false
                guard let geometry else { return }
                prepareReopenedGeometry(geometry, for: self)
                cornerTrace("reopen restore id=\(windowId) app=\(bundle) geometry=\(geometry)")
                if nodeWorkspace?.isVisible == true || macApp.nsApp.isActive {
                    cornerTrace("early frame start id=\(windowId)")
                    let applied = try await applyPreparedGeometryBeforeFocus(to: self) { target in
                        try await self.macApp.setAxFrameBeforeFocus(self.windowId, geometry: target)
                    }
                    cornerTrace("early frame complete id=\(windowId) applied=\(applied)")
                }
                if nodeWorkspace?.isVisible == true { unhideFromCorner() }
        }
    }

    @MainActor
    func rememberReopenedGeometry(_ rect: Rect, beforeParking: Bool = false) {
        guard !needsReopenedGeometryDecision, supportsReopenedGeometry, isFloating, !isFullscreen,
              let bundle = macApp.rawAppBundleId, let workspace = nodeWorkspace,
              MacApp.allAppsMap.values.filter({ $0.rawAppBundleId == bundle }).count == 1 else { return }
        if macApp.managedWindowCount > 1 {
            do { try reopenedGeometryStore?.forget(bundle) }
            catch { cornerTrace("geometry store forget failed: \(error)") }
            return
        }
        guard macApp.managedWindowCount == 1, !isHiddenInCorner,
              beforeParking || workspace.isVisible else { return }
        let geometry = FloatingGeometry(rect)
        if let pending = pendingReopenedGeometry {
            guard geometry.approximatelyEquals(pending) else {
                if workspace.isVisible { setAxFrame(pending.point, pending.size) }
                return
            }
            pendingReopenedGeometry = nil
        }
        do {
            try reopenedGeometryStore?.remember(geometry, for: bundle,
                visibleBounds: FloatingGeometry(workspace.workspaceMonitor.rect), parked: false)
        } catch { cornerTrace("geometry store save failed: \(error)") }
    }
}
