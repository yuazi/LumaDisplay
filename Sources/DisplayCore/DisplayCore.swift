import Foundation

public struct ModeDescriptor: Codable, Hashable, Identifiable {
    public var width: Int
    public var height: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Double
    public var id: String { "\(width)x\(height)-\(pixelWidth)x\(pixelHeight)-\(Int((refreshRate * 100).rounded()))" }
    public var isHiDPI: Bool { pixelWidth > width }
    public var resolution: String { "\(width) × \(height)" }
    public var refreshLabel: String {
        guard refreshRate > 0 else { return "System managed" }
        return abs(refreshRate - refreshRate.rounded()) < 0.05
            ? "\(Int(refreshRate.rounded())) Hz" : String(format: "%.2f Hz", refreshRate)
    }
    public init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double) {
        self.width = width; self.height = height; self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight; self.refreshRate = refreshRate
    }
    public func matches(_ other: ModeDescriptor) -> Bool { id == other.id }
}

public struct DisplayPreset: Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var displays: [SavedDisplay]
    public init(name: String, displays: [SavedDisplay]) {
        id = UUID(); self.name = name; createdAt = Date(); self.displays = displays
    }
}

public struct SavedDisplay: Codable {
    public var uuid: String
    public var name: String
    public var mode: ModeDescriptor
    public var brightness: Double?
    public var dimming: Double
    public var warmth: Double
    public init(uuid: String, name: String, mode: ModeDescriptor, brightness: Double?, dimming: Double, warmth: Double) {
        self.uuid = uuid; self.name = name; self.mode = mode; self.brightness = brightness
        self.dimming = dimming; self.warmth = warmth
    }
}

/// Keeps the original snapshot until rollback succeeds, including after an OS error.
/// Callers apply a snapshot atomically and tick this object from their UI timer.
public final class ModePreview<Snapshot> {
    public private(set) var original: Snapshot?
    public private(set) var deadline: Date?
    public private(set) var rollbackError: String?
    private let apply: (Snapshot) throws -> Void
    public var isPending: Bool { original != nil }
    public init(apply: @escaping (Snapshot) throws -> Void) { self.apply = apply }
    public func begin(original: Snapshot, proposed: Snapshot, now: Date = Date()) throws {
        guard !isPending else { throw PreviewError.alreadyPending }
        try apply(proposed)
        self.original = original
        deadline = now.addingTimeInterval(15)
        rollbackError = nil
    }
    public func confirm(commit: () throws -> Void = {}) throws {
        guard rollbackError == nil else { return }
        guard original != nil else { return }
        try commit()
        original = nil; deadline = nil
    }
    @discardableResult public func revert() -> Bool {
        guard let original else { return true }
        do {
            try apply(original)
            self.original = nil; deadline = nil; rollbackError = nil
            return true
        } catch {
            rollbackError = error.localizedDescription
            deadline = nil
            return false
        }
    }
    public func secondsRemaining(now: Date = Date()) -> Int {
        guard let deadline else { return 0 }
        return max(0, Int(ceil(deadline.timeIntervalSince(now))))
    }
    @discardableResult public func tick(now: Date = Date()) -> Bool {
        guard let deadline, now >= deadline else { return false }
        _ = revert()
        return true
    }
}

public enum PreviewError: LocalizedError {
    case alreadyPending
    public var errorDescription: String? { "Keep or revert the current display preview first." }
}

public enum PresetStorage {
    public static func read(from url: URL) throws -> [DisplayPreset] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let presets = try JSONDecoder().decode([DisplayPreset].self, from: Data(contentsOf: url))
        try validate(presets)
        return presets
    }
    public static func write(_ presets: [DisplayPreset], to url: URL) throws {
        try validate(presets)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(presets).write(to: url, options: .atomic)
    }

    private static func validate(_ presets: [DisplayPreset]) throws {
        var presetIDs = Set<UUID>()
        for preset in presets {
            guard presetIDs.insert(preset.id).inserted else { throw ValidationError.duplicatePreset }
            var displayIDs = Set<String>()
            guard !preset.displays.isEmpty, preset.displays.allSatisfy({ display in
                let mode = display.mode
                return !display.uuid.isEmpty && displayIDs.insert(display.uuid).inserted
                    && mode.width > 0 && mode.height > 0 && mode.pixelWidth > 0 && mode.pixelHeight > 0
                    && mode.refreshRate >= 0 && Int(exactly: (mode.refreshRate * 100).rounded()) != nil
                    && (display.brightness.map { (0...1).contains($0) } ?? true)
                    && (0.2...1).contains(display.dimming) && (0...1).contains(display.warmth)
            }) else { throw ValidationError.invalidDisplay(preset.name) }
        }
    }

    private enum ValidationError: LocalizedError {
        case duplicatePreset, invalidDisplay(String)
        var errorDescription: String? {
            switch self {
            case .duplicatePreset: return "Two saved presets have the same ID."
            case .invalidDisplay(let name): return "Preset \"\(name)\" contains missing, duplicate, or invalid display settings."
            }
        }
    }
}

public enum HDRGain {
    /// Software gain is not a physical luminance measurement. Never use the
    /// potential hardware headroom as the currently available upper bound.
    public static func effective(requested: Double, currentHeadroom: Double) -> Double {
        guard requested.isFinite, currentHeadroom.isFinite else { return 1 }
        return min(max(1, requested), max(1, currentHeadroom), 2)
    }
}
