import Foundation

/// Maps a linear output peak to a 0...1 display value on a dB scale, with a
/// held-and-decaying fall so a meter driven by periodic samples doesn't visibly step.
public enum LevelMeter {
    /// - Parameters:
    ///   - peak: Linear output peak (0...1 at full scale). Non-finite or non-positive
    ///     values are treated as silence.
    ///   - previous: The display value returned last time, used to let the meter fall
    ///     smoothly instead of jumping straight to the new peak.
    ///   - floorDB: The peak level, in dBFS, that maps to a display value of 0.
    ///   - decay: Multiplier applied to `previous` each call; the displayed value is
    ///     never lower than this decayed floor, so the bar eases down rather than
    ///     dropping instantly when the peak falls or silence returns.
    public static func display(peak: Float, previous: Float, floorDB: Float = -60, decay: Float = 0.8) -> Float {
        let mapped: Float
        if peak.isFinite && peak > 0 {
            let db = 20 * log10(peak)
            mapped = min(max((db - floorDB) / (0 - floorDB), 0), 1)
        } else {
            mapped = 0
        }
        let result = max(mapped, previous * decay)
        return result < 0.001 ? 0 : result
    }
}
