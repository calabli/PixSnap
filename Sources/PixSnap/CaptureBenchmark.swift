import AppKit

/// Development tool: `PixSnap --benchmark-capture <runs> [--benchmark-output <file>]` starts that many
/// captures in a row, cancels each right after the overlay's first frame, writes the timings to a
/// report, then quits. Nothing is saved but the timings.
@MainActor
final class CaptureBenchmark {
    private let coordinator: CaptureCoordinator
    private let runs: Int
    private let outputURL: URL
    private var results: [CaptureTiming] = []

    init(coordinator: CaptureCoordinator, runs: Int, outputURL: URL) {
        self.coordinator = coordinator
        self.runs = runs
        self.outputURL = outputURL
    }

    func start() {
        coordinator.onOverlayDrawn = { [weak self] timing in self?.record(timing) }
        // Give the app a moment to settle after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.runNext() }
    }

    private func runNext() {
        guard results.count < runs else {
            finish()
            return
        }
        coordinator.startCapture()
    }

    private func record(_ timing: CaptureTiming) {
        results.append(timing)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.coordinator.cancelSelection()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.runNext() }
        }
    }

    private func finish() {
        let totals = results.map(\.total)
        let warm = Array(totals.dropFirst()).sorted()
        func percentile(_ p: Double) -> Double {
            warm.isEmpty ? 0 : warm[min(warm.count - 1, Int((Double(warm.count) * p).rounded(.down)))]
        }
        var lines = [
            "PixSnap capture benchmark — \(results.count) runs, \(NSScreen.screens.count) screen(s)",
            "first (cold): \(String(format: "%.1f", totals.first ?? 0)) ms",
            "warm median: \(String(format: "%.1f", percentile(0.5))) ms, p90: \(String(format: "%.1f", percentile(0.9))) ms, max: \(String(format: "%.1f", warm.last ?? 0)) ms",
            "",
        ]
        lines += results.enumerated().map { "#\($0.offset + 1)  \($0.element.summary)" }
        try? (lines.joined(separator: "\n") + "\n").write(to: outputURL, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
