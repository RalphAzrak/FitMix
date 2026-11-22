import AVFoundation
import CoreImage
import OSLog
import QuartzCore
import Vision

/// One selectable garment in the live preview.
nonisolated struct LiveTarget: Identifiable, Sendable, Equatable {
    var id: GarmentCategory { category }
    let category: GarmentCategory
    /// Smoothed bounds used both on screen and for the crop (normalized, top-left origin).
    let bounds: CGRect
    let frame: LiveScanFrame
}

/// A full-resolution copy of the frame that produced these targets.
nonisolated final class LiveScanFrame: @unchecked Sendable, Equatable {
    let image: CGImage
    let date: Date
    let detections: [LiveDetection]
    let expiresAt: Double?

    init(image: CGImage, date: Date, detections: [LiveDetection], expiresAt: Double?) {
        self.image = image
        self.date = date
        self.detections = detections
        self.expiresAt = expiresAt
    }

    static func == (lhs: LiveScanFrame, rhs: LiveScanFrame) -> Bool { lhs === rhs }

    func isExpired(at time: Double) -> Bool { expiresAt.map { time >= $0 } ?? false }
}

/// A full-resolution frame frozen for manual selection, with what the detector found in it.
nonisolated struct LiveManualFrame: @unchecked Sendable, Identifiable {
    let id = UUID()
    let image: CGImage
    let date: Date
    /// Detections in `image` (normalized, top-left), possibly empty.
    let detections: [LiveDetection]
    /// The tracked person's pose bounds, when someone was found.
    let subjectBounds: CGRect?
    var isTestPhoto = false
}

/// What the Camera screen shows over the live preview.
nonisolated struct LiveScanState: Sendable, Equatable {
    /// Ready to tap, larger first, so smaller (inner) targets draw on top and win overlapping taps.
    var targets: [LiveTarget] = []
    /// Size of the analyzed frames, which have the same orientation and aspect as the preview.
    var frameSize: CGSize = .zero
    var hint: LiveGarmentDetector.Hint?
    /// Detection is unavailable on this device.
    var unavailable = false
    /// Filled only when the performance overlay is on (FM_DEBUG_PERF_HUD=1).
    var perf: LivePerf?
}

/// How fast the scanner is, for the debug overlay and the Instruments signposts.
nonisolated struct LivePerf: Sendable, Equatable {
    /// The last analyzed frame.
    var frame = LiveGarmentDetector.Timings()
    /// Seconds from the first frame with the person in it until each garment became tappable.
    var tappableAfter: [GarmentCategory: Double] = [:]
}

/// The garment the user tapped, with the frame it was detected in. Never written to disk.
nonisolated struct LiveGarmentSelection: @unchecked Sendable {
    struct Garment {
        let category: GarmentCategory
        /// Normalized to `frame`, top-left origin.
        let bounds: CGRect
        /// Cut from `frame` itself, using the same rectangle as the highlight.
        let crop: CGImage
        /// Measured on the person's pixels in `frame` when it was detected. Nil if unknown.
        var color: SIMD3<Float>? = nil
        /// A clearer crop of this garment from a recent snapshot, used only for retailer search.
        var searchCrop: CGImage? = nil
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

    /// Cuts a top-left-normalized region out of the source image.
    static func crop(_ frame: CGImage, to bounds: CGRect, padding: Double = 0.05) -> CGImage? {
        let w = Double(frame.width), h = Double(frame.height)
        let padded = bounds.insetBy(dx: -bounds.width * padding, dy: -bounds.height * padding)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !padded.isNull else { return nil }
        let pixels = CGRect(x: padded.minX * w, y: padded.minY * h, width: padded.width * w, height: padded.height * h)
            .integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard pixels.width >= 8, pixels.height >= 8 else { return nil }
        return frame.cropping(to: pixels)
    }
}

// MARK: - Tracker

/// Stabilizes garment geometry on the locked person. Confirmation takes two matching detections.
/// A confirmed garment that drops out for less than `staleAfter` is confirmed again by its next
/// detection alone, so a brief miss doesn't cost another confirmation frame.
nonisolated final class GarmentTracker {
    struct Track {
        var bounds: CGRect
        var raw: CGRect
        var hits: Int
        var lastSeen: Double
    }

    static let minHits = 2
    /// How long a garment stays tappable after its last detection while the same person is tracked.
    static let staleAfter = 1.0
    private var tracks: [GarmentCategory: Track] = [:]

    func update(_ detections: [LiveDetection], time: Double) -> [LiveDetection] {
        tracks = tracks.filter { time - $0.value.lastSeen < Self.staleAfter }
        return detections.compactMap { detection in
            let category = detection.category
            let bounds = detection.bounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard bounds.width >= 0.015, bounds.height >= 0.015 else { return nil }
            var next = Track(bounds: bounds, raw: bounds, hits: 1, lastSeen: time)
            if let previous = tracks[category], iou(previous.raw, bounds) > 0.15 {
                // Small variations get more smoothing. Follow big movements promptly.
                let motion = Self.edgeDistance(previous.bounds, bounds)
                let weight = min(0.9, 0.28 + motion * 9)
                next.bounds = CGRect(x: previous.bounds.minX + (bounds.minX - previous.bounds.minX) * weight,
                                     y: previous.bounds.minY + (bounds.minY - previous.bounds.minY) * weight,
                                     width: previous.bounds.width + (bounds.width - previous.bounds.width) * weight,
                                     height: previous.bounds.height + (bounds.height - previous.bounds.height) * weight)
                next.hits = Self.minHits
            }
            tracks[category] = next
            guard next.hits >= Self.minHits else { return nil }
            var stable = detection
            stable.bounds = next.bounds
            return stable
        }
    }

    func isConfirming(since time: Double) -> Bool {
        tracks.values.contains { $0.hits < Self.minHits && $0.lastSeen == time }
    }

    func reset() { tracks.removeAll() }

    static func edgeDistance(_ a: CGRect, _ b: CGRect) -> Double {
        max(abs(a.minX - b.minX), abs(a.maxX - b.maxX), abs(a.minY - b.minY), abs(a.maxY - b.maxY))
    }
}

// MARK: - Analyzer

nonisolated final class LiveGarmentAnalyzer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.fitmix.camera.analysis", qos: .userInitiated)

    private let tracker = GarmentTracker()
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private var loadedDetector: LiveGarmentDetector?
    private var detector: LiveGarmentDetector {
        if let loadedDetector { return loadedDetector }
        let detector = LiveGarmentDetector()
        loadedDetector = detector
        return detector
    }
    private let publish: @Sendable (LiveScanState, Int) -> Void
    private var lastRun = -Double.infinity
    private var ranEarly = false
    private var lastSnapshot = -Double.infinity
    private var paused = true
    private var run = 0
    private var holdingStill = false
    private var lastState = LiveScanState()
    private var recentFrames: [LiveScanFrame] = []
    private var firstSubjectFrame: Double?
    /// Last analyzed frame in which the locked person was matched.
    private var lastTrackedTime: Double?
    /// The hint on screen, and a different one waiting to be seen often enough to replace it.
    private var shownHint: LiveGarmentDetector.Hint?
    private var pendingHint: (hint: LiveGarmentDetector.Hint?, count: Int)?
    private var manualRequest: (@MainActor @Sendable (LiveManualFrame?) -> Void)?
    private var stillImage: CGImage?
    private var lastStillResult: LiveGarmentDetector.Result?
    private var loggedFirstTarget = false
    /// Per garment, for the performance overlay: seconds from the subject's first frame to tappable.
    private var tappableAfter: [GarmentCategory: Double] = [:]
    private let signposter = OSSignposter(subsystem: "app.fitmix", category: "LiveGarmentScanner")
    private let log = Logger(subsystem: "app.fitmix", category: "LiveGarmentScanner")

    /// Between analyses while targets are on screen and nothing is waiting to be confirmed; keeps the phone cool.
    private static let minInterval = 0.12
    /// Between analyses while nothing is tappable yet, so the first garments appear sooner.
    private static let searchInterval = 0.066
    private static let snapshotInterval = 0.24
    /// With no match for the tracked person this long (they left, or the scanner lost them to someone
    /// else), their targets are cleared rather than left on screen.
    static let subjectLostAfter = 0.45
    /// Sooner when someone else is in view instead, so one person's targets never sit on another.
    static let subjectReplacedAfter = 0.25
    /// A new hint must be seen in this many analyzed frames in a row before it replaces the shown one.
    private static let hintConfirmFrames = 3
    static let rearPortraitOrientation: CGImagePropertyOrientation = .right
    static let perfEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["FM_DEBUG_PERF_HUD"] == "1"
        #else
        false
        #endif
    }()

    /// The preview fits the same upright image represented by normalized overlay coordinates.
    static func previewRect(for bounds: CGRect, frameSize: CGSize, in viewSize: CGSize) -> CGRect {
        guard frameSize.width > 0, frameSize.height > 0 else { return .zero }
        let fit = AVMakeRect(aspectRatio: frameSize, insideRect: CGRect(origin: .zero, size: viewSize))
        return CGRect(x: fit.minX + bounds.minX * fit.width, y: fit.minY + bounds.minY * fit.height,
                      width: bounds.width * fit.width, height: bounds.height * fit.height)
    }

    init(publish: @escaping @MainActor @Sendable (LiveScanState, Int) -> Void) {
        self.publish = { state, run in DispatchQueue.main.async { publish(state, run) } }
        super.init()
    }

    func setPaused(_ paused: Bool, run: Int) {
        queue.async { [self] in
            self.run = run
            self.paused = paused
            clear()
            // Load Vision's models while the camera starts, not on the first frame with a person.
            if !paused, loadedDetector == nil { detector.warmUp() }
        }
    }

    /// Freezes the next camera frame (or the debug still) for manual selection, with its detections.
    func captureManualFrame(completion: @escaping @MainActor @Sendable (LiveManualFrame?) -> Void) {
        queue.async { [self] in
            if holdingStill, let stillImage {
                let result = lastStillResult
                let frame = LiveManualFrame(image: stillImage, date: .now, detections: result?.detections ?? [],
                                            subjectBounds: result?.subjectBounds, isTestPhoto: true)
                DispatchQueue.main.async { completion(frame) }
            } else if paused {
                DispatchQueue.main.async { completion(nil) }
            } else {
                manualRequest = completion
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !paused, !holdingStill else { return }
        let time = CACurrentMediaTime()
        let elapsed = time - lastRun
        let early = elapsed < (lastState.targets.isEmpty ? Self.searchInterval : Self.minInterval)
        let manual = manualRequest
        guard manual != nil || !early || (!ranEarly && elapsed >= 0.06 && tracker.isConfirming(since: lastRun)),
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let date = Date.now
        lastRun = time
        ranEarly = early

        let orientation = Self.rearPortraitOrientation
        let upright = CIImage(cvPixelBuffer: pixels).oriented(orientation)
        let analysis = signposter.beginInterval("Analyze frame")
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation)
        let result = detector.detect(handler, time: time) {
            // Classifier crops only need a smaller upright image. Pose reads the camera buffer.
            let scale = min(1, 720 / max(upright.extent.width, upright.extent.height))
            let reduced = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return Self.context.createCGImage(reduced, from: reduced.extent.integral)
        }
        signposter.endInterval("Analyze frame", analysis,
                              "total \(result.timings.total) ms, pose \(result.timings.pose) ms, mask \(result.timings.mask) ms, model \(result.timings.model) ms, classify \(result.timings.classify) ms")

        if let manual {
            manualRequest = nil
            let image = Self.context.createCGImage(upright, from: upright.extent, format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB), deferred: false)
            let frame = image.map { LiveManualFrame(image: $0, date: date, detections: result.detections, subjectBounds: result.subjectBounds) }
            DispatchQueue.main.async { manual(frame) }
        }

        process(result, size: upright.extent.size, time: time, date: date) {
            let copy = signposter.beginInterval("Copy selectable frame")
            // Own only selectable frames, leaving camera buffers in AVFoundation's pool.
            defer { signposter.endInterval("Copy selectable frame", copy) }
            return Self.context.createCGImage(upright, from: upright.extent, format: .RGBA8,
                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                              deferred: false)
        }
    }

    #if DEBUG
    func analyzeStill(_ image: CGImage, replay: [LiveDetection]? = nil, run: Int) {
        queue.async { [self] in
            self.run = run
            clear()
            holdingStill = true
            stillImage = image
            let start = CACurrentMediaTime()
            let size = CGSize(width: image.width, height: image.height)
            for i in 0..<GarmentTracker.minHits {
                let time = start + Double(i) * Self.minInterval
                let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
                let result = replay.map { LiveGarmentDetector.Result(detections: $0, trackedSubject: true) }
                    ?? detector.detect(handler, time: time) { image }
                lastStillResult = result
                process(result, size: size, time: time, date: .now) { image }
            }
        }
    }
    #endif

    private func process(_ result: LiveGarmentDetector.Result, size: CGSize, time: Double, date: Date,
                         copyFrame: () -> CGImage?) {
        let now = CACurrentMediaTime()
        recentFrames.removeAll { $0.isExpired(at: now) }
        if result.acquiredSubject {
            tracker.reset()
            recentFrames.removeAll()
            firstSubjectFrame = time
            loggedFirstTarget = false
            tappableAfter = [:]
        }
        if result.trackedSubject { lastTrackedTime = time }
        // Targets ride out brief misses on the same person, but go once that person is gone.
        let lostAfter = result.peopleInView > 0 ? Self.subjectReplacedAfter : Self.subjectLostAfter
        let subjectLost = lastTrackedTime.map { time - $0 >= lostAfter } ?? true
        if subjectLost, !lastState.targets.isEmpty {
            recentFrames.removeAll()
            log.info("Targets cleared: tracked person lost")
        }
        let stable = tracker.update(result.detections, time: time)
        var targets = result.acquiredSubject || subjectLost ? [] : lastState.targets.filter { !$0.frame.isExpired(at: now) }
        let byCategory = Dictionary(uniqueKeysWithValues: targets.map { ($0.category, $0) })
        let shouldSnapshot = stable.contains { detection in
            guard let target = byCategory[detection.category] else { return true }
            return GarmentTracker.edgeDistance(target.bounds, detection.bounds) >= 0.009
        } || (!stable.isEmpty && time - lastSnapshot >= Self.snapshotInterval)
        if shouldSnapshot, holdingStill || now - time < GarmentTracker.staleAfter, let image = copyFrame() {
            lastSnapshot = time
            let expiresAt = holdingStill ? nil : time + GarmentTracker.staleAfter
            let shown = stable.map { detection in
                var snapped = detection
                // Hold tiny changes steady even when renewing the source frame.
                if let previous = byCategory[detection.category],
                   GarmentTracker.edgeDistance(previous.bounds, detection.bounds) < 0.009 {
                    snapped.bounds = previous.bounds
                }
                return snapped
            }
            let updated = Set(shown.map(\.category))
            // Keep other garments from this *same* frame available in Studio.
            let companions = result.detections.filter { !updated.contains($0.category) }
            let frame = LiveScanFrame(image: image, date: date, detections: shown + companions, expiresAt: expiresAt)
            recentFrames.append(frame)
            if recentFrames.count > 4 { recentFrames.removeFirst() }
            targets.removeAll { updated.contains($0.category) }
            targets += shown.map {
                LiveTarget(category: $0.category, bounds: $0.bounds, frame: frame)
            }
            if !loggedFirstTarget, let firstSubjectFrame {
                loggedFirstTarget = true
                let ms = (CACurrentMediaTime() - firstSubjectFrame) * 1000
                signposter.emitEvent("First usable target", "\(ms) ms")
                log.info("First usable target: \(ms, format: .fixed(precision: 1)) ms after first subject frame")
            }
        }
        targets.sort {
            let a = $0.bounds.width * $0.bounds.height, b = $1.bounds.width * $1.bounds.height
            return a == b ? $0.category.rawValue < $1.category.rawValue : a > b
        }
        measureTappable(targets)
        // Shoes already tappable at the frame's edge: "feet are cut off" would contradict them.
        let hint = result.hint == .includeFeet && targets.contains { $0.category == .shoes } ? nil : result.hint
        var state = LiveScanState(targets: targets, frameSize: size, hint: steadyHint(hint), unavailable: result.failed)
        if Self.perfEnabled { state.perf = LivePerf(frame: result.timings, tappableAfter: tappableAfter) }
        guard state != lastState else { return }
        lastState = state
        publish(state, run)
    }

    /// Hints change only once a new one has held for a few frames, so the text doesn't flicker.
    private func steadyHint(_ hint: LiveGarmentDetector.Hint?) -> LiveGarmentDetector.Hint? {
        if hint == shownHint {
            pendingHint = nil
        } else if let pending = pendingHint, pending.hint == hint {
            pendingHint = (hint, pending.count + 1)
        } else {
            pendingHint = (hint, 1)
        }
        // "Point at an outfit" goes as soon as someone is found, and comes back at once when nothing is shown.
        let immediate = shownHint == nil && lastState.targets.isEmpty || shownHint == .noPerson
            || hint == .noPerson && lastState.targets.isEmpty
        if let pending = pendingHint, pending.count >= Self.hintConfirmFrames || immediate {
            shownHint = pending.hint
            pendingHint = nil
        }
        return shownHint
    }

    /// Time from the subject's first frame to each garment being tappable, once per subject.
    private func measureTappable(_ targets: [LiveTarget]) {
        guard let firstSubjectFrame else { return }
        for target in targets where tappableAfter[target.category] == nil {
            let seconds = CACurrentMediaTime() - firstSubjectFrame
            tappableAfter[target.category] = seconds
            signposter.emitEvent("tappable", "\(target.category.rawValue, privacy: .public) after \(seconds, format: .fixed(precision: 3)) s")
            log.info("\(target.category.rawValue, privacy: .public) tappable \(Int(seconds * 1000)) ms after the person appeared")
        }
    }

    private func clear() {
        loadedDetector?.reset()
        tracker.reset()
        recentFrames.removeAll()
        holdingStill = false
        lastRun = -.infinity
        ranEarly = false
        lastSnapshot = -.infinity
        firstSubjectFrame = nil
        loggedFirstTarget = false
        tappableAfter = [:]
        lastTrackedTime = nil
        shownHint = nil
        pendingHint = nil
        stillImage = nil
        lastStillResult = nil
        if let manualRequest {
            self.manualRequest = nil
            DispatchQueue.main.async { manualRequest(nil) }
        }
        lastState = LiveScanState()
    }

    /// Keep the tap and its crop aligned. Only ranking for product search uses other snapshots.
    private func clearerCrop(for detection: LiveDetection, exactCrop: CGImage, frame: LiveScanFrame,
                             tappedAt time: Double) -> CGImage? {
        let earlier = recentFrames.filter { $0.date < frame.date && !$0.isExpired(at: time) }
        guard !earlier.isEmpty else { return nil }

        func score(_ crop: CGImage) -> Double {
            let coverage = min(1, Double(min(crop.width, crop.height)) / 96)
            return (ColorGrid(crop, maxWidth: 80)?.sharpness ?? 0) * coverage
        }
        var best: CGImage?
        var bestScore = score(exactCrop)
        for snapshot in earlier.reversed() {
            guard let candidate = snapshot.detections.first(where: { $0.category == detection.category }),
                  iou(candidate.bounds, detection.bounds) > 0.15,
                  let crop = LiveGarmentSelection.crop(snapshot.image, to: candidate.bounds, padding: 0) else { continue }
            let sharpness = score(crop)
            if sharpness > bestScore {
                best = crop
                bestScore = sharpness
            }
        }
        return best
    }

    /// Resolve the displayed frame and exact bounds from the tap, even if newer targets arrived.
    func selection(of target: LiveTarget, tappedAt time: Double,
                   completion: @escaping @MainActor @Sendable (LiveGarmentSelection?) -> Void) {
        queue.async { [self] in
            let frame = target.frame
            guard !frame.isExpired(at: time) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let garments = GarmentCategory.liveScannable.compactMap { category -> LiveGarmentSelection.Garment? in
                guard let detection = frame.detections.first(where: { $0.category == category }),
                      let crop = LiveGarmentSelection.crop(frame.image, to: detection.bounds, padding: 0) else { return nil }
                let searchCrop = clearerCrop(for: detection, exactCrop: crop, frame: frame, tappedAt: time)
                return LiveGarmentSelection.Garment(category: category, bounds: detection.bounds, crop: crop,
                                                    color: detection.color, searchCrop: searchCrop)
            }
            let selection = garments.contains { $0.category == target.category && $0.bounds == target.bounds }
                ? LiveGarmentSelection(frame: frame.image, capturedAt: frame.date, garments: garments, selected: target.category)
                : nil
            DispatchQueue.main.async { completion(selection) }
        }
    }
}
