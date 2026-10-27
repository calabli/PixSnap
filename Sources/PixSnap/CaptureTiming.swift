import Foundation
import os

/// Timestamps along one capture, from the shortcut press to the overlay's first frame.
/// Each run is logged (subsystem com.pixsnap.PixSnap, category performance).
@MainActor
final class CaptureTiming {
    struct Mark {
        let stage: String
        /// Milliseconds since the capture started.
        let elapsed: Double
    }

    private(set) var marks: [Mark] = []
    private let start = ContinuousClock.now

    static let logger = Logger(subsystem: "com.pixsnap.PixSnap", category: "performance")

    func mark(_ stage: String) {
        let duration = ContinuousClock.now - start
        let milliseconds = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        marks.append(Mark(stage: stage, elapsed: milliseconds))
    }

    static let firstFrameStage = "首帧"

    /// Time until the overlay's first frame on the screen under the cursor — what people wait for.
    /// Other screens may still arrive after it; they're listed but not counted.
    var total: Double {
        marks.first { $0.stage == Self.firstFrameStage }?.elapsed ?? marks.last?.elapsed ?? 0
    }

    /// "权限 0.1 · 屏幕信息 1.0 · … → 首帧 62.3 ms": time spent in each stage, then the wait.
    var summary: String {
        var previous = 0.0
        let stages = marks.map { mark -> String in
            defer { previous = mark.elapsed }
            return "\(mark.stage) \(String(format: "%.1f", mark.elapsed - previous))"
        }
        return stages.joined(separator: " · ") + " → 首帧 \(String(format: "%.1f", total)) ms"
    }

    func log() {
        Self.logger.info("capture \(self.summary, privacy: .public)")
    }
}
