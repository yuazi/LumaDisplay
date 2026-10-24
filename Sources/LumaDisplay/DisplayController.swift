import AppKit
import Combine
import CoreGraphics
import DisplayCore
import Darwin

struct DisplayOption: Identifiable {
    let native: CGDisplayMode
    let descriptor: ModeDescriptor
    var id: String { descriptor.id }
    init(_ native: CGDisplayMode) {
        self.native = native
        descriptor = .init(width: native.width, height: native.height, pixelWidth: native.pixelWidth,
                           pixelHeight: native.pixelHeight, refreshRate: native.refreshRate)
    }
}

struct DisplayDevice: Identifiable {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    let builtIn: Bool
    let main: Bool
    let mirrored: Bool
    let frame: CGRect
    let current: DisplayOption
    let modes: [DisplayOption]
    var brightness: Double?
    var dimming: Double = 1
    var warmth: Double = 0
    var edrPotential: Double = 1
    var edrCurrent: Double = 1
    var hdrEnabled: Bool = false
    var hdrGain: Double = 1.25
    var hdrApplied: Double = 1
    var upscalingMethod: UpscalingMethod = .hdrOverlay
    var directMaximumGain: Double = 1
    var directSupported: Bool { directMaximumGain > 1.01 }
    var upscalingSupported: Bool { hdrSupported || directSupported }
    var combinedBrightness: Double { hdrEnabled ? hdrGain : brightness ?? dimming }
    var hdrSupported: Bool { edrPotential > 1.01 }
}

/// Optional system facility: never assume that an attached monitor supports it.
final class HardwareBrightness {
    typealias Read = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias Write = @convention(c) (UInt32, Float) -> Int32
    private let handle: UnsafeMutableRawPointer?
    private let read: Read?
    private let write: Write?
    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        read = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Read.self) }
        write = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Write.self) }
    }
    deinit { if let handle { dlclose(handle) } }
    func get(_ display: CGDirectDisplayID) -> Double? {
        guard let read, write != nil else { return nil }
        var value: Float = 0
        guard read(display, &value) == 0, value.isFinite, (0...1).contains(value) else { return nil }
        return Double(value)
    }
    func set(_ display: CGDirectDisplayID, value: Double) throws {
        try restore(display, value: min(1, max(0.05, value)))
    }
    /// Restoration must preserve even an original system brightness below
    /// the app slider's minimum; the UI floor is not a hardware constraint.
    func restore(_ display: CGDirectDisplayID, value: Double) throws {
        guard value.isFinite, (0...1).contains(value) else { throw BrightnessError.invalidRange }
        guard let write else { throw DisplayFailure.message("Hardware brightness is unavailable for this display.") }
        let result = write(display, Float(value))
        guard result == 0 else { throw DisplayFailure.message("The display rejected the brightness change (\(result)). Use software dimming instead.") }
    }
}

enum DisplayFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

final class TintView: NSView {
    var dimming: Double = 1
    var warmth: Double = 0
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        NSColor.black.withAlphaComponent(1 - dimming).setFill()
        bounds.fill()
        NSColor(calibratedRed: 1, green: 0.52, blue: 0.12, alpha: warmth * 0.28).setFill()
        bounds.fill()
    }
}

final class ScreenOverlay {
    let window: DisplayOverlayPanel
    private let tint = TintView()
    init(frame: NSRect) {
        window = DisplayOverlayPanel(frame: frame, level: NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1))
        window.contentView = tint
    }
    func update(frame: NSRect, dimming: Double, warmth: Double) {
        tint.dimming = dimming; tint.warmth = warmth; tint.needsDisplay = true
        if dimming < 0.999 || warmth > 0.001 { window.present(on: frame) }
        else { window.orderOut(nil) }
    }
    func close() { window.close() }
}

@MainActor final class DisplayController: ObservableObject {
    @Published var displays: [DisplayDevice] = []
    @Published var selectedID: CGDirectDisplayID?
    @Published var presets: [DisplayPreset] = []
    @Published var error: String?
    @Published var status = "Display controls ready."
    @Published var secondsRemaining = 0
    @Published var previewPending = false
    @Published var rollbackFailed = false
    private let brightness = HardwareBrightness()
    private lazy var directBrightness = DirectBrightness(hardware: brightness)
    private var directPulse: HDRActivityPulse?
    private var directGeneration = UUID()
    private var overlayBrightnessSnapshots: [CGDirectDisplayID: Double] = [:]
    private var overlays: [CGDirectDisplayID: ScreenOverlay] = [:]
    private var hdrOverlays: [CGDirectDisplayID: HDRBoostWindow] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var ticks = 0
    private var pendingAppearance: [SavedDisplay]?
    private var presetStorageAvailable = true
    private let presetURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LumaDisplay/presets.json")
    private lazy var preview = ModePreview<[String: CGDisplayMode]> { try Self.configure($0, scope: .forAppOnly) }
    var selected: DisplayDevice? { displays.first { $0.id == selectedID } }

    init() {
        do { presets = try PresetStorage.read(from: presetURL) }
        catch { self.error = "Saved presets could not be read. The file has been preserved: \(error.localizedDescription)"; presetStorageAvailable = false }
        refresh()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.disableAllHDR() }
            })
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.restoreOverlayPlacement() }
            })
        }
        let previewTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(previewTimer, forMode: .common)
        timer = previewTimer
    }

    func refresh() {
        let old = Dictionary(uniqueKeysWithValues: displays.map { ($0.uuid, $0) })
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            let directSupport = directBrightness.support(for: id)
            guard let native = CGDisplayCopyDisplayMode(id) else { return nil }
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "display-\(id)"
            if hdrOverlays[id] != nil && old[uuid]?.id != id { hdrOverlays.removeValue(forKey: id)?.close() }
            let current = DisplayOption(native)
            let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            let nativeModes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? [native]
            var seen = Set<String>()
            var modes = nativeModes.filter { $0.isUsableForDesktopGUI() }.map(DisplayOption.init)
                .filter { seen.insert($0.id).inserted }
            if !modes.contains(where: { $0.id == current.id }) { modes.append(current) }
            modes.sort {
                if $0.descriptor.width != $1.descriptor.width { return $0.descriptor.width < $1.descriptor.width }
                if $0.descriptor.height != $1.descriptor.height { return $0.descriptor.height < $1.descriptor.height }
                if $0.descriptor.isHiDPI != $1.descriptor.isHiDPI { return $0.descriptor.isHiDPI }
                return $0.descriptor.refreshRate > $1.descriptor.refreshRate
            }
            return DisplayDevice(id: id, uuid: uuid, name: screen.localizedName,
                                 builtIn: CGDisplayIsBuiltin(id) != 0, main: CGDisplayIsMain(id) != 0,
                                 mirrored: CGDisplayIsInMirrorSet(id) != 0, frame: screen.frame,
                                 current: current, modes: modes, brightness: brightness.get(id),
                                 dimming: old[uuid]?.dimming ?? 1, warmth: old[uuid]?.warmth ?? 0,
                                 edrPotential: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue),
                                 edrCurrent: Double(screen.maximumExtendedDynamicRangeColorComponentValue),
                                 hdrEnabled: hdrOverlays[id] != nil || directBrightness.activeDisplayID == id,
                                 hdrGain: old[uuid]?.hdrGain ?? 1.25, hdrApplied: hdrOverlays[id]?.surface.appliedGain ?? 1,
                                 upscalingMethod: old[uuid]?.upscalingMethod ?? .hdrOverlay,
                                 directMaximumGain: directSupport?.maximumGain ?? 1)
        }
        let recoveringDirect = directBrightness.needsRestore && !directBrightness.active
        do {
            try directBrightness.recoverIfNeeded(displays: displays.map { ($0.id, $0.uuid) })
            if recoveringDirect && !directBrightness.needsRestore {
                for index in displays.indices { displays[index].directMaximumGain = directBrightness.support(for: displays[index].id)?.maximumGain ?? 1 }
            }
        }
        catch { self.error = error.localizedDescription }
        let connected = Set(displays.map(\.id))
        if let id = directBrightness.activeDisplayID, !connected.contains(id) {
            do { try directBrightness.disable() } catch { self.error = error.localizedDescription }
            directPulse?.close()
        }
        for id in Array(overlays.keys) where !connected.contains(id) { overlays.removeValue(forKey: id)?.close() }
        for id in Array(hdrOverlays.keys) where !connected.contains(id) { hdrOverlays.removeValue(forKey: id)?.close() }
        // An offline output must never leave a numeric-ID snapshot that could
        // later be applied to a different monitor reusing that ID.
        for id in Array(overlayBrightnessSnapshots.keys) where !connected.contains(id) { overlayBrightnessSnapshots.removeValue(forKey: id) }
        for display in displays where display.hdrEnabled && display.upscalingMethod == .hdrOverlay {
            if let screen = screen(for: display.id), display.hdrSupported {
                hdrOverlays[display.id]?.update(screen: screen, gain: display.hdrGain)
            } else { setHDR(false, for: display.id) }
        }
        for display in displays { updateOverlay(display) }
        if !displays.contains(where: { $0.id == selectedID }) { selectedID = displays.first?.id }
    }

    func setBrightness(_ value: Double, for id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        if displays[index].hdrEnabled { setHDR(false, for: id) }
        guard !directBrightness.needsRestore, overlayBrightnessSnapshots[id] == nil else { return }
        do {
            try brightness.set(id, value: value)
            displays[index].brightness = brightness.get(id) ?? min(1, max(0.05, value))
        } catch { self.error = error.localizedDescription }
    }

    func setDimming(_ value: Double, for id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        displays[index].dimming = min(1, max(0.2, value))
        updateOverlay(displays[index])
    }

    func setWarmth(_ value: Double, for id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        displays[index].warmth = min(1, max(0, value))
        updateOverlay(displays[index])
    }

    func resetAppearance() {
        disableAllHDR()
        for index in displays.indices {
            displays[index].dimming = 1; displays[index].warmth = 0
            updateOverlay(displays[index])
        }
        status = "HDR boost, software dimming, and warmth reset."
    }

    private func updateOverlay(_ display: DisplayDevice) {
        guard display.dimming < 0.999 || display.warmth > 0.001 || overlays[display.id] != nil else { return }
        let overlay = overlays[display.id] ?? ScreenOverlay(frame: display.frame)
        overlays[display.id] = overlay
        overlay.update(frame: display.frame, dimming: display.dimming, warmth: display.warmth)
    }

    private func restoreOverlayPlacement() {
        // Reassert only existing effects; changing Space must never enable HDR.
        for display in displays {
            guard let screen = screen(for: display.id) else { continue }
            hdrOverlays[display.id]?.update(screen: screen, gain: display.hdrGain)
            if directBrightness.activeDisplayID == display.id { directPulse?.pulse(on: screen) }
            overlays[display.id]?.update(frame: screen.frame, dimming: display.dimming, warmth: display.warmth)
        }
    }

    func previewMode(_ modeID: String, for id: CGDirectDisplayID) {
        guard let display = displays.first(where: { $0.id == id }), let mode = display.modes.first(where: { $0.id == modeID }) else { return }
        guard !display.mirrored else { error = "Change mirrored-display modes in System Settings."; return }
        guard mode.id != display.current.id else { return }
        beginPreview([display.uuid: mode.native])
    }

    private func beginPreview(_ proposed: [String: CGDisplayMode], appearance: [SavedDisplay]? = nil) {
        disableAllHDR()
        guard !directBrightness.needsRestore, overlayBrightnessSnapshots.isEmpty else { return }
        // Capture all displays because a configuration transaction can affect more than one output.
        let original = Dictionary(uniqueKeysWithValues: displays.map { ($0.uuid, $0.current.native) })
        do {
            try preview.begin(original: original, proposed: proposed)
            pendingAppearance = appearance
            syncPreview()
            refresh()
        } catch { self.error = error.localizedDescription }
    }

    private static func configure(_ modes: [String: CGDisplayMode], scope: CGConfigureOption) throws {
        // Resolve stable UUIDs again at application time; hot-plug can change numeric IDs.
        var connected: [String: CGDirectDisplayID] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { continue }
            connected[CFUUIDCreateString(nil, uuid) as String] = number.uint32Value
        }
        var configuration: CGDisplayConfigRef?
        let start = CGBeginDisplayConfiguration(&configuration)
        guard start == .success, let configuration else { throw DisplayFailure.message("macOS could not begin a display change (\(start.rawValue)).") }
        var count = 0
        for (uuid, mode) in modes {
            // A disconnected display cannot be restored. Other connected outputs still can.
            guard let id = connected[uuid], CGDisplayIsOnline(id) != 0 else { continue }
            let result = CGConfigureDisplayWithDisplayMode(configuration, id, mode, nil)
            guard result == .success else {
                CGCancelDisplayConfiguration(configuration)
                throw DisplayFailure.message("macOS rejected this display mode (\(result.rawValue)).")
            }
            count += 1
        }
        if count == 0 { CGCancelDisplayConfiguration(configuration); return }
        let result = CGCompleteDisplayConfiguration(configuration, scope)
        guard result == .success else { throw DisplayFailure.message("macOS could not apply the display configuration (\(result.rawValue)).") }
    }

    func keepPreview() {
        guard preview.isPending, preview.rollbackError == nil else { return }
        let current = Dictionary(uniqueKeysWithValues: displays.map { ($0.uuid, $0.current.native) })
        do { try preview.confirm { try Self.configure(current, scope: .forSession) } }
        catch { self.error = "Could not keep this mode. The preview will still revert. \(error.localizedDescription)"; return }
        if let appearance = pendingAppearance { applyAppearance(appearance) }
        pendingAppearance = nil
        syncPreview(); refresh()
        status = "Display settings kept for this login session."
    }

    @discardableResult func revertPreview() -> Bool {
        let result = preview.revert()
        if result { pendingAppearance = nil; status = "Previous display settings restored." }
        else { error = "Could not restore the previous mode. Retry Revert or open System Settings. \(preview.rollbackError ?? "")" }
        syncPreview(); refresh()
        return result
    }

    private func syncPreview() {
        previewPending = preview.isPending
        rollbackFailed = preview.rollbackError != nil
        secondsRemaining = preview.secondsRemaining()
    }

    private func tick() {
        if preview.tick() {
            pendingAppearance = nil
            status = preview.rollbackError == nil ? "Preview expired. Previous display settings restored." : "Restore failed. Retry Revert."
            refresh()
        }
        if preview.isPending || previewPending { syncPreview() }
        ticks += 1
        if ticks % 16 == 0 {
            for index in displays.indices { displays[index].brightness = brightness.get(displays[index].id) }
        }
        if ticks % 4 == 0 {
            for index in displays.indices {
                let id = displays[index].id
                if let screen = screen(for: id) {
                    displays[index].edrCurrent = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
                    displays[index].edrPotential = Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
                }
                if directBrightness.activeDisplayID == id {
                    displays[index].hdrApplied = displays[index].hdrGain
                } else { displays[index].hdrApplied = hdrOverlays[id]?.surface.appliedGain ?? 1 }
            }
        }
        if ticks % 12 == 0 {
            maintainDirectBrightness()
            for index in displays.indices where !displays[index].hdrEnabled {
                displays[index].directMaximumGain = directBrightness.support(for: displays[index].id)?.maximumGain ?? 1
            }
            restoreOverlayPlacement()
        }
    }

    private func maintainDirectBrightness() {
        guard let id = directBrightness.activeDisplayID, let index = displays.firstIndex(where: { $0.id == id }) else { return }
        do {
            if try !directBrightness.maintain(gain: displays[index].hdrGain) {
                directGeneration = UUID(); directPulse?.close()
                displays[index].hdrEnabled = false; displays[index].hdrApplied = 1
                displays[index].brightness = brightness.get(id)
                status = "Direct upscaling stopped after the system brightness or power limit changed."
            }
        } catch { setHDR(false, for: id); self.error = error.localizedDescription }
    }

    func savePreset(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !displays.isEmpty, !previewPending else { return }
        guard presetStorageAvailable else { error = "The unreadable presets file is preserved at \(presetURL.path). Repair or move it, then restart to save presets."; return }
        let saved = displays.map { SavedDisplay(uuid: $0.uuid, name: $0.name, mode: $0.current.descriptor, brightness: $0.brightness, dimming: $0.dimming, warmth: $0.warmth) }
        let updated = presets + [DisplayPreset(name: String(name.prefix(60)), displays: saved)]
        do { try PresetStorage.write(updated, to: presetURL); presets = updated; status = "Saved “\(name)”." }
        catch { self.error = error.localizedDescription }
    }

    func deletePreset(_ preset: DisplayPreset) {
        let updated = presets.filter { $0.id != preset.id }
        do { try PresetStorage.write(updated, to: presetURL); presets = updated }
        catch { self.error = error.localizedDescription }
    }

    func applyPreset(_ preset: DisplayPreset) {
        guard !previewPending else { error = "Keep or revert the current preview first."; return }
        var modes: [String: CGDisplayMode] = [:]
        for saved in preset.displays {
            guard let display = displays.first(where: { $0.uuid == saved.uuid }) else { error = "Connect \(saved.name) before applying “\(preset.name)”."; return }
            guard let mode = display.modes.first(where: { $0.descriptor.matches(saved.mode) }) else { error = "The saved resolution for \(saved.name) is no longer available."; return }
            if mode.id != display.current.id {
                guard !display.mirrored else { error = "Adjust mirrored displays in System Settings before applying this preset."; return }
                modes[display.uuid] = mode.native
            }
        }
        if modes.isEmpty { applyAppearance(preset.displays); status = "Applied “\(preset.name)”." }
        else { beginPreview(modes, appearance: preset.displays) }
    }

    private func applyAppearance(_ saved: [SavedDisplay]) {
        // Presets never implicitly enable extra brightness. Keep it a deliberate action.
        disableAllHDR()
        for item in saved {
            guard let display = displays.first(where: { $0.uuid == item.uuid }) else { continue }
            if let value = item.brightness, display.brightness != nil { setBrightness(value, for: display.id) }
            setDimming(item.dimming, for: display.id)
            setWarmth(item.warmth, for: display.id)
        }
    }

    func identifyDisplays() {
        for (index, display) in displays.enumerated() {
            let panel = NSPanel(contentRect: NSRect(x: display.frame.midX - 125, y: display.frame.midY - 70, width: 250, height: 140), styleMask: [.borderless], backing: .buffered, defer: false)
            panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96)
            panel.isOpaque = false; panel.hasShadow = true; panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false; panel.ignoresMouseEvents = true
            let label = NSTextField(labelWithString: "\(index + 1)\n\(display.name)")
            label.alignment = .center; label.font = .systemFont(ofSize: 25, weight: .semibold)
            label.frame = NSRect(x: 10, y: 30, width: 230, height: 80)
            panel.contentView?.addSubview(label); panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { panel.close() }
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    func prepareToQuit() -> Bool {
        if preview.isPending && !revertPreview() { return false }
        for overlay in overlays.values { overlay.close() }
        disableAllHDR()
        return !directBrightness.needsRestore && overlayBrightnessSnapshots.isEmpty
    }

    func diagnostics() -> String {
        let data: [[String: Any]] = displays.map {
            ["name": $0.name, "id": $0.id, "uuid": $0.uuid, "builtIn": $0.builtIn, "main": $0.main,
             "resolution": $0.current.descriptor.resolution, "refresh": $0.current.descriptor.refreshLabel,
             "modeCount": $0.modes.count, "hiDPIModeCount": $0.modes.filter { $0.descriptor.isHiDPI }.count,
             "hardwareBrightness": $0.brightness as Any? ?? NSNull(), "mirrored": $0.mirrored]
        }
        guard let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]), let output = String(data: json, encoding: .utf8) else { return "[]" }
        return output
    }

    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }

    func setHDR(_ enabled: Bool, for id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        if !enabled {
            directGeneration = UUID()
            hdrOverlays.removeValue(forKey: id)?.close()
            do {
                if directBrightness.activeDisplayID == id || directBrightness.needsRestore { try directBrightness.disable() }
                if let original = overlayBrightnessSnapshots[id] {
                    // Preserve a brightness-key adjustment made outside the app.
                    guard let current = brightness.get(id) else { throw DisplayFailure.message("Hardware brightness could not be restored. Retry Reset all effects.") }
                    if abs(current - 1) < 0.002 { try brightness.restore(id, value: original) }
                    overlayBrightnessSnapshots.removeValue(forKey: id)
                }
            } catch { self.error = error.localizedDescription }
            directPulse?.close()
            displays[index].hdrEnabled = false; displays[index].hdrApplied = 1
            displays[index].brightness = brightness.get(id)
            status = "HDR boost off. Standard desktop brightness restored."
            return
        }
        guard !displays[index].hdrEnabled else { return }
        guard !directBrightness.needsRestore else { error = "Reset all effects to restore the previous direct brightness session first."; return }
        guard overlayBrightnessSnapshots[id] == nil else { error = "Reset all effects to restore the previous HDR brightness before enabling upscaling again."; return }
        if displays[index].upscalingMethod == .direct {
            guard let screen = screen(for: id), displays[index].directSupported else {
                error = directBrightness.lastRecoveryError ?? "Direct XDR upscaling requires a supported built-in Apple display."
                return
            }
            do {
                let gain = min(displays[index].directMaximumGain, displays[index].hdrGain)
                try directBrightness.enable(id: id, uuid: displays[index].uuid, gain: gain)
                displays[index].hdrGain = gain
                displays[index].hdrEnabled = true; displays[index].hdrApplied = gain
                displays[index].brightness = brightness.get(id)
                directPulse = directPulse ?? HDRActivityPulse()
                directPulse?.pulse(on: screen)
                // macOS can asynchronously reapply defaults just after a
                // preset switch. Retry once without waiting for the watchdog.
                directGeneration = UUID()
                let generation = directGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.directGeneration == generation else { return }
                    self.maintainDirectBrightness()
                }
                status = "Direct XDR upscaling enabled. Original settings will be restored when it stops."
            } catch { self.error = error.localizedDescription }
            return
        }
        guard displays[index].hdrSupported, let screen = screen(for: id) else {
            error = "This display does not currently expose HDR support. For an external HDR display, enable HDR in macOS Display Settings first."
            return
        }
        do {
            if let original = brightness.get(id) {
                overlayBrightnessSnapshots[id] = original
                try brightness.set(id, value: 1)
            }
            let overlay = try HDRBoostWindow(screen: screen, gain: displays[index].hdrGain)
            let token = overlay.token
            overlay.surface.onFailure = { [weak self] message in
                guard let self, self.hdrOverlays[id]?.token == token else { return }
                self.setHDR(false, for: id); self.error = message
            }
            hdrOverlays[id] = overlay
            displays[index].hdrEnabled = true
            displays[index].brightness = brightness.get(id)
            status = "HDR boost enabled. Gain is limited by current display headroom."
        } catch { setHDR(false, for: id); self.error = error.localizedDescription }
    }

    func setHDRGain(_ gain: Double, for id: CGDirectDisplayID) {
        guard gain.isFinite, let index = displays.firstIndex(where: { $0.id == id }) else { return }
        let maximum = displays[index].upscalingMethod == .direct ? displays[index].directMaximumGain : 2
        let bounded = min(maximum, max(1, gain))
        displays[index].hdrGain = bounded
        hdrOverlays[id]?.surface.requestedGain = bounded
        if directBrightness.activeDisplayID == id {
            do { try directBrightness.update(gain: bounded); displays[index].hdrApplied = bounded }
            catch { setHDR(false, for: id); self.error = error.localizedDescription }
        }
    }

    func setUpscalingMethod(_ method: UpscalingMethod, for id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }), displays[index].upscalingMethod != method else { return }
        guard method == .direct ? displays[index].directSupported : displays[index].hdrSupported else {
            error = "This upscaling method is unavailable on the selected display."
            return
        }
        let wasEnabled = displays[index].hdrEnabled
        setHDR(false, for: id)
        guard !directBrightness.needsRestore, overlayBrightnessSnapshots[id] == nil else { return }
        displays[index].upscalingMethod = method
        if wasEnabled { setHDR(true, for: id) }
    }

    func setCombinedBrightness(_ value: Double, for id: CGDirectDisplayID) {
        guard value.isFinite, let index = displays.firstIndex(where: { $0.id == id }) else { return }
        let maximum = displays[index].upscalingSupported ? (displays[index].upscalingMethod == .direct ? displays[index].directMaximumGain : 2) : 1
        let bounded = BrightnessScale.bounded(value, maximum: maximum)
        if bounded > 1 {
            setHDRGain(bounded, for: id)
            setHDR(true, for: id)
            if displays[index].hdrEnabled { setDimming(1, for: id) }
        } else {
            setHDR(false, for: id)
            if displays[index].brightness != nil { setBrightness(bounded, for: id); setDimming(1, for: id) }
            else { setDimming(bounded, for: id) }
        }
    }

    func disableAllHDR() {
        for display in displays where display.hdrEnabled || overlayBrightnessSnapshots[display.id] != nil { setHDR(false, for: display.id) }
        if directBrightness.active {
            do { try directBrightness.disable() } catch { self.error = error.localizedDescription }
        }
        if directBrightness.needsRestore {
            do { try directBrightness.recoverIfNeeded(displays: displays.map { ($0.id, $0.uuid) }) }
            catch { self.error = error.localizedDescription }
        }
        directPulse?.close()
    }

    func hdrDiagnostics() -> String {
        let data: [[String: Any]] = displays.map { display in
            let overlay = hdrOverlays[display.id]
            let surface = overlay?.surface
            return ["display": display.name, "supported": display.hdrSupported,
                    "currentHeadroom": display.edrCurrent, "potentialHeadroom": display.edrPotential,
                    "enabled": display.hdrEnabled, "requestedGain": display.hdrGain,
                    "method": display.upscalingMethod.rawValue,
                    "directSupported": display.directSupported, "directMaximumGain": display.directMaximumGain,
                    "directTargetNits": directBrightness.activeDisplayID == display.id ? (directBrightness.targetNits as Any? ?? NSNull()) : NSNull(),
                    "directRecoveryPending": directBrightness.needsRestore,
                    "directError": directBrightness.lastRecoveryError as Any? ?? NSNull(),
                    "driverState": directBrightness.diagnostics(for: display.id),
                    "controllerError": error as Any? ?? NSNull(),
                    "appliedGain": display.upscalingMethod == .direct ? display.hdrApplied : surface?.appliedGain ?? 1,
                    "completedMetalFrames": surface?.completedFrames ?? 0,
                    "overlayOnActiveSpace": overlay?.window.isOnActiveSpace ?? false,
                    "overlayVisible": overlay?.window.isVisible ?? false,
                    "overlayOcclusionVisible": overlay?.window.occlusionState.contains(.visible) ?? false,
                    "overlayCanBecomeKey": overlay?.window.canBecomeKey ?? false,
                    "overlayIsKey": overlay?.window.isKeyWindow ?? false,
                    "applicationActive": NSApplication.shared.isActive,
                    "renderError": surface?.lastError as Any? ?? NSNull()]
        }
        let dataBytes = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
        return dataBytes.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
