import SwiftUI
import DisplayCore

// Explicit alias selects the back-deployable property wrapper rather than the
// new State macro exposed by beta SDKs whose macro plugin is absent in CLT.
typealias ViewState<Value> = SwiftUI.State<Value>

enum Palette {
    static let base = Color(red: 0.055, green: 0.065, blue: 0.09)
    static let sidebar = Color(red: 0.075, green: 0.085, blue: 0.115)
    static let card = Color(red: 0.09, green: 0.105, blue: 0.14)
    static let accent = Color(red: 0.66, green: 0.64, blue: 1)
    static let muted = Color(red: 0.57, green: 0.61, blue: 0.69)
    static let line = Color.white.opacity(0.07)
    static let green = Color(red: 0.41, green: 0.85, blue: 0.69)
}

struct BrandMark: View {
    var size: CGFloat = 34
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28).fill(LinearGradient(colors: [Palette.accent, Color(red: 0.39, green: 0.44, blue: 0.91)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "display").font(.system(size: size * 0.52, weight: .medium)).foregroundStyle(.white)
        }.frame(width: size, height: size)
    }
}

struct Dashboard: View {
    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    @EnvironmentObject var controller: DisplayController
    @ViewState private var page = "displays"
    @ViewState private var showingSave = false
    @ViewState private var presetName = ""
    @ViewState private var showingAbout = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 226)
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if controller.previewPending { PreviewBanner() }
                        if page == "presets" { presetsPage }
                        else if let display = controller.selected {
                            DisplayDetail(display: display).id(display.id)
                        } else { emptyDisplays }
                    }.padding(30)
                }
                footer
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.base)
        }
        .frame(minWidth: 1000, minHeight: 720)
        .tint(Palette.accent)
        .sheet(isPresented: $showingSave) { saveSheet }
        .alert("Display control", isPresented: Binding(get: { controller.error != nil }, set: { if !$0 { controller.error = nil } })) {
            Button("OK") { controller.error = nil }
        } message: { Text(controller.error ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark()
                VStack(alignment: .leading, spacing: 2) {
                    Text("LumaDisplay").font(.system(size: 16, weight: .semibold))
                    Text("A little more clarity.").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
            }.padding(.top, 49).padding(.bottom, 37).padding(.horizontal, 22)
            Text("WORKSPACE").font(.system(size: 9, weight: .bold)).tracking(1.8).foregroundStyle(Palette.muted).padding(.horizontal, 23).padding(.bottom, 12)
            navRow("Displays", icon: "display.2", selected: page == "displays") { page = "displays" }
            navRow("Presets", icon: "square.stack.3d.up", selected: page == "presets") { page = "presets" }
            HStack {
                Text("CONNECTED").font(.system(size: 9, weight: .bold)).tracking(1.8)
                Spacer()
                Text("\(controller.displays.count)").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(.white.opacity(0.06), in: Capsule())
            }.foregroundStyle(Palette.muted).padding(.horizontal, 23).padding(.top, 34).padding(.bottom, 12)
            ForEach(Array(controller.displays.enumerated()), id: \.element.id) { index, display in
                Button {
                    controller.selectedID = display.id; page = "displays"
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: display.builtIn ? "laptopcomputer" : "display").font(.system(size: 17)).frame(width: 23)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(display.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text(display.current.descriptor.resolution).font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                        Spacer(minLength: 0)
                        Circle().fill(Palette.green).frame(width: 5, height: 5)
                    }.foregroundStyle(controller.selectedID == display.id ? .white : Palette.muted)
                        .padding(12).background(controller.selectedID == display.id && page == "displays" ? Color.white.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 4)
                .accessibilityLabel("Display \(index + 1): \(display.name)")
            }
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) { Circle().fill(Palette.green).frame(width: 5, height: 5); Text("All systems in view").font(.system(size: 11, weight: .medium)) }
                Text("Changes stay on your Mac.").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12)).padding(14)
            Button { showingAbout.toggle() } label: {
                HStack { Image(systemName: "info.circle"); Text("About LumaDisplay"); Spacer(); Text(appVersion).foregroundStyle(Palette.muted) }
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }.buttonStyle(.plain).padding(.horizontal, 24).padding(.bottom, 22)
                .popover(isPresented: $showingAbout) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("LumaDisplay \(appVersion)").font(.headline)
                        Text("Display controls for macOS, built with SwiftUI and native display APIs.")
                        Text("Supports existing display modes, hardware brightness when available, experimental HDR boost, software dimming, warmth, and local presets. DDC and virtual displays are not included.").foregroundStyle(.secondary)
                        Text("HDR rendering uses BrightIntosh’s Metal technique. LumaDisplay is GPL-3.0 licensed; see the included source and notices.").font(.caption).foregroundStyle(.secondary)
                    }.font(.callout).padding(24).frame(width: 340)
                }
        }.background(Palette.sidebar)
    }

    private func navRow(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 20)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                if selected { RoundedRectangle(cornerRadius: 2).fill(Palette.accent).frame(width: 3, height: 15) }
            }.foregroundStyle(selected ? Palette.accent : Palette.muted).padding(.horizontal, 14).padding(.vertical, 12)
                .background(selected ? Palette.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 4)
    }

    private var header: some View {
        HStack {
            Text(page == "displays" ? "Display workspace" : "Your presets").font(.system(size: 13, weight: .medium))
            Spacer()
            Button { controller.identifyDisplays() } label: { Label("Identify", systemImage: "viewfinder") }
                .buttonStyle(.plain).foregroundStyle(Palette.muted).help("Show the number and name on every connected display")
            Button { controller.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(Palette.muted).padding(.horizontal, 12).help("Refresh displays")
            Button { presetName = ""; showingSave = true } label: { Label("Save preset", systemImage: "plus") }
                .buttonStyle(.bordered).disabled(controller.displays.isEmpty || controller.previewPending)
        }.font(.system(size: 11)).padding(.horizontal, 30).padding(.top, 24).padding(.bottom, 18)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(Palette.green).frame(width: 5, height: 5)
            Text(controller.status).lineLimit(1)
            Spacer()
            Button("macOS display settings ↗") { controller.openSystemSettings() }.buttonStyle(.plain)
        }.font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.horizontal, 30).padding(.vertical, 14)
            .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private var emptyDisplays: some View {
        VStack(spacing: 15) {
            Image(systemName: "display.trianglebadge.exclamationmark").font(.system(size: 40)).foregroundStyle(Palette.accent)
            Text("No displays available").font(.title2)
            Text("Connect a display and refresh to get started.").foregroundStyle(Palette.muted)
            Button("Refresh displays") { controller.refresh() }
        }.frame(maxWidth: .infinity).padding(.vertical, 100)
    }

    private var presetsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("A workspace for every moment.").font(.system(size: 27, weight: .semibold))
            Text("Save your displays, resolution, brightness, and warmth together.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            if controller.presets.isEmpty {
                VStack(spacing: 18) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 38)).foregroundStyle(Palette.accent)
                    Text("Make yourself comfortable.").font(.system(size: 19, weight: .medium))
                    Text("Set up your displays, then save your first preset.\nYour settings will be ready when you need them.").multilineTextAlignment(.center).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Button("Save current workspace") { showingSave = true }.buttonStyle(.borderedProminent).disabled(controller.displays.isEmpty || controller.previewPending)
                }.frame(maxWidth: .infinity).padding(.vertical, 66).card()
            }
            ForEach(controller.presets) { preset in
                HStack(spacing: 16) {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 22)).foregroundStyle(Palette.accent).frame(width: 48, height: 48).background(Palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(preset.name).font(.system(size: 15, weight: .semibold))
                        Text(preset.displays.map(\.name).joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Text(preset.createdAt, style: .date).font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Button("Apply") { controller.applyPreset(preset) }.buttonStyle(.bordered).disabled(controller.previewPending)
                    Menu { Button("Delete preset", role: .destructive) { controller.deletePreset(preset) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                }.padding(22).card()
            }
            Label("If a saved display is disconnected, connect it before applying its preset.", systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) { BrandMark(); Text("Save your workspace").font(.title2.weight(.semibold)) }
            Text("Capture the current settings for all \(controller.displays.count) connected displays.").font(.callout).foregroundStyle(.secondary)
            TextField("Preset name, e.g. Evening focus", text: $presetName).textFieldStyle(.roundedBorder).onSubmit { save() }
            HStack {
                Spacer()
                Button("Cancel") { showingSave = false }.keyboardShortcut(.cancelAction)
                Button("Save preset") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.previewPending)
            }
        }.padding(30).frame(width: 400)
    }
    private func save() {
        guard !presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        controller.savePreset(name: presetName); showingSave = false
    }
}

struct PreviewBanner: View {
    @EnvironmentObject var controller: DisplayController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(controller.rollbackFailed ? "Restore needs attention" : "Keep these display settings?", systemImage: "timer").font(.system(size: 14, weight: .semibold))
            Text(controller.rollbackFailed ? "macOS could not restore the previous mode. Retry or open Display Settings." : "Reverting automatically in \(controller.secondsRemaining) seconds.").font(.system(size: 12)).monospacedDigit()
            HStack {
                Button(controller.rollbackFailed ? "Retry revert" : "Revert") { controller.revertPreview() }.keyboardShortcut(.cancelAction)
                Button("Keep changes") { controller.keepPreview() }.buttonStyle(.borderedProminent).disabled(controller.rollbackFailed)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(Palette.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }
}

extension View {
    func card() -> some View {
        self.background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
    }
}
