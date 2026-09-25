import Foundation

/// Path rules for deciding which application bundle a process belongs to.
public enum AppBundle {
    /// The outermost `.app` bundle in `path`, so a helper nested inside an app resolves
    /// to that app. Nil when the path contains no application bundle.
    public static func outermost(_ path: String) -> String? {
        let parts = (path as NSString).pathComponents
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(parts.prefix(index + 1)))
    }

    /// Whether an app at `path` is one a person would recognise as an application.
    /// Bundles under a `System/Library` directory — Siri, PowerChime, Control Center —
    /// are system components that only happen to be packaged as apps. System apps such as
    /// Music and Safari live under `System/Applications` instead, including the cryptex
    /// copies Safari runs from.
    public static func isUserFacing(_ path: String) -> Bool {
        let parts = (path as NSString).pathComponents
        return !zip(parts, parts.dropFirst()).contains { $0 == "System" && $1 == "Library" }
    }
}
