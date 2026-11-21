import AVFoundation
import CoreImage
import OSLog
import QuartzCore

// MARK: - Live garment scanning (frames → stable targets → one selection)
//
// `LiveGarmentAnalyzer` receives upright frames from the camera's video output on its own queue,
// runs `LiveGarmentDetector` on at most ~8 frames a second (late frames are dropped by AVFoundation,
// so the preview never waits), and keeps targets steady with `GarmentTracker`. Each target remembers
// the exact frame it was last detected in. Tapping a target builds a `LiveGarmentSelection` from that
// same frame, so the crop matches what the user tapped. Frames stay in memory on the iPhone.

/// One selectable garment in the live preview.
nonisolated struct LiveTarget: Identifiable, Sendable, Equatable {
    var id: GarmentCategory { category }
    let category: GarmentCategory
    /// Smoothed across frames, normalized to the frame (top-left origin).
    var bounds: CGRect
}

/// What the Camera screen shows over the live preview.
nonisolated struct LiveScanState: Sendable, Equatable {
    /// Ready to tap, larger first, so smaller (inner) targets draw on top and win overlapping taps.
    var targets: [LiveTarget] = []
    /// Size of the analyzed frames, which have the same orientation and aspect as the preview.
    var frameSize: CGSize = .zero
    var hint: LiveGarmentDetector.Hint?
    /// Detection can't run here (the simulator can't run Vision body pose).
    var unavailable = false
    var engine: LiveGarmentDetector.Engine = .vision
    /// Filled only when the performance overlay is on (FM_DEBUG_PERF_HUD=1).
    var perf: LivePerf?
}

/// How fast the scanner is, for the debug overlay and the Instruments signposts.
nonisolated struct LivePerf: Sendable, Equatable {
    /// The last analyzed frame.
    var frame = LiveGarmentDetector.Timings()
    /// Seconds from the first frame with a person in it until each garment became tappable.
    var tappableAfter: [GarmentCategory: Double] = [:]
}

/// The garment the user tapped, with the frame it was detected in. Never written to disk.
nonisolated struct LiveGarmentSelection: @unchecked Sendable {
    struct Garment {
        let category: GarmentCategory
        /// Normalized to `frame`, top-left origin.
        let bounds: CGRect
        /// Cut from `frame` itself. The only image that may be sent for retailer search.
        let crop: CGImage
        /// Measured on the person's pixels in `frame` when it was detected. Nil if unknown.
        var color: SIMD3<Float>? = nil
    }

    /// The full outfit frame. Stays on the iPhone.
    let frame: CGImage
    let capturedAt: Date
    /// Every garment detected in `frame`, including the selected one.
    let garments: [Garment]
    let selected: GarmentCategory
    /// Debug sample data rather than a camera frame.
    var isSample = false
    var isTestPhoto = false

    /// Pads a region a little and cuts it from `frame`.
    static func crop(_ frame: CGImage, to bounds: CGRect, padding: Double = 0.05) -> CGImage? {
        let w = Double(frame.width), h = Double(frame.height)
        let padded = bounds.insetBy(dx: -bounds.width * padding, dy: -bounds.height * padding)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !padded.isNull else { return nil }
        let pixels = CGRect(x: padded.minX * w, y: padded.minY * h, width: padded.width * w, height: padded.height * h).integral
        guard pixels.width >= 8, pixels.height >= 8 else { return nil }
        return frame.cropping(to: pixels)
    }
}

// MARK: - Tracker

/// Keeps one track per category so targets don't flicker. A detection must appear in two analyzed
/// frames before it can be tapped, and disappears once it hasn't been seen for `staleAfter` seconds.
nonisolated final class GarmentTracker {
    struct Track {
        var smoothed: CGRect
        /// Bounds exactly as detected in `frameID`.
        var raw: CGRect
        /// Colour measured in `frameID`.
        var color: SIMD3<Float>?
        var frameID: Int
        var hits: Int
        var lastSeen: Double
    }

    static let minHits = 2
    static let staleAfter = 0.6
    private static let smoothing = 0.5

    private(set) var tracks: [GarmentCategory: Track] = [:]

    func update(_ detections: [LiveDetection], frameID: Int, time: Double) {
        for detection in detections {
            if var track = tracks[detection.category], iou(track.smoothed, detection.bounds) > 0.15 {
                track.smoothed = Self.blend(track.smoothed, detection.bounds, Self.smoothing)
                track.raw = detection.bounds
                track.color = detection.color
                track.frameID = frameID
                track.hits += 1
                track.lastSeen = time
                tracks[detection.category] = track
            } else {
                // New, or jumped somewhere else (another person): start over without smoothing.
                tracks[detection.category] = Track(smoothed: detection.bounds, raw: detection.bounds, color: detection.color,
                                                   frameID: frameID, hits: 1, lastSeen: time)
            }
        }
    }

    func expire(now: Double) {
        tracks = tracks.filter { now - $0.value.lastSeen <= Self.staleAfter }
    }

    func reset() { tracks = [:] }

    var ready: [GarmentCategory: Track] { tracks.filter { $0.value.hits >= Self.minHits } }

    var targets: [LiveTarget] {
        ready.map { LiveTarget(category: $0.key, bounds: $0.value.smoothed) }
            .sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
    }

    private static func blend(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }
}

// MARK: - Analyzer

nonisolated final class LiveGarmentAnalyzer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Frames are delivered and analyzed here.
    let queue = DispatchQueue(label: "app.fitmix.camera.analysis", qos: .userInitiated)

    private struct Frame {
        let image: CGImage
        let date: Date
    }

    private let detector = LiveGarmentDetector()
    private let tracker = GarmentTracker()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let publish: @Sendable (LiveScanState) -> Void
    private var frames: [Int: Frame] = [:]
    private var nextFrameID = 0
    private var lastRun = 0.0
    private var recentSharpness = 0.0
    private var paused = false
    /// Analyzing a still (debug recorded frame): its targets don't go stale.
    private var holdingStill = false
    private var lastState = LiveScanState()
    /// When the current person was first seen, for time-to-tappable.
    private var personSince: Double?
    private var lastPersonSeen = 0.0
    private var tappableAfter: [GarmentCategory: Double] = [:]
    private let signposter = OSSignposter(subsystem: "app.fitmix", category: "LiveGarmentScanner")
    private let log = Logger(subsystem: "app.fitmix", category: "LiveGarmentScanner")

    /// Between analyses while nothing is waiting to be confirmed; keeps the phone cool.
    private static let minInterval = 0.12
    static let perfEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["FM_DEBUG_PERF_HUD"] == "1"
        #else
        false
        #endif
    }()

    /// `publish` is called on the main queue.
    init(publish: @escaping @MainActor @Sendable (LiveScanState) -> Void) {
        self.publish = { state in DispatchQueue.main.async { publish(state) } }
        super.init()
    }

    /// Paused while Studio is open or the camera is off. Pausing forgets every target.
    func setPaused(_ paused: Bool) {
        queue.async { [self] in
            self.paused = paused
            if paused { clear() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !paused, !holdingStill else { return }
        let now = CACurrentMediaTime()
        // A garment seen once is confirmed on the very next frame instead of after the interval,
        // so it becomes tappable as soon as two frames agree.
        let confirming = tracker.tracks.values.contains { $0.hits < GarmentTracker.minHits }
        guard confirming || now - lastRun >= Self.minInterval, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastRun = now
        let extent = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        // A copy, so retained frames don't hold the camera's buffer pool. Vision reads the camera's
        // buffer directly; the copy is what a tap crops.
        guard let image = context.createCGImage(CIImage(cvPixelBuffer: pixels), from: extent) else { return }
        process(image, pixelBuffer: pixels, time: now)
    }

    /// Debug builds: analyze a photo as if it were the live feed, so overlays and taps can be
    /// checked without a camera. `replay` stands in for the detector with detections recorded
    /// elsewhere (the simulator can't run body pose).
    func analyzeStill(_ image: CGImage, replay: [LiveDetection]? = nil) {
        queue.async { [self] in
            clear()
            holdingStill = true
            paused = false
            let start = CACurrentMediaTime()
            for i in 0..<GarmentTracker.minHits { process(image, time: start + Double(i) * Self.minInterval, replay: replay) }
        }
    }

    private func process(_ image: CGImage, pixelBuffer: CVPixelBuffer? = nil, time: Double, replay: [LiveDetection]? = nil) {
        let interval = signposter.beginInterval("analyze frame")
        let result = replay.map { LiveGarmentDetector.Result(detections: $0) } ?? detector.detect(image, pixelBuffer: pixelBuffer, time: time)
        signposter.endInterval("analyze frame", interval,
                               "\(result.timings.total, format: .fixed(precision: 1)) ms, classify \(result.timings.classify, format: .fixed(precision: 1)) ms")
        var state = LiveScanState(frameSize: CGSize(width: image.width, height: image.height), hint: result.hint,
                                  unavailable: result.failed, engine: detector.engine)
        if !result.failed {
            // Keep the recent sharp frame: a frame much blurrier than recent ones (motion blur)
            // doesn't replace the detections, so a tap always crops a sharp frame.
            let sharpness = ColorGrid(image, maxWidth: 120)?.sharpness ?? 0
            recentSharpness = max(sharpness, recentSharpness * 0.95)
            if holdingStill || sharpness >= recentSharpness * 0.55 {
                let id = nextFrameID
                nextFrameID += 1
                frames[id] = Frame(image: image, date: .now)
                tracker.update(result.detections, frameID: id, time: time)
            }
        }
        if !holdingStill { tracker.expire(now: time) }
        let referenced = Set(tracker.tracks.values.map(\.frameID))
        frames = frames.filter { referenced.contains($0.key) }
        state.targets = tracker.targets
        measureTappable(result, targets: state.targets, time: time)
        if Self.perfEnabled { state.perf = LivePerf(frame: result.timings, tappableAfter: tappableAfter) }
        guard state != lastState else { return }
        lastState = state
        publish(state)
    }

    /// Time from first seeing a person to each garment being tappable, once per appearance.
    private func measureTappable(_ result: LiveGarmentDetector.Result, targets: [LiveTarget], time: Double) {
        let personVisible = !result.detections.isEmpty || (result.hint != nil && result.hint != .noPerson)
        if personVisible {
            if personSince == nil || time - lastPersonSeen > GarmentTracker.staleAfter {
                personSince = time
                tappableAfter = [:]
            }
            lastPersonSeen = time
        }
        guard let since = personSince else { return }
        // Tappable once this frame's analysis has finished, measured from when the person's first frame arrived.
        let finished = time + result.timings.total / 1000
        for target in targets where tappableAfter[target.category] == nil {
            let seconds = finished - since
            tappableAfter[target.category] = seconds
            signposter.emitEvent("tappable", "\(target.category.rawValue, privacy: .public) after \(seconds, format: .fixed(precision: 3)) s")
            log.info("\(target.category.rawValue, privacy: .public) tappable \(Int(seconds * 1000)) ms after the person appeared")
        }
    }

    private func clear() {
        tracker.reset()
        personSince = nil
        tappableAfter = [:]
        frames = [:]
        holdingStill = false
        recentSharpness = 0
        lastState = LiveScanState()
        publish(lastState)
    }

    /// The tapped garment and the others detected in the same frame, cut from that frame.
    /// `completion` runs on the main queue, with nil if the target has just gone away.
    func selection(of category: GarmentCategory, completion: @escaping @MainActor @Sendable (LiveGarmentSelection?) -> Void) {
        queue.async { [self] in
            let ready = tracker.ready
            guard let track = ready[category], let frame = frames[track.frameID] else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let garments = ready
                .filter { $0.value.frameID == track.frameID }
                .compactMap { category, track -> LiveGarmentSelection.Garment? in
                    LiveGarmentSelection.crop(frame.image, to: track.raw).map {
                        LiveGarmentSelection.Garment(category: category, bounds: track.raw, crop: $0, color: track.color)
                    }
                }
                .sorted { GarmentCategory.liveScannable.firstIndex(of: $0.category) ?? 0 < GarmentCategory.liveScannable.firstIndex(of: $1.category) ?? 0 }
            let selection = garments.contains { $0.category == category }
                ? LiveGarmentSelection(frame: frame.image, capturedAt: frame.date, garments: garments, selected: category)
                : nil
            DispatchQueue.main.async { completion(selection) }
        }
    }
}
