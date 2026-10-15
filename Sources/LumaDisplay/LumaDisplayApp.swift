import SwiftUI
import AppKit
import DisplayCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static let controller = DisplayController()
    private var verificationTimer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.controller.refresh()
        if ProcessInfo.processInfo.arguments.contains("--diagnose") {
            print(Self.controller.diagnostics())
            NSApplication.shared.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--diagnose-hdr") {
            print(Self.controller.hdrDiagnostics())
            NSApplication.shared.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-hdr") || ProcessInfo.processInfo.arguments.contains("--verify-direct") {
            // A bounded, explicit smoke test. The optional duration allows manual
            // Space/full-screen transitions while diagnostics report our own overlay.
            let arguments = ProcessInfo.processInfo.arguments
            var duration = 3.0
            if let option = arguments.firstIndex(of: "--verify-hdr-seconds"),
               arguments.indices.contains(option + 1),
               let seconds = Double(arguments[option + 1]), seconds.isFinite {
                duration = min(60, max(3, seconds))
            }
            NSApplication.shared.setActivationPolicy(.regular)
            let direct = arguments.contains("--verify-direct")
            if let display = Self.controller.displays.first(where: { direct ? $0.directSupported : $0.hdrSupported }) {
                Self.controller.setUpscalingMethod(direct ? .direct : .hdrOverlay, for: display.id)
                Self.controller.setHDRGain(1.1, for: display.id)
                Self.controller.setHDR(true, for: display.id)
            }
            if duration > 3 {
                let timer = Timer(timeInterval: 1, repeats: true) { _ in
                    Task { @MainActor in
                        print(Self.controller.hdrDiagnostics())
                        fflush(stdout)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                verificationTimer = timer
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                self?.verificationTimer?.invalidate()
                self?.verificationTimer = nil
                print(Self.controller.hdrDiagnostics())
                Self.controller.disableAllHDR()
                if direct { print("RESTORED\n" + Self.controller.hdrDiagnostics()) }
                NSApplication.shared.terminate(nil)
            }
            return
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows where window.canBecomeMain {
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.09, alpha: 1)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.controller.prepareToQuit() ? .terminateNow : .terminateCancel
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // MenuBarExtra can be visible while the dashboard is closed. Its panel
        // must not prevent a launcher or Dock click from restoring the dashboard.
        if let dashboard = sender.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            if dashboard.isMiniaturized { dashboard.deminiaturize(nil) }
            dashboard.makeKeyAndOrderFront(nil)
            sender.activate(ignoringOtherApps: true)
        }
        return true
    }
}

@main @MainActor struct LumaDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = AppDelegate.controller
    var body: some Scene {
        Window("LumaDisplay", id: "main") {
            Dashboard().environmentObject(controller).preferredColorScheme(.dark)
        }
        .defaultSize(width: 1120, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Displays") {
                Button("Refresh Displays") { controller.refresh() }.keyboardShortcut("r")
                Button("Identify Displays") { controller.identifyDisplays() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Reset HDR, Dimming & Warmth") { controller.resetAppearance() }.keyboardShortcut("0", modifiers: [.command, .shift])
                Divider()
                Button("Open Display Settings") { controller.openSystemSettings() }
            }
        }
        MenuBarExtra("LumaDisplay", systemImage: "display") {
            QuickControls().environmentObject(controller).preferredColorScheme(.dark)
        }.menuBarExtraStyle(.window)
    }
}

struct QuickControls: View {
    @EnvironmentObject var controller: DisplayController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { BrandMark(size: 28); Text("LumaDisplay").font(.headline); Spacer() }
            if controller.previewPending { PreviewBanner() }
            ForEach(controller.displays) { display in
                VStack(alignment: .leading, spacing: 8) {
                    Label(display.name, systemImage: display.builtIn ? "laptopcomputer" : "display").font(.headline)
                    if display.brightness != nil || display.upscalingSupported {
                        HStack {
                            Image(systemName: "sun.max")
                            Slider(value: Binding(get: { display.combinedBrightness }, set: { controller.setCombinedBrightness($0, for: display.id) }), in: (display.brightness != nil ? 0.05 : 0.2)...(display.upscalingSupported ? (display.upscalingMethod == .direct ? max(1.01, display.directMaximumGain) : 2) : 1))
                            Text("\(Int((display.combinedBrightness * 100).rounded()))%").monospacedDigit().frame(width: 40)
                        }.accessibilityLabel("\(display.name) brightness")
                    }
                    HStack {
                        Text("Dimming").font(.caption).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { display.dimming }, set: { controller.setDimming($0, for: display.id) }), in: 0.2...1)
                    }.accessibilityLabel("\(display.name) software brightness")
                    if display.upscalingSupported {
                        Picker("Upscaling", selection: Binding(get: { display.upscalingMethod }, set: { controller.setUpscalingMethod($0, for: display.id) })) {
                            Text("HDR overlay").tag(UpscalingMethod.hdrOverlay).disabled(!display.hdrSupported)
                            Text("Direct XDR").tag(UpscalingMethod.direct).disabled(!display.directSupported)
                        }.font(.caption)
                        Toggle("Brightness upscaling", isOn: Binding(get: { display.hdrEnabled }, set: { controller.setHDR($0, for: display.id) })).font(.caption)
                        if display.hdrEnabled {
                            HStack {
                                Slider(value: Binding(get: { display.hdrGain }, set: { controller.setHDRGain($0, for: display.id) }), in: 1...(display.upscalingMethod == .direct ? max(1.01, display.directMaximumGain) : 2), step: 0.01).accessibilityLabel("Brightness upscaling level")
                                Text("\(Int((display.hdrApplied * 100).rounded()))%").font(.caption).monospacedDigit().frame(width: 40)
                            }
                        }
                    }
                }
            }
            if !controller.presets.isEmpty {
                Menu("Apply preset") {
                    ForEach(controller.presets) { preset in Button(preset.name) { controller.applyPreset(preset) } }
                }.disabled(controller.previewPending)
            }
            Divider()
            Button("Open LumaDisplay") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }.buttonStyle(.borderedProminent)
            HStack {
                Button("Reset all effects") { controller.resetAppearance() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            }.buttonStyle(.plain).font(.caption)
        }.padding(20).frame(width: 340).tint(Palette.accent)
        .alert("Display control", isPresented: Binding(get: { controller.error != nil }, set: { if !$0 { controller.error = nil } })) {
            Button("OK") { controller.error = nil }
        } message: { Text(controller.error ?? "") }
    }
}
