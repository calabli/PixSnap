@preconcurrency import AVFoundation
import AppKit

/// A round window showing the camera, mirrored like a mirror, in the corner of what's being
/// recorded — so the recording shows who's explaining. It's an ordinary window on screen, so the
/// recording takes it in; drag it anywhere.
@MainActor
final class CameraBubble: NSPanel {
    private let capture = CaptureSession()
    private let preview: AVCaptureVideoPreviewLayer

    /// In the bottom-right corner of `region`, smaller for small regions.
    init(in region: CGRect) {
        let side: CGFloat = min(180, max(96, min(region.width, region.height) * 0.28))
        let frame = CGRect(x: region.maxX - side - 18, y: region.minY + 18, width: side, height: side)
        preview = AVCaptureVideoPreviewLayer(session: capture.session)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        content.layer?.cornerRadius = side / 2
        content.layer?.masksToBounds = true
        content.layer?.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        content.layer?.borderWidth = 3
        content.layer?.borderColor = NSColor.white.cgColor
        preview.videoGravity = .resizeAspectFill
        preview.frame = content.bounds
        content.layer?.addSublayer(preview)
        contentView = content
    }

    /// Asks for the camera the first time; false when it's not allowed or there's none.
    func start() async -> Bool {
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        guard allowed, let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera),
              capture.session.canAddInput(input) else { return false }
        capture.session.addInput(input)
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        orderFrontRegardless()
        await capture.run()
        return true
    }

    override func close() {
        capture.stop()
        super.close()
    }
}

/// A capture session started and stopped off the main thread, as AVFoundation wants.
final class CaptureSession: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.pixsnap.PixSnap.capture")

    func run() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [session] in
                session.startRunning()
                done.resume()
            }
        }
    }

    func stop() {
        queue.async { [session] in session.stopRunning() }
    }
}

/// How loud the microphone is right now, for the meter in 讲解模式's setup.
@MainActor
final class MicrophoneMeter {
    var onLevel: ((Double) -> Void)?
    private let capture = CaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sink = Sink()
    private var timer: Timer?

    /// The microphones there are: (unique ID, name).
    static var microphones: [(id: String, name: String)] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { ($0.uniqueID, $0.localizedName) }
    }

    /// Listens to the microphone `id` (the default when nil), asking for it the first time.
    func start(microphone id: String?) async -> Bool {
        stop()
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        guard allowed, let device = id.flatMap({ AVCaptureDevice(uniqueID: $0) }) ?? AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        let session = capture.session
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if session.canAddInput(input) { session.addInput(input) }
        if session.outputs.isEmpty, session.canAddOutput(output) {
            output.setSampleBufferDelegate(sink, queue: DispatchQueue(label: "com.pixsnap.PixSnap.meter"))
            session.addOutput(output)
        }
        session.commitConfiguration()
        await capture.run()
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        return true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        capture.stop()
    }

    private func poll() {
        let power = output.connections.first?.audioChannels.map(\.averagePowerLevel).max() ?? -160
        // −50 dB and below reads as silence.
        onLevel?(min(max((Double(power) + 50) / 50, 0), 1))
    }

    private final class Sink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {}
}
