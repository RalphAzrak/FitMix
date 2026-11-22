import AVFoundation
import QuartzCore
import UIKit

// MARK: - Camera session (AVFoundation, off the main thread)
//
// `CameraSession` owns the AVCaptureSession and does every configuration, start/stop, zoom and
// torch call on its own serial queue. The iPhone interface is portrait and the scanner uses the
// rear camera. The preview is fixed to that geometry, and the analyzer orients the native buffers.
// See Docs/LiveGarmentMatch.md.

/// A zoom stop the current camera can actually reach, e.g. "0.5×" on a device with an ultra-wide.
struct ZoomPreset: Hashable, Sendable {
    /// What the user sees, matching the system Camera ("0.5", "1", "2").
    let display: CGFloat
    /// The `videoZoomFactor` that produces it on this device.
    let factor: CGFloat

    var label: String { display < 1 ? "0.5×" : "\(Int(display))×" }
}

/// What the configured rear camera supports.
struct CameraCapabilities: Sendable {
    var zoomPresets: [ZoomPreset]
    var defaultZoom: ZoomPreset?
    var hasTorch: Bool
}

enum CameraSessionError: Error {
    case noRearCamera
    case cannotUseCamera(String)
}

nonisolated final class CameraSession: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.fitmix.camera.session", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var configured = false
    static let rearPortraitAngle: CGFloat = 90

    /// Rear cameras in preference order. Virtual devices first, so 0.5× and 2× switch lenses
    /// automatically where the hardware has them.
    private static let rearCameraTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
    ]

    /// True when this device has a rear camera at all (false in the simulator). No permission needed.
    static var hasRearCamera: Bool { findRearCamera() != nil }

    private static func findRearCamera() -> AVCaptureDevice? {
        for type in rearCameraTypes {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) { return device }
        }
        return nil
    }

    /// Configures the session the first time, then starts it. Completion runs on the main queue.
    func start(completion: @escaping @MainActor @Sendable (Result<CameraCapabilities, CameraSessionError>) -> Void) {
        queue.async { [self] in
            let result: Result<CameraCapabilities, CameraSessionError>
            do {
                let capabilities = try configureIfNeeded()
                if !session.isRunning { session.startRunning() }
                result = .success(capabilities)
            } catch let error as CameraSessionError {
                result = .failure(error)
            } catch {
                result = .failure(.cannotUseCamera(error.localizedDescription))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Stops the session and turns the torch off. With `release`, also removes the camera input
    /// so the hardware is fully let go (used when leaving the Camera screen).
    func stop(release: Bool = false) {
        queue.async { [self] in
            setTorchLocked(false)
            if session.isRunning { session.stopRunning() }
            guard release, configured else { return }
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            session.commitConfiguration()
            device = nil
            configured = false
        }
    }

    func setZoom(_ preset: ZoomPreset) {
        queue.async { [self] in
            guard let device else { return }
            let factor = min(max(preset.factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            do {
                try device.lockForConfiguration()
                device.ramp(toVideoZoomFactor: factor, withRate: 8)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func setTorch(_ on: Bool, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async { [self] in
            let isOn = setTorchLocked(on)
            DispatchQueue.main.async { completion(isOn) }
        }
    }

    /// Where frames go. The delegate is called on `queue`, and frames that arrive while it is busy
    /// are dropped, so analysis never slows the preview.
    func setFrameDelegate(_ delegate: LiveGarmentAnalyzer, queue delegateQueue: DispatchQueue) {
        queue.async { [self] in videoOutput.setSampleBufferDelegate(delegate, queue: delegateQueue) }
    }

    // MARK: Queue-only

    static func configureGeometry(_ connection: AVCaptureConnection, rotation: CGFloat) {
        if connection.isVideoRotationAngleSupported(rotation), connection.videoRotationAngle != rotation {
            connection.videoRotationAngle = rotation
        }
        if connection.isVideoMirroringSupported {
            if connection.automaticallyAdjustsVideoMirroring { connection.automaticallyAdjustsVideoMirroring = false }
            if connection.isVideoMirrored { connection.isVideoMirrored = false }
        }
    }

    @discardableResult
    private func setTorchLocked(_ on: Bool) -> Bool {
        guard let device, device.hasTorch, device.isTorchAvailable else { return false }
        let mode: AVCaptureDevice.TorchMode = on ? .on : .off
        guard device.isTorchModeSupported(mode) else { return device.torchMode == .on }
        do {
            try device.lockForConfiguration()
            device.torchMode = mode
            device.unlockForConfiguration()
        } catch {}
        return device.torchMode == .on
    }

    private func configureIfNeeded() throws -> CameraCapabilities {
        if configured, let device { return Self.capabilities(of: device) }
        guard let camera = Self.findRearCamera() else { throw CameraSessionError.noRearCamera }

        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: camera) } catch {
            throw CameraSessionError.cannotUseCamera(error.localizedDescription)
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // 1080p frames: sharp enough for garment crops and Studio's photo, light enough to analyze live.
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        guard session.canAddInput(input) else { throw CameraSessionError.cannotUseCamera("The camera input couldn't be added.") }
        session.addInput(input)
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOutput) else {
            session.removeInput(input)
            throw CameraSessionError.cannotUseCamera("The video output couldn't be added.")
        }
        session.addOutput(videoOutput)
        if let connection = videoOutput.connection(with: .video) {
            Self.configureGeometry(connection, rotation: 0)
        }

        let capabilities = Self.capabilities(of: camera)
        // Virtual devices start on their widest lens; open at 1× like the system Camera.
        if let start = capabilities.defaultZoom, (try? camera.lockForConfiguration()) != nil {
            camera.videoZoomFactor = start.factor
            camera.unlockForConfiguration()
        }
        device = camera
        configured = true
        return capabilities
    }

    private static func capabilities(of device: AVCaptureDevice) -> CameraCapabilities {
        let multiplier = device.displayVideoZoomFactorMultiplier
        let minFactor = device.minAvailableVideoZoomFactor
        let maxFactor = device.maxAvailableVideoZoomFactor
        let presets = [0.5, 1, 2].compactMap { (display: CGFloat) -> ZoomPreset? in
            let factor = display / multiplier
            guard factor >= minFactor - 0.001, factor <= maxFactor + 0.001 else { return nil }
            return ZoomPreset(display: display, factor: factor)
        }
        return CameraCapabilities(zoomPresets: presets.count > 1 ? presets : [],
                                  defaultZoom: presets.first { $0.display == 1 },
                                  hasTorch: device.hasTorch && device.isTorchModeSupported(.on))
    }
}

// MARK: - Controller (main actor)

/// State the Camera screen shows, plus the actions it calls. Owns one `CameraSession`.
@Observable
final class CameraController {
    enum Phase: Equatable {
        case starting
        case live
        /// The system paused the camera (another app, multitasking, system pressure).
        case interrupted(String)
        case denied
        case restricted
        /// No rear camera, e.g. the simulator.
        case unavailable
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    /// Garments detected in the live feed, ready to tap.
    private(set) var scan = LiveScanState()
    /// Set once a garment is tapped: the camera stops and Studio opens.
    private(set) var isSelecting = false
    /// Debug builds: a photo analyzed as if it were the live feed (a recorded frame).
    private(set) var stillFrame: UIImage?
    private(set) var capabilities = CameraCapabilities(zoomPresets: [], defaultZoom: nil, hasTorch: false)
    private(set) var zoom: ZoomPreset?
    private(set) var torchOn = false

    @ObservationIgnored let camera = CameraSession()
    @ObservationIgnored private var analyzer: LiveGarmentAnalyzer!
    @ObservationIgnored private var scanExpiry: Task<Void, Never>?
    @ObservationIgnored private var analysisRun = 0
    @ObservationIgnored private var sessionStart = 0
    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// False once the screen has gone away, so late callbacks don't restart the camera.
    @ObservationIgnored private var active = false

    var session: AVCaptureSession { camera.session }

    init() {
        analyzer = LiveGarmentAnalyzer { [weak self] state, run in
            guard let self, self.analysisRun == run, self.active else { return }
            self.publishScan(state)
        }
        camera.setFrameDelegate(analyzer, queue: analyzer.queue)
    }

    // MARK: Lifecycle

    /// Camera screen appeared, or the app came back to the foreground.
    func activate() async {
        active = true
        observeSession()
        guard !isSelecting, stillFrame == nil else { return }  // Studio is opening, or a recorded frame is shown.
        guard CameraSession.hasRearCamera else { phase = .unavailable; return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            phase = .starting
            guard await AVCaptureDevice.requestAccess(for: .video) else { phase = .denied; return }
        case .restricted: phase = .restricted; return
        default: phase = .denied; return
        }
        guard active else { return }
        startSession()
    }

    /// Camera screen went away or the app went to the background.
    func deactivate(release: Bool) {
        active = false
        sessionStart += 1
        torchOn = false
        resetAnalysis(paused: true)
        camera.stop(release: release)
        if release {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }
    }

    func retry() {
        phase = .starting
        Task { await activate() }
    }

    private func startSession() {
        if phase != .live { phase = .starting }
        sessionStart += 1
        let start = sessionStart
        camera.start { [weak self] result in
            guard let self, self.active, self.sessionStart == start, self.stillFrame == nil, !self.isSelecting else { return }
            switch result {
            case .success(let capabilities):
                self.capabilities = capabilities
                // Keep the user's zoom across Retake and backgrounding; otherwise open at 1×.
                if let zoom = self.zoom, capabilities.zoomPresets.contains(zoom) {
                    self.camera.setZoom(zoom)
                } else {
                    self.zoom = capabilities.defaultZoom
                }
                self.phase = self.session.isInterrupted ? .interrupted(Self.message(for: nil)) : .live
                self.applyPreviewGeometry()
                self.resetAnalysis(paused: self.session.isInterrupted)
            case .failure(.noRearCamera):
                self.phase = .unavailable
            case .failure(let error):
                self.phase = .failed(Self.describe(error))
            }
        }
    }

    private func resetAnalysis(paused: Bool) {
        analysisRun += 1
        isSelecting = false
        publishScan(LiveScanState())
        analyzer.setPaused(paused, run: analysisRun)
    }

    private func publishScan(_ state: LiveScanState) {
        scanExpiry?.cancel()
        let now = CACurrentMediaTime()
        var visible = state
        visible.targets.removeAll { $0.frame.isExpired(at: now) }
        if scan != visible { scan = visible }
        if let deadline = visible.targets.compactMap({ $0.frame.expiresAt }).min() {
            scanExpiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, deadline - CACurrentMediaTime())))
                guard !Task.isCancelled, let self else { return }
                self.publishScan(self.scan)
            }
        } else {
            scanExpiry = nil
        }
    }

    // MARK: Selecting a garment

    /// Stops the camera and hands Studio the tapped target's frame and crop while still fresh.
    func select(_ target: LiveTarget, completion: @escaping (LiveGarmentSelection) -> Void) {
        let now = CACurrentMediaTime()
        guard active, !isSelecting, phase == .live || stillFrame != nil, !target.frame.isExpired(at: now) else { return }
        isSelecting = true
        let run = analysisRun
        analyzer.selection(of: target, tappedAt: now) { [weak self] selection in
            guard let self, self.active, self.analysisRun == run else { return }
            guard let selection else {
                self.isSelecting = false
                return
            }
            self.resetAnalysis(paused: true)
            self.torchOn = false
            self.camera.stop()
            completion(selection)
        }
    }

    /// Freezes the current frame for manual garment selection. Nil if the camera isn't running.
    func captureManualFrame(completion: @escaping @MainActor (LiveManualFrame?) -> Void) {
        guard active, !isSelecting, phase == .live || stillFrame != nil else {
            completion(nil)
            return
        }
        let run = analysisRun
        analyzer.captureManualFrame { [weak self] frame in
            guard let self, self.active, self.analysisRun == run else {
                completion(nil)
                return
            }
            completion(frame)
        }
    }

    #if DEBUG
    /// Debug builds: show a photo in place of the preview and analyze it like a live frame.
    func analyzeStill(_ image: UIImage, replay: [LiveDetection]? = nil) {
        guard let cgImage = image.cgImage else { return }
        active = true
        stillFrame = image
        resetAnalysis(paused: true)
        camera.stop()
        analyzer.analyzeStill(cgImage, replay: replay, run: analysisRun)
    }
    #endif

    // MARK: Controls

    func select(_ preset: ZoomPreset) {
        guard phase == .live, preset != zoom, !isSelecting else { return }
        zoom = preset
        camera.setZoom(preset)
        resetAnalysis(paused: false)
    }

    func toggleTorch() {
        camera.setTorch(!torchOn) { [weak self] isOn in self?.torchOn = isOn }
    }

    // MARK: Preview orientation

    func attach(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        applyPreviewGeometry()
    }

    private func applyPreviewGeometry() {
        guard let connection = previewLayer?.connection else { return }
        CameraSession.configureGeometry(connection, rotation: CameraSession.rearPortraitAngle)
    }

    // MARK: Session notifications

    private func observeSession() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
                let reason = raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
                MainActor.assumeIsolated {
                    guard let self, self.stillFrame == nil, self.phase == .live || self.phase == .starting else { return }
                    // Backgrounding is handled by the screen; don't flash a message on the way out.
                    if reason == .videoDeviceNotAvailableInBackground { return }
                    self.torchOn = false
                    self.resetAnalysis(paused: true)
                    self.phase = .interrupted(Self.message(for: reason))
                }
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.active, self.stillFrame == nil, case .interrupted = self.phase else { return }
                    self.phase = .live
                    self.applyPreviewGeometry()
                    self.resetAnalysis(paused: false)
                }
            },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
                MainActor.assumeIsolated {
                    guard let self, self.active, self.stillFrame == nil, !self.isSelecting else { return }
                    self.resetAnalysis(paused: true)
                    if error?.code == .mediaServicesWereReset {
                        self.startSession()
                    } else {
                        self.phase = .failed(error?.localizedDescription ?? "The camera stopped unexpectedly.")
                    }
                }
            },
        ]
    }

    private static func message(for reason: AVCaptureSession.InterruptionReason?) -> String {
        switch reason {
        case .videoDeviceInUseByAnotherClient: "Another app is using the camera."
        case .videoDeviceNotAvailableWithMultipleForegroundApps: "The camera isn't available while other apps are on screen."
        case .videoDeviceNotAvailableDueToSystemPressure: "The camera paused because the iPhone is too warm."
        default: "The camera is paused."
        }
    }

    private static func describe(_ error: CameraSessionError) -> String {
        switch error {
        case .noRearCamera: "This device has no rear camera."
        case .cannotUseCamera(let detail): "The camera couldn't start. \(detail)"
        }
    }
}
