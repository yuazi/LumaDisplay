import AppKit
import QuartzCore

/// Brief EDR window activity keeps the direct display path represented in the
/// compositor across app/Space transitions. It never takes focus or input.
@MainActor final class HDRActivityPulse {
    private let window: DisplayOverlayPanel
    private var generation = 0
    init() {
        window = DisplayOverlayPanel(frame: .zero, level: NSWindow.Level(rawValue: Int(CGShieldingWindowLevel())))
        window.title = "LumaDisplay brightness activity"
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.wantsLayer = true
        let layer = CAMetalLayer()
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        layer.wantsExtendedDynamicRangeContent = true
        layer.backgroundColor = NSColor(white: 0.5, alpha: 1).cgColor
        view.layer = layer
        window.contentView = view
    }
    func pulse(on screen: NSScreen) {
        generation += 1
        let token = generation
        window.alphaValue = 0.05
        window.present(on: NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 1, height: 1))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 15) { [weak self] in
            guard let self, self.generation == token else { return }
            self.window.orderOut(nil)
        }
    }
    func close() { generation += 1; window.orderOut(nil) }
}
