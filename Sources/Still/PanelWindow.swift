import AppKit
import MixerCore
import SwiftUI

/// Borderless panel that hangs from the menu bar item.
///
/// `NSHostingController` resizes the window whenever SwiftUI's content changes.
/// AppKit keeps the bottom-left origin fixed while doing so, which would make the
/// panel grow upward through the menu bar, so every frame change is re-anchored to
/// the point under the status item and clamped to the screen.
final class PanelWindow: NSPanel {
    /// Screen point the panel's top edge centre is pinned to.
    var anchor: NSPoint?
    /// Display holding the menu bar item the panel was opened from.
    var anchorScreen: NSScreen?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    convenience init(contentViewController: NSViewController) {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.contentViewController = contentViewController
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(anchored(frameRect), display: flag)
        invalidateShadow()
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate: Bool) {
        super.setFrame(anchored(frameRect), display: flag, animate: animate)
        invalidateShadow()
    }

    private func anchored(_ rect: NSRect) -> NSRect {
        guard let anchor, let host = hostScreen(for: anchor) else { return rect }
        return PanelPlacement.frame(anchor: anchor, size: rect.size, visibleFrame: host.visibleFrame)
    }

    private func hostScreen(for anchor: NSPoint) -> NSScreen? {
        let screens = NSScreen.screens
        let host = PanelPlacement.host(
            anchor: anchor,
            displays: screens.map { Display(frame: $0.frame, visibleFrame: $0.visibleFrame) },
            preferred: anchorScreen.map { Display(frame: $0.frame, visibleFrame: $0.visibleFrame) })
        guard let host else { return NSScreen.main }
        return screens.first { $0.frame == host.frame } ?? NSScreen.main
    }
}

/// The panel's background. A behind-window visual effect view is masked natively so
/// the blur itself is rounded; masking it from SwiftUI would leave square corners.
struct PanelMaterial: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.maskImage = Self.mask(radius: cornerRadius)
    }

    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Root of the panel: the mixer plus its window chrome.
struct PanelRoot: View {
    @Bindable var store: MixerStore
    var maxListHeight: CGFloat
    var cornerRadius: CGFloat
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        MixerPanel(
            store: store,
            maxListHeight: maxListHeight,
            onOpenSettings: onOpenSettings,
            onQuit: onQuit
        )
        .background(PanelMaterial(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        // A menu bar panel is always the focus of attention while it is open, so its
        // controls keep their active tint even though the app never activates.
        .environment(\.controlActiveState, .key)
    }
}
