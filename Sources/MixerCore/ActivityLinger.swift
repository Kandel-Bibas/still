import Foundation

/// Keeps an app listed as active for `window` seconds after it last played, so a pause
/// between tracks doesn't make its row jump out of the list.
public struct ActivityLinger {
    public let window: TimeInterval
    private var lastSeen: [String: Date] = [:]

    public init(window: TimeInterval = 15) { self.window = window }

    /// Records the app's current state and returns whether it should show as active.
    public mutating func observe(_ id: String, active: Bool, now: Date) -> Bool {
        if active { lastSeen[id] = now }
        return isActive(id, now: now)
    }

    public func isActive(_ id: String, now: Date) -> Bool {
        guard let seen = lastSeen[id] else { return false }
        return now.timeIntervalSince(seen) < window
    }

    /// The earliest moment an app currently lingering stops counting as active, or nil
    /// when none is lingering. Nothing else re-evaluates activity, so the owner must
    /// refresh at this time.
    public func nextExpiry(after now: Date) -> Date? {
        lastSeen.values.map { $0.addingTimeInterval(window) }.filter { $0 > now }.min()
    }
}
