// The Metal multiply-overlay technique is adapted from BrightIntosh by
// Niklas Rousset and contributors, under GPL-3.0. See THIRD_PARTY_NOTICES.md.
// LumaDisplay adds bounded dynamic gain, lifecycle ownership and error handling.
import AppKit
import MetalKit
import DisplayCore

final class HDRSurface: MTKView, MTKViewDelegate {
    private let queue: MTLCommandQueue
    private var missedFrames = 0
    private var firstFrame = true
    var requestedGain: Double = 1.25
    private(set) var appliedGain: Double = 1
    private(set) var completedFrames = 0
    private(set) var lastError: String?
    var onFailure: ((String) -> Void)?
    var onReady: (() -> Void)?

    init(size: CGSize) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw DisplayFailure.message("Metal rendering is unavailable on this Mac.")
        }
        self.queue = queue
        super.init(frame: CGRect(origin: .zero, size: size), device: device)
        colorPixelFormat = .rgba16Float
        colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        // A uniform 2×2 floating-point texture fills the window; no full-screen
        // capture, shaders or full-resolution video processing are required.
        autoResizeDrawable = false
        drawableSize = CGSize(width: 2, height: 2)
        preferredFramesPerSecond = 10
        autoresizingMask = [.width, .height]
        clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        guard let metalLayer = layer as? CAMetalLayer else {
            throw DisplayFailure.message("The HDR Metal layer could not be created.")
        }
        metalLayer.isOpaque = false
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.compositingFilter = "multiply"
        delegate = self
    }
    required init(coder: NSCoder) { fatalError("Use init(size:)") }

    func draw(in view: MTKView) {
        let available = Double(window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        appliedGain = HDRGain.effective(requested: requestedGain, currentHeadroom: available)
        clearColor = MTLClearColor(red: appliedGain, green: appliedGain, blue: appliedGain, alpha: 1)
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable else {
            missedFrames += 1
            if missedFrames == 30 { fail("macOS stopped providing HDR rendering surfaces. HDR boost has been turned off.") }
            return
        }
        missedFrames = 0
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            fail("The GPU could not render HDR boost. HDR boost has been turned off."); return
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.addCompletedHandler { [weak self] result in
            let succeeded = result.status == .completed
            let message = result.error?.localizedDescription ?? "The HDR render did not complete."
            DispatchQueue.main.async {
                guard let self, !self.isPaused else { return }
                if succeeded {
                    self.completedFrames += 1
                    if self.firstFrame { self.firstFrame = false; self.onReady?(); self.onReady = nil }
                } else { self.fail(message) }
            }
        }
        buffer.commit()
    }
    private func fail(_ message: String) {
        guard lastError == nil else { return }
        lastError = message
        isPaused = true
        DispatchQueue.main.async { [weak self] in self?.onFailure?(message) }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }
    func stop() {
        isPaused = true; delegate = nil; onFailure = nil; onReady = nil
        (layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = false
    }
}

final class HDRBoostWindow {
    let token = UUID()
    let window: NSWindow
    let surface: HDRSurface
    init(screen: NSScreen, gain: Double) throws {
        surface = try HDRSurface(size: screen.frame.size)
        surface.requestedGain = gain
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.title = "LumaDisplay HDR overlay"
        window.backgroundColor = .clear; window.isOpaque = false
        window.hasShadow = false; window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.sharingType = .none
        window.animationBehavior = .none
        window.contentView = surface
        // Keep an initial surface invisible until its first GPU submission has completed.
        window.alphaValue = 0.001
        surface.onReady = { [weak window] in window?.alphaValue = 1 }
        window.orderFrontRegardless()
        surface.draw()
    }
    func update(screen: NSScreen, gain: Double) {
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
        surface.requestedGain = gain
    }
    func close() { surface.stop(); window.close() }
}
