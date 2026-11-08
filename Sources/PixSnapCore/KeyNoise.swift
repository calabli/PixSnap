import Foundation

/// 去掉键盘声: the microphone turned down for the moment around each key press — the timeline knows
/// exactly when they were — so the clatter drops away and speech in between stays as it was.
public enum KeyNoise {
    /// How loud the microphone stays while a key goes down (about −14 dB): the click mostly gone,
    /// words said over typing still there.
    public static let level = 0.2
    /// How long the volume takes to go down and back up, so it never clicks itself.
    public static let ramp = 0.015
    /// A key's sound starts a moment before its event arrives and rings on a little after.
    public static let before = 0.03
    public static let after = 0.12
    /// Keys closer than this share one quiet stretch rather than bobbing up in between.
    public static let join = 0.1

    /// The stretches to turn down, in order and apart, within 0…`duration`.
    public static func quietRanges(typing: [Double], duration: Double) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        for t in typing.sorted() {
            let start = max(0, t - before), end = min(duration, t + after)
            guard end > start else { continue }
            if let last = ranges.last, start <= last.upperBound + join {
                ranges[ranges.count - 1] = last.lowerBound ... max(last.upperBound, end)
            } else {
                ranges.append(start ... end)
            }
        }
        return ranges
    }
}
