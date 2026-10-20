import Foundation

struct FloatingGeometry: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var isValid: Bool {
        [x, y, width, height].allSatisfy { $0.isFinite } && width > 0 && height > 0
    }

    func isVisible(in bounds: FloatingGeometry) -> Bool {
        let overlapWidth = min(x + width, bounds.x + bounds.width) - max(x, bounds.x)
        let overlapHeight = min(y + height, bounds.y + bounds.height) - max(y, bounds.y)
        return isValid && overlapWidth >= min(100, width / 2) && overlapHeight >= min(60, height / 2)
    }

    func clamped(to bounds: FloatingGeometry) -> FloatingGeometry {
        let w = min(width, bounds.width)
        let h = min(height, bounds.height)
        return FloatingGeometry(x: max(bounds.x, min(x, bounds.x + bounds.width - w)),
                                y: max(bounds.y, min(y, bounds.y + bounds.height - h)), width: w, height: h)
    }

    func approximatelyEquals(_ other: FloatingGeometry) -> Bool {
        abs(x - other.x) <= 2 && abs(y - other.y) <= 2 && abs(width - other.width) <= 2 && abs(height - other.height) <= 2
    }
}

enum FloatingGeometryLookup: Equatable {
    case pending
    case ambiguous
    case ready(FloatingGeometry?)
}

struct FloatingGeometryStore {
    private let url: URL
    private var entries: [String: FloatingGeometry]

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            entries = try JSONDecoder().decode([String: FloatingGeometry].self, from: Data(contentsOf: url))
            guard entries.values.allSatisfy(\.isValid) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        } else {
            entries = [:]
        }
    }

    func geometry(for bundle: String) -> FloatingGeometry? { entries[bundle] }

    func lookup(_ bundle: String, liveWindowCount: Int?) -> FloatingGeometryLookup {
        guard let count = liveWindowCount, count > 0 else { return .pending }
        guard count == 1 else { return .ambiguous }
        return .ready(entries[bundle])
    }

    mutating func remember(_ geometry: FloatingGeometry, for bundle: String, visibleBounds: FloatingGeometry, parked: Bool) throws {
        guard !parked, geometry.isVisible(in: visibleBounds) else { return }
        var updated = entries
        updated[bundle] = geometry
        try commit(updated)
    }

    mutating func forget(_ bundle: String) throws {
        var updated = entries
        updated.removeValue(forKey: bundle)
        try commit(updated)
    }

    private mutating func commit(_ updated: [String: FloatingGeometry]) throws {
        guard updated != entries else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        entries = updated
    }
}
