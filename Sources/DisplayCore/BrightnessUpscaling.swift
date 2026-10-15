import Foundation

public enum UpscalingMethod: String, CaseIterable, Identifiable {
    case hdrOverlay, direct
    public var id: String { rawValue }
    public var title: String { self == .direct ? "Direct XDR" : "HDR overlay" }
}

public enum BrightnessScale {
    public static func bounded(_ value: Double, maximum: Double = 2) -> Double {
        guard value.isFinite, maximum.isFinite else { return 1 }
        return min(max(0.05, value), max(1, min(2, maximum)))
    }

    /// The direct controller uses unsigned positive luminance in 16.16 units.
    /// The result is a requested driver value, not a luminance measurement.
    public static func fixedPoint(nits: Double) throws -> Int64 {
        guard nits.isFinite, (0...10_000).contains(nits) else { throw BrightnessError.invalidRange }
        return Int64((nits * 65_536).rounded())
    }

    public static func directTarget(gain: Double, standardNits: Double, ceilingNits: Double) throws -> Double {
        guard gain.isFinite, standardNits.isFinite, ceilingNits.isFinite,
              standardNits > 0, standardNits <= ceilingNits, ceilingNits <= 10_000 else {
            throw BrightnessError.invalidRange
        }
        return min(ceilingNits, standardNits * min(2, max(1, gain)))
    }
}

public enum BrightnessError: LocalizedError {
    case invalidRange, alreadyActive
    public var errorDescription: String? {
        switch self {
        case .invalidRange: return "The display reported an unsupported brightness range."
        case .alreadyActive: return "Restore the previous brightness session before starting another."
        }
    }
}

/// Keeps a recovery snapshot until both restoration and checkpoint removal
/// succeed. A failed partial apply always attempts the complete restoration.
public final class ReversibleChange<Snapshot> {
    public private(set) var original: Snapshot?
    private let checkpoint: (Snapshot?) throws -> Void
    public init(recovered: Snapshot? = nil, checkpoint: @escaping (Snapshot?) throws -> Void) {
        original = recovered
        self.checkpoint = checkpoint
    }
    public func begin(snapshot: Snapshot, apply: () throws -> Void, restore: (Snapshot) throws -> Void) throws {
        guard original == nil else { throw BrightnessError.alreadyActive }
        try checkpoint(snapshot)
        original = snapshot
        try update(apply: apply, restore: restore)
    }
    public func update(apply: () throws -> Void, restore: (Snapshot) throws -> Void) throws {
        do { try apply() }
        catch {
            let applyError = error
            do { try self.restore(using: restore) }
            catch { throw RecoveryFailure(change: applyError.localizedDescription, recovery: error.localizedDescription) }
            throw applyError
        }
    }
    public func restore(using restore: (Snapshot) throws -> Void) throws {
        guard let original else { return }
        try restore(original)
        try checkpoint(nil)
        self.original = nil
    }
}

public struct RecoveryFailure: LocalizedError {
    public let change: String
    public let recovery: String
    public var errorDescription: String? { "\(change) Restoration needs another attempt: \(recovery)" }
}
