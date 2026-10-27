import AppKit

/// The clothesline's motion vocabulary: system springs (the same model as SwiftUI's), so things
/// settle the way they do elsewhere in macOS instead of running on fixed curves.
@MainActor
enum Motion {
    /// A spring that settles in about `duration` seconds; `bounce` 0 is smooth, 0.3 is lively.
    static func spring(_ keyPath: String, from: Any?, to: Any?, duration: Double = 0.4, bounce: Double = 0) -> CASpringAnimation {
        let spring = CASpringAnimation(perceptualDuration: duration, bounce: bounce)
        spring.keyPath = keyPath
        spring.fromValue = from
        spring.toValue = to
        spring.duration = spring.settlingDuration
        return spring
    }

    /// Runs `animations` on `layer` and calls `completion` when they're done.
    static func run(on layer: CALayer, _ animations: [String: CAAnimation], completion: (() -> Void)? = nil) {
        CATransaction.begin()
        if let completion {
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        }
        for (key, animation) in animations { layer.add(animation, forKey: key) }
        CATransaction.commit()
    }

    /// Changes layer properties without the implicit quarter-second fade.
    static func immediately(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    /// The transform that makes a layer showing `frame` look like it's at `source` instead.
    static func transform(from source: CGRect, to frame: CGRect) -> CATransform3D {
        guard frame.width > 0, frame.height > 0 else { return CATransform3DIdentity }
        var transform = CATransform3DMakeTranslation(source.midX - frame.midX, source.midY - frame.midY, 0)
        transform = CATransform3DScale(transform, source.width / frame.width, source.height / frame.height, 1)
        return transform
    }
}

/// The Finder's trash sounds, played only when the user has interface sound effects on.
@MainActor
enum TrashSound {
    case moveToTrash, emptyTrash

    func play() {
        // Absent means on, which is the system default.
        let enabled = UserDefaults(suiteName: ".GlobalPreferences")?.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true
        guard enabled else { return }
        let name = self == .moveToTrash ? "move to trash" : "empty trash"
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/\(name).aif"
        guard let sound = Self.cache[name] ?? NSSound(contentsOfFile: path, byReference: true) else { return }
        Self.cache[name] = sound
        sound.volume = 0.6
        sound.stop()
        sound.play()
    }

    private static var cache: [String: NSSound] = [:]
}
