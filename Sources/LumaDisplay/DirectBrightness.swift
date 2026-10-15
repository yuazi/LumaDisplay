import AppKit
import Darwin
import IOKit
import DisplayCore

struct DirectBrightnessCapability {
    let standardNits: Double
    let ceilingNits: Double
    var maximumGain: Double { min(2, ceilingNits / standardNits) }
}

private struct DirectBrightnessSnapshot: Codable {
    let displayUUID: String
    let bootSession: String
    let properties: [String: Int64]
    let brightness: Double
    let automatic: Bool
    let preset: Int32
    let standardNits: Double?
}

/// Fresh implementation of a reversible built-in display brightness session.
/// Only the physical disp0 service with all required properties is eligible.
@MainActor final class DirectBrightness {
    private static let keys = ["IOMFBIndicatorNitsCap", "BLNitsCap",
                               "limit_max_physical_brightness", "IOMFBBrightnessLevel"]
    private static let baseline: Double = 0.998877
    private typealias AmbientRead = @convention(c) (UInt32, UnsafeMutablePointer<Bool>) -> Int32
    private typealias AmbientWrite = @convention(c) (UInt32, Bool) -> Int32
    private typealias PresetRead = @convention(c) (UInt32) -> Int32
    private typealias PresetWrite = @convention(c) (UInt32, Int32) -> Int32
    private let hardware: HardwareBrightness
    private let displayServices: UnsafeMutableRawPointer?
    private let skyLight: UnsafeMutableRawPointer?
    private let ambientRead: AmbientRead?
    private let ambientWrite: AmbientWrite?
    private let presetRead: PresetRead?
    private let presetWrite: PresetWrite?
    private let journal: URL
    private var service: io_service_t = 0
    private var displayID: CGDirectDisplayID?
    private var capability: DirectBrightnessCapability?
    private var normalRanges: [CGDirectDisplayID: (preset: Int32, range: DirectBrightnessCapability)] = [:]
    private let preferences: UserDefaults = {
        if Bundle.main.bundleIdentifier == "io.github.yuazi.LumaDisplay" { return .standard }
        return UserDefaults(suiteName: "io.github.yuazi.LumaDisplay") ?? .standard
    }()
    private var lockDescriptor: Int32 = -1
    private var recoveryBlocked = false
    private var recovery = ReversibleChange<DirectBrightnessSnapshot>(checkpoint: { _ in })
    private(set) var targetNits: Double?
    private(set) var lastRecoveryError: String?
    var active: Bool { displayID != nil && targetNits != nil }
    var activeDisplayID: CGDirectDisplayID? { active ? displayID : nil }
    var needsRestore: Bool { recovery.original != nil }

    init(hardware: HardwareBrightness) {
        self.hardware = hardware
        displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        ambientRead = displayServices.flatMap { dlsym($0, "DisplayServicesAmbientLightCompensationEnabled") }.map { unsafeBitCast($0, to: AmbientRead.self) }
        ambientWrite = displayServices.flatMap { dlsym($0, "DisplayServicesEnableAmbientLightCompensation") }.map { unsafeBitCast($0, to: AmbientWrite.self) }
        presetRead = skyLight.flatMap { dlsym($0, "SLSDisplayGetActivePresetIndex") }.map { unsafeBitCast($0, to: PresetRead.self) }
        presetWrite = skyLight.flatMap { dlsym($0, "SLSDisplaySetActivePresetIndex") }.map { unsafeBitCast($0, to: PresetWrite.self) }
        journal = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumaDisplay/direct-brightness-recovery.json")
        do {
            try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
            lockDescriptor = open(journal.deletingLastPathComponent().appendingPathComponent("direct-brightness.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw DisplayFailure.message("Another LumaDisplay instance owns direct brightness. Quit that instance first.")
            }
            guard Self.bootSession() != "unavailable" else { throw DisplayFailure.message("The system recovery identity could not be read.") }
            let saved = FileManager.default.fileExists(atPath: journal.path)
                ? try JSONDecoder().decode(DirectBrightnessSnapshot.self, from: Data(contentsOf: journal)) : nil
            // A reboot recreates the driver settings; do not replay old values.
            let recovered = saved?.bootSession == Self.bootSession() ? saved : nil
            if saved != nil && recovered == nil { try FileManager.default.removeItem(at: journal) }
            recovery = ReversibleChange(recovered: recovered, checkpoint: { [journal] snapshot in
                if let snapshot {
                    try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(snapshot).write(to: journal, options: .atomic)
                } else if FileManager.default.fileExists(atPath: journal.path) {
                    try FileManager.default.removeItem(at: journal)
                }
            })
        } catch { recoveryBlocked = true; lastRecoveryError = error.localizedDescription }
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
        if let displayServices { dlclose(displayServices) }
        if let skyLight { dlclose(skyLight) }
        if lockDescriptor >= 0 { close(lockDescriptor) }
    }

    func support(for id: CGDirectDisplayID) -> DirectBrightnessCapability? {
        guard !recoveryBlocked, lastRecoveryError == nil, CGDisplayIsBuiltin(id) != 0,
              ambientRead != nil, ambientWrite != nil, presetRead != nil, presetWrite != nil,
              hardware.get(id) != nil else { return nil }
        if displayID == id, let capability { return capability }
        guard let candidate = Self.findService() else { return nil }
        defer { IOObjectRelease(candidate) }
        guard let values = Self.properties(candidate),
              let normal = values["BLNitsCap"], let indicator = values["IOMFBIndicatorNitsCap"],
              let physical = values["limit_max_physical_brightness"] else { return nil }
        let standard = Double(normal) / 65_536
        let ceiling = Double(min(indicator, physical)) / 65_536
        let currentPreset = presetRead?(id) ?? -1
        guard currentPreset >= 0 else { return nil }
        let rangeKey = Self.rangeKey(id: id, preset: currentPreset)
        if normalRanges[id] == nil,
           let saved = preferences.array(forKey: rangeKey) as? [Double], saved.count == 2,
           saved[0].isFinite, saved[1].isFinite, saved[0] >= 100,
           saved[1] > saved[0] * 1.01, saved[1] <= 10_000 {
            normalRanges[id] = (currentPreset, DirectBrightnessCapability(standardNits: saved[0], ceilingNits: saved[1]))
        }
        // EDR presentation can temporarily make BLNitsCap equal the physical
        // HDR ceiling. Keep the observed normal range for this preset instead
        // of redefining 100% from that transient, already-boosted value.
        if let cached = normalRanges[id], cached.preset == currentPreset {
            let bound = min(ceiling, cached.range.ceilingNits)
            guard bound > cached.range.standardNits * 1.01 else { return nil }
            return DirectBrightnessCapability(standardNits: cached.range.standardNits, ceilingNits: bound)
        }
        guard standard >= 100, ceiling > standard * 1.01, ceiling <= 10_000 else { return nil }
        let range = DirectBrightnessCapability(standardNits: standard, ceilingNits: ceiling)
        normalRanges[id] = (currentPreset, range)
        preferences.set([standard, ceiling], forKey: rangeKey)
        return range
    }

    func diagnostics(for id: CGDirectDisplayID) -> [String: Any] {
        guard CGDisplayIsBuiltin(id) != 0 else { return [:] }
        var values: [String: Int64] = [:]
        if let port = Self.findService() {
            values = Self.properties(port) ?? [:]
            IOObjectRelease(port)
        }
        return ["properties": values, "preset": presetRead?(id) as Any? ?? NSNull(),
                "automaticBrightness": (try? automatic(id)) as Any? ?? NSNull(),
                "hardwareBrightness": hardware.get(id) as Any? ?? NSNull()]
    }

    func enable(id: CGDirectDisplayID, uuid: String, gain: Double) throws {
        guard !needsRestore, !recoveryBlocked, lastRecoveryError == nil, let support = support(for: id),
              let brightness = hardware.get(id), let presetRead else {
            throw DisplayFailure.message("Direct XDR upscaling is unavailable. Use HDR overlay on this display.")
        }
        guard let port = Self.findService() else { throw DisplayFailure.message("The built-in display service is unavailable.") }
        guard let values = Self.properties(port) else { IOObjectRelease(port); throw BrightnessError.invalidRange }
        service = port; displayID = id; capability = support
        do {
            let snapshot = DirectBrightnessSnapshot(displayUUID: uuid, bootSession: Self.bootSession(),
                properties: values, brightness: brightness, automatic: try automatic(id), preset: presetRead(id), standardNits: support.standardNits)
            guard snapshot.preset >= 0 else { throw DisplayFailure.message("The display preset could not be read.") }
            try recovery.begin(snapshot: snapshot, apply: { try self.configure(gain: gain) }, restore: self.restore)
        } catch {
            if !needsRestore { releaseService() }
            throw error
        }
    }

    func update(gain: Double) throws {
        guard active else { return }
        try recovery.update(apply: { try self.configure(gain: gain) }, restore: self.restore)
    }

    func disable() throws {
        guard !recoveryBlocked else { throw DisplayFailure.message(lastRecoveryError ?? "Direct brightness is unavailable.") }
        do {
            try recovery.restore(using: restore)
            targetNits = nil; lastRecoveryError = nil
            releaseService()
        } catch {
            targetNits = nil
            lastRecoveryError = error.localizedDescription
            throw error
        }
    }

    func recoverIfNeeded(displays: [(CGDirectDisplayID, String)]) throws {
        guard let snapshot = recovery.original, !active else { return }
        guard let (id, _) = displays.first(where: { $0.1 == snapshot.displayUUID }),
              CGDisplayIsBuiltin(id) != 0 else { throw DisplayFailure.message("Connect the built-in display to restore direct brightness.") }
        if service == 0 {
            guard let port = Self.findService() else { throw DisplayFailure.message("The built-in brightness service is unavailable for recovery.") }
            service = port
        }
        displayID = id
        try disable()
    }

    /// Reapply only registry changes while our normal-brightness baseline is
    /// intact. Brightness keys or automatic dimming should not be fought.
    func maintain(gain: Double) throws -> Bool {
        guard active, let id = displayID else { return true }
        guard let value = hardware.get(id), abs(value - Self.baseline) < 0.002 else {
            let manualValue = hardware.get(id)
            try disable()
            if let manualValue { try hardware.restore(id, value: manualValue) }
            return false
        }
        guard let targetNits, let values = Self.properties(service) else {
            try disable(); return false
        }
        let expected = try BrightnessScale.fixedPoint(nits: targetNits)
        // Never raise a driver-imposed thermal/power cap from the watchdog.
        if let cap = values["limit_max_physical_brightness"], cap < expected - 65_536 {
            try disable(); return false
        }
        if let level = values["IOMFBBrightnessLevel"], abs(level - expected) > 65_536 {
            try update(gain: gain)
        }
        return true
    }

    private func configure(gain: Double) throws {
        guard let id = displayID, let capability, let presetRead, let presetWrite else { return }
        let nits = try BrightnessScale.directTarget(gain: gain, standardNits: capability.standardNits, ceilingNits: capability.ceilingNits)
        if presetRead(id) != 1 {
            _ = presetWrite(id, 1)
            guard presetRead(id) == 1 else { throw DisplayFailure.message("macOS rejected the XDR display preset.") }
        }
        try setAutomatic(false, id: id)
        try hardware.set(id, value: Self.baseline)
        let value = try BrightnessScale.fixedPoint(nits: nits)
        for key in Self.keys { try write(key, value: value) }
        guard let readback = Self.properties(service), Self.keys.allSatisfy({ abs((readback[$0] ?? 0) - value) < 65_536 }) else {
            throw DisplayFailure.message("The display did not accept direct brightness. Its previous settings will be restored.")
        }
        targetNits = nits
    }

    private func restore(_ snapshot: DirectBrightnessSnapshot) throws {
        guard let id = displayID, service != 0 else { throw DisplayFailure.message("The display is unavailable for brightness restoration.") }
        // An OS cap below even the original SDR ceiling takes precedence over
        // our snapshot. Ending upscaling must not lift that new restriction.
        let currentCap = Self.properties(service)?["limit_max_physical_brightness"]
        let standardCap = try snapshot.standardNits.map { try BrightnessScale.fixedPoint(nits: $0) } ?? snapshot.properties["BLNitsCap"] ?? 0
        let lowerCap = currentCap.flatMap { cap in
            cap < standardCap - 65_536 ? cap : nil
        }
        var failures: [String] = []
        if let presetRead, let presetWrite {
            _ = presetWrite(id, snapshot.preset)
            if presetRead(id) != snapshot.preset { failures.append("display preset") }
        } else { failures.append("display preset") }
        do { try setAutomatic(snapshot.automatic, id: id) } catch { failures.append("automatic brightness") }
        do { try hardware.restore(id, value: snapshot.brightness) } catch { failures.append("hardware brightness") }
        // The system brightness setter can recalculate these properties.
        // Restore their snapshot after the system-level controls settle.
        for key in Self.keys {
            do { if let value = snapshot.properties[key] { try write(key, value: lowerCap.map { min(value, $0) } ?? value) } }
            catch { failures.append(key) }
        }
        guard failures.isEmpty else { throw DisplayFailure.message("Could not restore: \(failures.joined(separator: ", ")). Retry Reset all effects.") }
    }

    private func automatic(_ id: CGDirectDisplayID) throws -> Bool {
        var enabled = false
        guard let ambientRead, ambientRead(id, &enabled) == 0 else { throw DisplayFailure.message("Automatic brightness state could not be read.") }
        return enabled
    }
    private func setAutomatic(_ enabled: Bool, id: CGDirectDisplayID) throws {
        guard let ambientWrite, ambientWrite(id, enabled) == 0, try automatic(id) == enabled else {
            throw DisplayFailure.message("Automatic brightness could not be changed.")
        }
    }
    private func write(_ key: String, value: Int64) throws {
        if let current = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber,
           current.int64Value == value { return }
        let result = IORegistryEntrySetCFProperty(service, key as CFString, NSNumber(value: value))
        guard result == KERN_SUCCESS else { throw DisplayFailure.message("The display rejected \(key) (\(result)).") }
    }
    private func releaseService() {
        if service != 0 { IOObjectRelease(service) }
        service = 0; displayID = nil; capability = nil
    }
    private static func properties(_ port: io_service_t) -> [String: Int64]? {
        var result: [String: Int64] = [:]
        for key in keys {
            guard let value = IORegistryEntryCreateCFProperty(port, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber,
                  value.doubleValue > 0, value.doubleValue <= 10_000 * 65_536 else { return nil }
            result[key] = value.int64Value
        }
        return result
    }
    private static func findService() -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleCLCD2"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var candidates: [io_service_t] = []
        while case let port = IOIteratorNext(iterator), port != 0 {
            let name = IORegistryEntryCreateCFProperty(port, "IONameMatched" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if name?.hasPrefix("disp0,") == true, properties(port) != nil { candidates.append(port) }
            else { IOObjectRelease(port) }
        }
        guard candidates.count == 1 else { candidates.forEach { IOObjectRelease($0) }; return nil }
        return candidates[0]
    }
    private static func bootSession() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "unavailable" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "unavailable" }
        return String(cString: bytes)
    }
    private static func rangeKey(id: CGDirectDisplayID, preset: Int32) -> String {
        let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "display-\(id)"
        return "directNormalRange.\(uuid).\(preset)"
    }
}
