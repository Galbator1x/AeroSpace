import AppKit
import Common

struct ReopenedGeometryRestore: Equatable, Sendable {
    let id = UUID()
    var target: FloatingGeometry
    var bounds: FloatingGeometry
    var retryCount = 0
}

enum ReopenedGeometryState: Equatable, Sendable {
    case undecided
    case pending(ReopenedGeometryRestore)
    case finished

    var pending: ReopenedGeometryRestore? {
        if case .pending(let restore) = self { return restore }
        return nil
    }
}

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
    let bounds = FloatingGeometry(workspace.workspaceMonitorInfo.rect)
    // A restore target is not a parking position: preserve the actual frame until it is applied.
    window.reopenedGeometry = .pending(ReopenedGeometryRestore(target: geometry.clamped(to: bounds), bounds: bounds))
}

@MainActor
func decideReopenedGeometry(
    for window: Window,
    lookup: @MainActor () async throws -> FloatingGeometryLookup
) async throws -> FloatingGeometryLookup? {
    guard window.needsReopenedGeometryDecision, window.isFloating else { return nil }
    let decision = try await lookup()
    // A mouse gesture or command can cancel the decision while AX is suspended.
    guard window.needsReopenedGeometryDecision, window.isFloating else { return nil }
    switch decision {
        case .pending: break
        case .ambiguous: window.cancelReopenedGeometry()
        case .ready(let geometry):
            window.reopenedGeometry = .finished
            if let geometry { prepareReopenedGeometry(geometry, for: window) }
    }
    return decision
}

@MainActor
func applyPreparedGeometryBeforeFocus(
    to window: Window,
    apply: @escaping @MainActor (FloatingGeometry) async throws -> Bool
) async throws -> Bool {
    window.rebaseReopenedGeometryIfNeeded()
    guard let restore = window.reopenedGeometry.pending else { return false }
    window.cancelReopenedGeometryApplication()
    let id = UUID()
    let task = Task { @MainActor in
        try checkCancellation()
        return try await apply(restore.target)
    }
    window.reopenedGeometryApplication = (id, task)
    defer {
        if window.reopenedGeometryApplication?.id == id { window.reopenedGeometryApplication = nil }
    }
    let applied: Bool
    do {
        applied = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        try checkCancellation()
    } catch is CancellationError {
        try checkCancellation()
        if window.reopenedGeometryApplication?.id != id { return false }
        throw CancellationError()
    }
    window.rebaseReopenedGeometryIfNeeded()
    guard applied, window.reopenedGeometryApplication?.id == id,
          window.reopenedGeometry.pending?.id == restore.id,
          window.pendingReopenedGeometry == restore.target else { return false }
    window.prevUnhiddenProportionalPositionInsideWorkspaceRect = nil
    window.lastFloatingSize = restore.target.size
    return true
}

@MainActor
@discardableResult
func invalidateAmbiguousReopenedGeometry(_ windows: [Window], windowCount: Int, appCount: Int = 1) -> Bool {
    guard windowCount > 1 || appCount > 1 else { return false }
    for window in windows { window.cancelReopenedGeometry(allowRevealFallback: true) }
    return true
}

@MainActor
@discardableResult
func invalidateAmbiguousReopenedGeometry(for app: MacApp, liveWindowCount: Int? = nil) -> Bool {
    guard let bundle = app.rawAppBundleId else { return false }
    let count = liveWindowCount ?? app.managedWindowCount
    let duplicateApp = MacApp.allAppsMap.values.contains { $0 !== app && $0.rawAppBundleId == bundle }
    guard count > 1 || duplicateApp else { return false }
    let windows = MacWindow.allWindows.filter { $0.macApp.rawAppBundleId == bundle }
    invalidateAmbiguousReopenedGeometry(windows, windowCount: count, appCount: duplicateApp ? 2 : 1)
    do { try reopenedGeometryStore?.forget(bundle) }
    catch { reportFloatingGeometryError("geometry store forget failed: \(error)") }
    return true
}

extension MacWindow {
    @MainActor
    func restoreReopenedGeometry() async throws {
        guard let bundle = macApp.rawAppBundleId else { cancelReopenedGeometry(); return }
        let kind = try await macApp.getAxUiElementWindowType(windowId, getWindowLevel(for: windowId, .cancellable), .cancellable)
        guard MacWindow.allWindowsMap[windowId] === self else { return }
        supportsReopenedGeometry = kind == .window
        guard supportsReopenedGeometry, isFloating else { cancelReopenedGeometry(); return }
        guard !invalidateAmbiguousReopenedGeometry(for: macApp) else { return }
        let decision = try await decideReopenedGeometry(for: self) {
            let count = try await self.macApp.getAxWindowsCount(.cancellable)
            guard MacWindow.allWindowsMap[self.windowId] === self else { return .pending }
            if invalidateAmbiguousReopenedGeometry(for: self.macApp, liveWindowCount: count) { return .ambiguous }
            return reopenedGeometryStore?.lookup(bundle, liveWindowCount: count) ?? .ready(nil)
        }
        guard case .ready = decision, pendingReopenedGeometry != nil else { return }
        if nodeWorkspace?.isVisible == true || macApp.nsApp.isActive {
            _ = try await applyPreparedGeometryBeforeFocus(to: self) { target in
                try await self.setAxFrameBeforeFocus(target)
            }
        }
        if nodeWorkspace?.isVisible == true { try await unhideFromCorner() }
    }

    @MainActor
    func rememberReopenedGeometry(_ rect: Rect, beforeParking: Bool = false) {
        guard !invalidateAmbiguousReopenedGeometry(for: macApp) else { return }
        rebaseReopenedGeometryIfNeeded()
        guard !needsReopenedGeometryDecision, supportsReopenedGeometry, isFloating, !isFullscreen,
              let bundle = macApp.rawAppBundleId, let workspace = nodeWorkspace,
              macApp.managedWindowCount == 1, !isHiddenInCorner,
              beforeParking || workspace.isVisible else { return }
        let geometry = FloatingGeometry(rect)
        guard confirmReopenedGeometry(geometry, for: self, visible: workspace.isVisible) else {
            if workspace.isVisible, let pending = pendingReopenedGeometry {
                setReopenedGeometryFrame(pending)
            }
            return
        }
        lastFloatingSize = geometry.size
        do {
            try reopenedGeometryStore?.remember(geometry, for: bundle,
                visibleBounds: FloatingGeometry(workspace.workspaceMonitorInfo.rect), parked: false)
        } catch { reportFloatingGeometryError("geometry store save failed: \(error)") }
    }
}

@MainActor
func confirmReopenedGeometry(_ actual: FloatingGeometry, for window: Window, visible: Bool) -> Bool {
    guard var restore = window.reopenedGeometry.pending else { return true }
    if actual.approximatelyEquals(restore.target) {
        window.cancelReopenedGeometry()
        return true
    }
    guard visible else { return false }
    if restore.retryCount < 3 {
        restore.retryCount += 1
        window.reopenedGeometry = .pending(restore)
        return false
    }
    // Applications may enforce their own minimum size or position. Stop fighting them.
    window.cancelReopenedGeometry()
    return true
}

extension Window {
    var needsReopenedGeometryDecision: Bool { reopenedGeometry == .undecided }
    var pendingReopenedGeometry: FloatingGeometry? { reopenedGeometry.pending?.target }

    @MainActor
    func rebaseReopenedGeometryIfNeeded() {
        guard pendingReopenedGeometry != nil, let workspace = nodeWorkspace else { return }
        rebaseReopenedGeometry(to: FloatingGeometry(workspace.workspaceMonitorInfo.rect))
    }

    @MainActor
    func rebaseReopenedGeometry(to bounds: FloatingGeometry) {
        guard var restore = reopenedGeometry.pending, bounds.isValid, restore.bounds != bounds else { return }
        let previous = restore.bounds
        let pending = restore.target
        restore.target = FloatingGeometry(
            x: bounds.x + (pending.x - previous.x) / previous.width * bounds.width,
            y: bounds.y + (pending.y - previous.y) / previous.height * bounds.height,
            width: pending.width, height: pending.height,
        ).clamped(to: bounds)
        restore.bounds = bounds
        restore.retryCount = 0
        reopenedGeometry = .pending(restore)
    }

    @MainActor
    func setReopenedGeometryFrame(_ target: FloatingGeometry) {
        if let window = self as? MacWindow {
            reopenedGeometryFrameJob = window.macApp.setAxFrame(windowId, target.point, target.size)
        } else {
            setAxFrame(target.point, target.size)
        }
    }

    @MainActor
    func cancelReopenedGeometryApplication() {
        reopenedGeometryApplication?.task.cancel()
        reopenedGeometryApplication = nil
        reopenedGeometryFrameJob?.cancel()
        reopenedGeometryFrameJob = nil
    }

    @MainActor
    func cancelReopenedGeometryReveal() {
        reopenedGeometryRevealId = nil
        cancelReopenedGeometryApplication()
    }

    @MainActor
    func cancelReopenedGeometry(allowRevealFallback: Bool = false) {
        reopenedGeometry = .finished
        if !allowRevealFallback { reopenedGeometryRevealId = nil }
        cancelReopenedGeometryApplication()
    }
}

@MainActor
func flushReopenedGeometry() {
    reopenedGeometryStore?.flush()
}
