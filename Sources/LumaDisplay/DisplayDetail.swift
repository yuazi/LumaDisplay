import SwiftUI
import DisplayCore

struct DisplayDetail: View {
    @EnvironmentObject var controller: DisplayController
    let display: DisplayDevice
    @ViewState private var stagedModeID: String
    init(display: DisplayDevice) {
        self.display = display
        _stagedModeID = State(initialValue: display.current.id)
    }
    private var chosen: DisplayOption { display.modes.first { $0.id == stagedModeID } ?? display.current }
    private func geometry(_ mode: DisplayOption) -> String {
        let d = mode.descriptor
        return "\(d.width)x\(d.height)-\(d.pixelWidth)x\(d.pixelHeight)"
    }
    private var resolutions: [DisplayOption] {
        var seen = Set<String>()
        return display.modes.filter { seen.insert(geometry($0)).inserted }
    }
    private var refreshOptions: [DisplayOption] { display.modes.filter { geometry($0) == geometry(chosen) } }
    private var quickResolutions: [DisplayOption] {
        let retina = resolutions.filter { $0.descriptor.isHiDPI }
        let source = retina.isEmpty ? resolutions : retina
        if source.count <= 5 { return source }
        var indexes = Set((0..<5).map { Int((Double($0) * Double(source.count - 1) / 4).rounded()) })
        if let current = source.firstIndex(where: { geometry($0) == geometry(display.current) }), !indexes.contains(current) {
            if let closest = indexes.min(by: { abs($0 - current) < abs($1 - current) }) { indexes.remove(closest) }
            indexes.insert(current)
        }
        return indexes.sorted().map { source[$0] }
    }
    private func selectResolution(_ id: String) {
        let candidates = display.modes.filter { geometry($0) == id }
        let best = candidates.min { abs($0.descriptor.refreshRate - chosen.descriptor.refreshRate) < abs($1.descriptor.refreshRate - chosen.descriptor.refreshRate) }
        if let best { stagedModeID = best.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(display.name).font(.system(size: 27, weight: .semibold)).tracking(-0.7)
                    Text(display.builtIn ? "Your built-in display. Tuned to you." : "More room for everything you do.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(Palette.green).frame(width: 5, height: 5)
                    Text(display.main ? "MAIN DISPLAY" : "CONNECTED").font(.system(size: 9, weight: .semibold)).tracking(1)
                }.foregroundStyle(Palette.green).padding(.horizontal, 12).padding(.vertical, 8).background(Palette.green.opacity(0.07), in: Capsule())
            }
            overview
            hdrCard
            HStack(alignment: .top, spacing: 16) { brightnessCard; warmthCard }
            resolutionCard
            HStack(spacing: 7) {
                Image(systemName: "checkmark.shield")
                Text("Resolution changes include a 15-second preview. Dimming resets when you quit.")
            }.font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
        .onChange(of: display.current.id) { stagedModeID = $0 }
    }

    private var overview: some View {
        HStack(spacing: 30) {
            MonitorArtwork(builtIn: display.builtIn).frame(width: 260, height: 150).padding(.leading, 10)
            VStack(alignment: .leading, spacing: 23) {
                HStack {
                    Label(display.builtIn ? "Built-in display" : "External display", systemImage: display.builtIn ? "laptopcomputer" : "cable.connector").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Spacer()
                }
                HStack(alignment: .top, spacing: 30) {
                    stat("RESOLUTION", display.current.descriptor.resolution, suffix: "logical workspace")
                    stat("REFRESH RATE", display.current.descriptor.refreshLabel, suffix: "current mode")
                }
                HStack(spacing: 7) {
                    tag(display.current.descriptor.isHiDPI ? "HiDPI" : "Standard DPI", icon: "sparkles")
                    tag("\(display.current.descriptor.pixelWidth) × \(display.current.descriptor.pixelHeight) px", icon: "viewfinder")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(22).frame(maxWidth: .infinity).card()
    }

    private func stat(_ title: String, _ value: String, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 8, weight: .semibold)).tracking(1.4).foregroundStyle(Palette.muted)
            Text(value).font(.system(size: 18, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            Text(suffix).font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
    }
    private func tag(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.accent)
            .padding(.horizontal, 8).padding(.vertical, 5).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
    }

    private var brightnessCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardHeading("Brightness", subtitle: display.brightness != nil ? "Find your comfortable level." : "Software dimming for this display.", icon: "sun.max")
            if let brightness = display.brightness {
                sliderRow("Hardware brightness", value: brightness, range: 0.05...1, low: "sun.min", high: "sun.max.fill") { controller.setBrightness($0, for: display.id) }
            } else {
                Label("Hardware control unavailable", systemImage: "info.circle").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            sliderRow("Software brightness", value: display.dimming, range: 0.2...1, low: "moon", high: "sun.max") { controller.setDimming($0, for: display.id) }
        }.padding(21).frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading).card()
    }

    private var hdrCard: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .center) {
                cardHeading("HDR extra brightness", subtitle: display.hdrSupported ? "Go beyond the normal desktop brightness." : "This display is currently using an SDR range.", icon: "sun.max.trianglebadge.exclamationmark")
                Text("EXPERIMENTAL").font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(Palette.accent).padding(.horizontal, 9).padding(.vertical, 6).background(Palette.accent.opacity(0.08), in: Capsule())
                Toggle("HDR boost", isOn: Binding(get: { display.hdrEnabled }, set: { controller.setHDR($0, for: display.id) }))
                    .toggleStyle(.switch).labelsHidden().disabled(!display.hdrSupported)
            }
            if display.hdrSupported {
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Desktop gain").foregroundStyle(Palette.muted)
                            Spacer()
                            Text("\(Int((display.hdrGain * 100).rounded()))%").monospacedDigit()
                        }.font(.system(size: 11))
                        Slider(value: Binding(get: { display.hdrGain }, set: { controller.setHDRGain($0, for: display.id) }), in: 1...2, step: 0.01)
                            .disabled(!display.hdrEnabled).accessibilityLabel("HDR desktop gain")
                        HStack { Text("100% · Standard"); Spacer(); Text("200% · Extra bright") }.font(.system(size: 9)).foregroundStyle(Palette.muted)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(display.hdrEnabled ? "\(Int((display.hdrApplied * 100).rounded()))% applied" : "Boost is off")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(display.hdrEnabled ? Palette.green : Palette.muted)
                        Text(String(format: "%.2f× current headroom", display.edrCurrent)).font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }.frame(width: 148, alignment: .leading).padding(.leading, 5)
                }
                Text("Uses HDR headroom for desktop content. May affect HDR highlights and use more power. Turn off for color-critical work; resets on quit or sleep.")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Requires an XDR display or a compatible external display with HDR enabled in macOS. Ordinary SDR displays cannot be boosted.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(21).card()
    }

    private var warmthCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardHeading("A warmer workspace", subtitle: "Take the edge off after hours.", icon: "sun.haze")
            sliderRow("Warmth", value: display.warmth, range: 0...1, low: "snowflake", high: "sun.haze.fill") { controller.setWarmth($0, for: display.id) }
            HStack(spacing: 8) {
                warmthButton("Neutral", value: 0)
                warmthButton("Soft", value: 0.35)
                warmthButton("Evening", value: 0.7)
            }
            Text("A gentle color overlay, applied to this display.").font(.system(size: 9)).foregroundStyle(Palette.muted)
        }.padding(21).frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading).card()
    }

    private func cardHeading(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Palette.accent).frame(width: 27, height: 29)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
        }
    }

    private func sliderRow(_ title: String, value: Double, range: ClosedRange<Double>, low: String, high: String, set: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 7) {
            HStack {
                Text(title).foregroundStyle(Palette.muted)
                Spacer()
                Text("\(Int((value * 100).rounded()))%").monospacedDigit().foregroundStyle(.white)
            }.font(.system(size: 10))
            HStack(spacing: 8) {
                Image(systemName: low).font(.system(size: 11)).foregroundStyle(Palette.muted)
                Slider(value: Binding(get: { value }, set: set), in: range).controlSize(.small).accessibilityLabel(title)
                Image(systemName: high).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
        }
    }
    private func warmthButton(_ title: String, value: Double) -> some View {
        Button { controller.setWarmth(value, for: display.id) } label: {
            Text(title).font(.system(size: 10)).frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(abs(display.warmth - value) < 0.02 ? Palette.accent.opacity(0.14) : Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(abs(display.warmth - value) < 0.02 ? Palette.accent : Palette.muted)
        }.buttonStyle(.plain)
    }

    private var resolutionCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                cardHeading("Resolution & scaling", subtitle: "The right balance of space and sharpness.", icon: "arrow.up.left.and.arrow.down.right")
                Text("\(display.modes.count) modes").font(.system(size: 9)).foregroundStyle(Palette.muted).padding(7).background(.white.opacity(0.035), in: Capsule())
            }
            HStack(spacing: 10) {
                ForEach(Array(quickResolutions.enumerated()), id: \.element.id) { index, mode in
                    Button { selectResolution(geometry(mode)) } label: {
                        VStack(spacing: 8) {
                            Text("Aa").font(.system(size: CGFloat(28 - index * 3), weight: .medium, design: .rounded)).frame(height: 31)
                            Text("\(mode.descriptor.width) × \(mode.descriptor.height)").font(.system(size: 9, weight: .medium))
                            Text(geometry(mode) == geometry(display.current) ? "Current" : mode.descriptor.isHiDPI ? "HiDPI" : "Standard").font(.system(size: 8)).foregroundStyle(Palette.muted)
                        }.frame(maxWidth: .infinity).padding(.vertical, 12)
                            .foregroundStyle(geometry(chosen) == geometry(mode) ? Palette.accent : .white.opacity(0.75))
                            .background(geometry(chosen) == geometry(mode) ? Palette.accent.opacity(0.1) : Color.white.opacity(0.015), in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(geometry(chosen) == geometry(mode) ? Palette.accent.opacity(0.65) : Palette.line, lineWidth: 1))
                    }.buttonStyle(.plain).accessibilityLabel("Stage \(mode.descriptor.resolution) resolution")
                }
            }
            HStack {
                Text("Larger text"); Spacer(); Text("More space")
            }.font(.system(size: 9)).foregroundStyle(Palette.muted).padding(.top, -10)
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("RESOLUTION").font(.system(size: 8, weight: .semibold)).tracking(1.1).foregroundStyle(Palette.muted)
                    Picker("Resolution", selection: Binding(get: { geometry(chosen) }, set: selectResolution)) {
                        ForEach(resolutions) { mode in
                            Text("\(mode.descriptor.resolution)\(mode.descriptor.isHiDPI ? " · HiDPI" : "")").tag(geometry(mode))
                        }
                    }.labelsHidden().frame(maxWidth: .infinity)
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 7) {
                    Text("REFRESH RATE").font(.system(size: 8, weight: .semibold)).tracking(1.1).foregroundStyle(Palette.muted)
                    Picker("Refresh rate", selection: $stagedModeID) {
                        ForEach(refreshOptions) { mode in Text(mode.descriptor.refreshLabel).tag(mode.id) }
                    }.labelsHidden().frame(width: 143)
                }
                Button { controller.previewMode(stagedModeID, for: display.id) } label: {
                    Label("Preview changes", systemImage: "arrow.right").font(.system(size: 11, weight: .medium)).padding(.vertical, 3)
                }.buttonStyle(.borderedProminent).disabled(chosen.id == display.current.id || controller.previewPending || display.mirrored)
            }
            if display.mirrored { Text("This display is mirrored. Change its mode in macOS Display Settings.").font(.caption).foregroundStyle(Palette.muted) }
        }.padding(21).card()
    }
}

struct MonitorArtwork: View {
    let builtIn: Bool
    var body: some View {
        ZStack {
            Ellipse().fill(Palette.accent.opacity(0.10)).frame(width: 230, height: 90).blur(radius: 28).offset(y: 20)
            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(Color(red: 0.20, green: 0.22, blue: 0.28))
                    RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.025, green: 0.03, blue: 0.05)).padding(1)
                    landscape.padding(6)
                    Circle().fill(.white.opacity(0.2)).frame(width: 2, height: 2).offset(y: -62)
                }.frame(width: 222, height: 140)
                if builtIn {
                    UnevenBase().fill(LinearGradient(colors: [.gray, Color(white: 0.28)], startPoint: .top, endPoint: .bottom)).frame(width: 250, height: 7)
                } else {
                    Rectangle().fill(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.15)], startPoint: .top, endPoint: .bottom)).frame(width: 28, height: 12)
                    Capsule().fill(Color(white: 0.28)).frame(width: 80, height: 3)
                }
            }
        }.accessibilityHidden(true)
    }
    private var landscape: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                LinearGradient(colors: [Color(red: 0.15, green: 0.17, blue: 0.36), Color(red: 0.48, green: 0.39, blue: 0.65), Color(red: 0.85, green: 0.55, blue: 0.52)], startPoint: .top, endPoint: .bottom)
                Circle().fill(Color(red: 0.98, green: 0.77, blue: 0.65)).frame(width: 38, height: 38).blur(radius: 0.5).offset(x: 35, y: -7)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h * 0.8))
                    path.addCurve(to: CGPoint(x: w, y: h * 0.66), control1: CGPoint(x: w * 0.3, y: h * 0.15), control2: CGPoint(x: w * 0.7, y: h * 1.05))
                    path.addLine(to: CGPoint(x: w, y: h)); path.addLine(to: CGPoint(x: 0, y: h)); path.closeSubpath()
                }.fill(Color(red: 0.28, green: 0.27, blue: 0.48))
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h * 0.84))
                    path.addCurve(to: CGPoint(x: w, y: h * 0.72), control1: CGPoint(x: w * 0.55, y: h * 1.1), control2: CGPoint(x: w * 0.8, y: h * 0.45))
                    path.addLine(to: CGPoint(x: w, y: h)); path.addLine(to: CGPoint(x: 0, y: h)); path.closeSubpath()
                }.fill(Color(red: 0.11, green: 0.15, blue: 0.28))
            }.clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

struct UnevenBase: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: rect.width, y: 0))
            p.addQuadCurve(to: CGPoint(x: rect.width - 14, y: rect.height), control: CGPoint(x: rect.width - 3, y: rect.height))
            p.addLine(to: CGPoint(x: 14, y: rect.height)); p.addQuadCurve(to: .zero, control: CGPoint(x: 3, y: rect.height)); p.closeSubpath()
        }
    }
}
