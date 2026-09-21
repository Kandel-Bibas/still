import CoreGraphics

public struct Display: Equatable, Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

public enum PanelPlacement {
    /// The display a panel anchored at `anchor` belongs to.
    ///
    /// `preferred` is the display holding the menu bar item that was clicked. A panel
    /// reports the display it was last shown on as its own, so that cannot be used to
    /// choose: it drags the panel back to wherever it opened last. Returns nil when
    /// neither the preferred display nor any display's frame covers the anchor, leaving
    /// the caller to pick a fallback.
    public static func host(anchor: CGPoint, displays: [Display], preferred: Display?) -> Display? {
        if let preferred, displays.contains(preferred) { return preferred }
        return displays.first { $0.frame.contains(anchor) }
    }

    /// Frame for a panel hanging from `anchor`, the point its top edge is centred on,
    /// kept inside `visibleFrame`.
    public static func frame(anchor: CGPoint, size: CGSize,
                             visibleFrame: CGRect, margin: CGFloat = 8) -> CGRect {
        var origin = CGPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height)
        let leftLimit = visibleFrame.minX + margin
        let rightLimit = visibleFrame.maxX - size.width - margin
        origin.x = rightLimit >= leftLimit
            ? min(max(origin.x, leftLimit), rightLimit)
            : visibleFrame.midX - size.width / 2
        origin.y = max(origin.y, visibleFrame.minY + margin)
        return CGRect(origin: origin, size: size)
    }
}
