import AppKit

/// A visual effect must follow other apps into full-screen Spaces without
/// activating LumaDisplay or intercepting keyboard and pointer input.
final class DisplayOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: NSRect, level: NSWindow.Level) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canHide = false
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                              .fullScreenAuxiliary, .fullScreenDisallowsTiling,
                              .stationary, .ignoresCycle]
        sharingType = .none
        animationBehavior = .none
    }

    func present(on frame: NSRect) {
        if self.frame != frame { setFrame(frame, display: true) }
        orderFrontRegardless()
    }
}
