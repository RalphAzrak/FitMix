import CoreGraphics
import CoreML
import CoreVideo
import OSLog
import QuartzCore
import Vision

// MARK: - Live garment detection (on-device, per frame)
//
// Vision pose anchors one subject. Instance masks refine regions when they agree with that
// pose. Colour and Vision classification provide category evidence, with optional Core ML
// detections refining regions on the same subject.

nonisolated struct LiveDetection: Sendable, Equatable {
    var category: GarmentCategory
    /// Normalized to the analyzed frame, top-left origin.
    var bounds: CGRect
    var confidence: Double
    /// The garment's own colour (person pixels only, sRGB 0–1), when it could be measured.
    var color: SIMD3<Float>? = nil
}

nonisolated final class LiveGarmentDetector: @unchecked Sendable {
    /// What to tell the user when a frame has nothing (or not everything) selectable.
    enum Hint: Sendable, Equatable {
        case noPerson
        /// The person is found but their feet are cut off at the bottom of the frame.
        case includeFeet
        /// Shoulders and hips weren't both visible.
        case includeUpperBody
        case holdSteady
        case clearerView
    }

    /// Where one frame's analysis time went, in milliseconds.
    struct Timings: Sendable, Equatable {
        var pose = 0.0
        var mask = 0.0
        var model = 0.0
        var classify = 0.0
        var total = 0.0
        /// Pose, mask and garment model together, for the performance overlay.
        var vision: Double { pose + mask + model }
    }

    struct Result: Sendable {
        var detections: [LiveDetection] = []
        var hint: Hint?
        var acquiredSubject = false
        /// The locked subject was matched in this frame (a new, resumed or continuing lock).
        var trackedSubject = false
        /// The subject's pose bounds (normalized, top-left), for manual selection's suggested crops.
        var subjectBounds: CGRect?
        /// People whose pose was found in this frame, the subject included.
        var peopleInView = 0
        /// Vision couldn't run at all.
        var failed = false
        var timings = Timings()
    }

    #if DEBUG
    /// Debug builds: receives the measurements behind each decision (tests and the frame harness).
    nonisolated(unsafe) static var trace: ((String) -> Void)?
    #endif
    private let model: VNCoreMLModel?
    private let pose = VNDetectHumanBodyPoseRequest()
    private let segmentation = VNGeneratePersonInstanceMaskRequest()
    private let subject = LiveSubjectTracker()
    private var cachedMask: (joints: PoseJoints, mask: ByteMask)?
    private var lastMaskAttempt = -Double.infinity
    /// Classifier scores per body area, reused for a short time so each frame runs at most a few
    /// classifications.
    private var classified: [String: (time: Double, box: CGRect, scores: [String: Float])] = [:]
    private var timings = Timings()
    private let log = Logger(subsystem: "app.fitmix", category: "LiveGarmentDetector")

    init(bundle: Bundle = .main) {
        if let url = bundle.url(forResource: "GarmentDetector", withExtension: "mlmodelc"),
           let ml = try? MLModel(contentsOf: url), let vn = try? VNCoreMLModel(for: ml) {
            model = vn
        } else {
            model = nil
        }
    }

    /// Loads Vision's models before the first camera frame, so the first garments aren't delayed by it.
    func warmUp() {
        let size = 64
        guard let context = CGContext(data: nil, width: size, height: size * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size * 2))
        guard let image = context.makeImage() else { return }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try? handler.perform([VNDetectHumanBodyPoseRequest(), VNGeneratePersonInstanceMaskRequest(), VNClassifyImageRequest()])
    }

    func reset() {
        subject.reset()
        resetRefinements()
    }

    private func resetRefinements() {
        classified.removeAll()
        cachedMask = nil
        lastMaskAttempt = -.infinity
    }

    /// The handler reads the original camera buffer with its orientation. The upright analysis
    /// image is only rendered if pose finds the subject.
    func detect(_ handler: VNImageRequestHandler, time: Double, analysisImage: () -> CGImage?) -> Result {
        let start = CACurrentMediaTime()
        timings = Timings()
        var result = detectSubject(handler, time: time, analysisImage: analysisImage)
        timings.total = (CACurrentMediaTime() - start) * 1000
        result.timings = timings
        return result
    }

    // MARK: Core ML model

    private func detectWithModel(_ model: VNCoreMLModel, _ handler: VNImageRequestHandler,
                                 joints: PoseJoints, others: [PoseJoints]) -> [LiveDetection] {
        let start = CACurrentMediaTime()
        defer { timings.model = (CACurrentMediaTime() - start) * 1000 }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        do { try handler.perform([request]) } catch {
            log.error("Garment model failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        var best: [GarmentCategory: LiveDetection] = [:]
        for observation in request.results as? [VNRecognizedObjectObservation] ?? [] {
            guard let label = observation.labels.first, label.confidence >= 0.5,
                  let category = Self.modelCategory(for: label.identifier) else { continue }
            let box = observation.boundingBox
            let bounds = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            let support = joints.support(for: category, in: bounds)
            guard support > 0, others.allSatisfy({ $0.support(for: category, in: bounds) < support }) else { continue }
            let detection = LiveDetection(category: category, bounds: bounds, confidence: Double(label.confidence))
            if (best[category]?.confidence ?? 0) < detection.confidence { best[category] = detection }
        }
        return Array(best.values)
    }

    /// Maps common clothing-dataset labels onto the four live categories.
    static func modelCategory(for label: String) -> GarmentCategory? {
        let l = label.lowercased().replacingOccurrences(of: "_", with: " ")
        if ["jacket", "coat", "outer", "outerwear", "blazer", "long sleeve outwear", "short sleeve outwear"].contains(l) { return .jacket }
        if ["t-shirt", "tshirt", "t shirt", "tee", "top", "short sleeve top", "long sleeve top"].contains(l) { return .tshirt }
        if ["pants", "trousers", "jeans"].contains(l) { return .pants }
        if ["shoes", "shoe", "footwear", "boots", "sneakers", "sneaker"].contains(l) { return .shoes }
        return nil
    }

    // MARK: Vision fallback

    private func detectSubject(_ handler: VNImageRequestHandler, time: Double, analysisImage: () -> CGImage?) -> Result {
        let start = CACurrentMediaTime()
        do { try handler.perform([pose]) } catch {
            timings.pose = (CACurrentMediaTime() - start) * 1000
            log.error("Body pose failed: \(error.localizedDescription, privacy: .public)")
            return Result(failed: true)
        }
        timings.pose = (CACurrentMediaTime() - start) * 1000
        let candidates = (pose.results ?? []).map(PoseJoints.init)
        guard let match = subject.update(candidates, time: time) else {
            var result = Result(hint: subject.isLocked ? .holdSteady : candidates.isEmpty ? .noPerson : .includeUpperBody)
            result.peopleInView = candidates.count
            return result
        }
        if match.acquired { resetRefinements() }
        let joints = candidates[match.index]
        var result = Result(acquiredSubject: match.acquired, trackedSubject: true, subjectBounds: joints.bounds,
                            peopleInView: candidates.count)
        guard let image = analysisImage(), let grid = ColorGrid(image, maxWidth: 240) else { return result }
        let others = candidates.enumerated().filter { $0.offset != match.index }.map(\.element)
        let scene = Scene(image: image, joints: joints, grid: grid,
                          mask: subjectMask(handler, joints: joints, others: others, time: time),
                          aspect: Double(image.height) / Double(image.width))
        let skin = faceSkin(scene) ?? handSkin(scene)

        result.detections = upperBody(scene, skin: skin, time: time)
        if let pants = pants(scene, skin: skin, time: time) { result.detections.append(pants) }
        switch shoes(scene, skin: skin, time: time) {
        case .found(let shoes): result.detections.append(shoes)
        case .feetOutOfFrame: result.hint = .includeFeet
        case .notFound: break
        }
        if let model {
            for var detection in detectWithModel(model, handler, joints: joints, others: others) {
                // Preserve the inner panel when both engines see the tee under an open jacket.
                if detection.category == .tshirt, result.detections.contains(where: { $0.category == .jacket }),
                   result.detections.contains(where: { $0.category == .tshirt }) { continue }
                detection.color = scene.mean(detection.bounds)
                result.detections.removeAll { $0.category == detection.category }
                result.detections.append(detection)
            }
        }
        // Shoulders are what tops are found from (hips can be estimated). A feet hint stays: it's the more
        // specific one when the lower body is what's in view.
        let topFound = result.detections.contains { $0.category == .tshirt || $0.category == .jacket }
        if !topFound, joints[.leftShoulder] == nil || joints[.rightShoulder] == nil, result.hint == nil {
            result.hint = .includeUpperBody
        }
        if result.detections.isEmpty, result.hint == nil { result.hint = .clearerView }
        return result
    }

    private func subjectMask(_ handler: VNImageRequestHandler, joints: PoseJoints, others: [PoseJoints],
                             time: Double) -> ByteMask? {
        if !others.isEmpty { cachedMask = nil }
        if time - lastMaskAttempt < 0.32 {
            guard let cachedMask, joints.isAligned(with: cachedMask.joints) else { return nil }
            return cachedMask.mask
        }
        lastMaskAttempt = time
        cachedMask = nil
        let start = CACurrentMediaTime()
        defer { timings.mask = (CACurrentMediaTime() - start) * 1000 }
        guard (try? handler.perform([segmentation])) != nil, let observation = segmentation.results?.first else { return nil }
        let labels = LabelMask(observation.instanceMask)
        guard let instance = labels.instance(for: joints, excluding: others) else { return nil }
        let mask = ByteMask(labels, instance: instance)
        if others.isEmpty, observation.allInstances.count == 1 { cachedMask = (joints, mask) }
        return mask
    }

    private struct Scene {
        let image: CGImage
        let joints: PoseJoints
        let grid: ColorGrid
        let mask: ByteMask?
        /// Frame height / width: converts a vertical normalized length into a horizontal one.
        let aspect: Double

        func mean(_ rect: CGRect) -> SIMD3<Float>? { grid.mean(in: rect, mask: mask) }

        /// A small square sample around a point, `size` measured vertically.
        func sample(at p: CGPoint, size: Double) -> SIMD3<Float>? {
            let w = size * aspect
            return mean(CGRect(x: p.x - w / 2, y: p.y - size / 2, width: w, height: size))
        }

        /// The person's pixels inside `band`, or the band itself without segmentation.
        func tighten(_ band: CGRect) -> CGRect? {
            let clamped = band.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !clamped.isNull, clamped.width > 0.01, clamped.height > 0.01 else { return nil }
            guard let mask else { return clamped }
            return mask.box(in: clamped) ?? clamped
        }
    }

    /// The face's skin tone, sampled on the cheek just below the nose. Nil when the face isn't visible.
    private func faceSkin(_ s: Scene) -> SIMD3<Float>? {
        guard let nose = s.joints[.nose] else { return nil }
        let eyes = [s.joints[.leftEye], s.joints[.rightEye]].compactMap { $0 }
        let eyeGap = eyes.count == 2 ? abs(eyes[0].x - eyes[1].x) / s.aspect : 0.02
        let size = max(0.008, eyeGap * 0.5)
        // A hand, phone or camera in front of the face would otherwise become the "skin" reference.
        return s.sample(at: CGPoint(x: nose.x, y: nose.y + size * 0.6), size: size).flatMap { Self.plausibleSkin($0) ? $0 : nil }
    }

    /// With the face hidden (a phone or camera in front of it), the back of a hand, just past the wrist.
    private func handSkin(_ s: Scene) -> SIMD3<Float>? {
        let j = s.joints
        let samples = [(j[.leftElbow], j[.leftWrist]), (j[.rightElbow], j[.rightWrist])].compactMap { elbow, wrist -> SIMD3<Float>? in
            guard let elbow, let wrist else { return nil }
            let forearm = hypot(wrist.x - elbow.x, (wrist.y - elbow.y) * s.aspect)
            return s.sample(at: lerp(elbow, wrist, 1.18), size: max(0.006, forearm * 0.12 / s.aspect))
        }.filter(Self.plausibleSkin)
        #if DEBUG
        Self.trace?("hand skin: " + samples.map(labString).joined(separator: " "))
        #endif
        return samples.first
    }

    /// Colours real skin falls in under ordinary light, from very light to very dark (CIELAB: warm,
    /// moderately saturated, yellow about as strong as red). Black, white, gray, blue and green
    /// garments are all outside it; tan and pink ones can fall inside.
    static func plausibleSkin(_ color: SIMD3<Float>) -> Bool {
        let l = lab(color)
        guard (18...92).contains(l.x), (5...35).contains(l.y), (5...42).contains(l.z) else { return false }
        return (0.5...2.6).contains(l.z / l.y)
    }

    /// Bare skin rather than a garment: close to the face's skin, or skin-coloured and not far from it.
    private func looksBare(_ color: SIMD3<Float>?, _ skin: SIMD3<Float>?) -> Bool {
        guard let color else { return false }
        if let skin, deltaE(color, skin) < 16 { return true }
        return Self.plausibleSkin(color) && (skin.map { deltaE(color, $0) < 30 } ?? true)
    }

    /// Mid-gray with no colour: under low light or a grayscale feed, skin can look like this too.
    private static func isNeutralMidtone(_ color: SIMD3<Float>) -> Bool {
        let l = lab(color)
        return (35...80).contains(l.x) && (l.y * l.y + l.z * l.z).squareRoot() < 8
    }

    /// Centre-vs-panel colour differences that mean an open outer layer over another garment.
    static func isOpenFront(_ differences: [Float], jacketSeen: Bool) -> Bool {
        guard let low = differences.min() else { return false }
        if !jacketSeen { return low > 20 }
        let mean = differences.reduce(0, +) / Float(differences.count)
        return mean >= 6.5 && low >= 4
    }

    private func isSkin(_ color: SIMD3<Float>?, _ skin: SIMD3<Float>?) -> Bool {
        guard let color, let skin else { return false }
        return deltaE(color, skin) < 16
    }

    // MARK: Upper body: Jacket and/or T-shirt

    private func upperBody(_ s: Scene, skin: SIMD3<Float>?, time: Double) -> [LiveDetection] {
        let j = s.joints
        guard let ls = j[.leftShoulder], let rs = j[.rightShoulder] else { return [] }
        let shoulderY = (ls.y + rs.y) / 2
        let minS = min(ls.x, rs.x), maxS = max(ls.x, rs.x), w = maxS - minS
        guard w > 0.02 else { return [] }
        // Close framing cuts the hips off. The torso is then estimated from the shoulders (hip joints sit
        // about 1.45 shoulder widths below them), as long as the chest itself is in view.
        let hip: CGPoint
        if let measured = j.mid(.leftHip, .rightHip), measured.y - shoulderY > 0.05 {
            hip = measured
        } else {
            let estimated = 1.45 * w / s.aspect
            guard shoulderY + estimated * 0.55 < 0.98 else { return [] }
            hip = CGPoint(x: (minS + maxS) / 2, y: shoulderY + estimated)
        }
        let torso = hip.y - shoulderY
        guard torso > 0.05 else { return [] }
        let cx = ((minS + maxS) / 2 + hip.x) / 2
        let top = shoulderY - torso * 0.12, hem = hip.y + torso * 0.06

        // The whole upper garment, sleeves included.
        let armXs = [j[.leftElbow], j[.rightElbow], j[.leftWrist], j[.rightWrist]].compactMap { $0?.x } + [minS, maxS]
        let pad = w * 0.18
        guard let outer = s.tighten(CGRect(x: (armXs.min() ?? minS) - pad, y: top,
                                           width: (armXs.max() ?? maxS) - (armXs.min() ?? minS) + pad * 2, height: hem - top)) else { return [] }

        // Centre strip (high and low on the chest) against the two side panels.
        let half = torso * 0.09
        let centreRect = { (y: Double) in CGRect(x: cx - w * 0.08, y: y - half, width: w * 0.16, height: half * 2) }
        let centreHigh = s.mean(centreRect(shoulderY + torso * 0.25))
        let centreLow = s.mean(centreRect(hip.y - torso * 0.22))
        let panelRect = { (x: Double) in CGRect(x: x - w * 0.07, y: shoulderY + torso * 0.3, width: w * 0.14, height: torso * 0.4) }
        let panelA = s.mean(panelRect(minS + w * 0.2)), panelB = s.mean(panelRect(maxS - w * 0.2))

        // Upper arms near the middle, forearms past the elbow.
        let upperArms = [(ls, j[.leftElbow]), (rs, j[.rightElbow])].compactMap { shoulder, elbow in
            elbow.flatMap { s.sample(at: lerp(shoulder, $0, 0.5), size: torso * 0.1) }
        }
        let forearms = [(j[.leftElbow], j[.leftWrist]), (j[.rightElbow], j[.rightWrist])].compactMap { elbow, wrist -> SIMD3<Float>? in
            guard let elbow, let wrist else { return nil }
            return s.sample(at: lerp(elbow, wrist, 0.6), size: torso * 0.08)
        }

        // Jackets often hang below the hips, so the classifier sees down to mid-thigh.
        let context = CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: hip.y + torso * 0.5 - outer.minY)
        let upperScores = scores(key: "upper", box: context, s, time: time)
        let jacketScore = score(["jacket", "hoodie", "suit", "lab_coat"], in: upperScores)
        let teeScore = score(["t-shirt", "t_shirt", "tshirt", "tee_shirt"], in: upperScores)
        #if DEBUG
        Self.trace?("upper scores: " + upperScores.filter { $0.value > 0.05 }.sorted { $0.value > $1.value }.prefix(10).map { String(format: "%@ %.2f", $0.key, $0.value) }.joined(separator: ", "))
        #endif
        /// Follows a side panel's colour down from the hip to find where that garment ends.
        func hemY(matching colour: SIMD3<Float>?) -> Double {
            guard let colour else { return hem }
            var y = hip.y
            while y < hip.y + torso * 0.7, let below = s.sample(at: CGPoint(x: (minS + w * 0.2), y: y + torso * 0.05), size: torso * 0.08),
                  deltaE(below, colour) < 16 {
                y += torso * 0.05
            }
            return max(hem, y + torso * 0.03)
        }
        #if DEBUG
        if let trace = Self.trace, let ch = centreHigh, let cl = centreLow, let a = panelA, let b = panelB {
            trace(String(format: "upper: centre/panels ΔE %.0f %.0f %.0f %.0f, centre high/low %.0f, panels %.0f, jacket %.2f, arms %d, forearms %d, skin %@",
                         deltaE(ch, a), deltaE(ch, b), deltaE(cl, a), deltaE(cl, b), deltaE(ch, cl), deltaE(a, b), jacketScore,
                         upperArms.count, forearms.count, skin == nil ? "none" : "yes"))
        }
        #endif

        // The centre strip (high and low) must differ from both side panels. With the classifier
        // already seeing a jacket, a smaller contrast counts (dark tee under a black jacket measures
        // 5–11); a single closed top measures 0–4, averaging ≤ 2, so it never splits in two.
        if let ch = centreHigh, let cl = centreLow, let a = panelA, let b = panelB,
           deltaE(ch, cl) < 16, deltaE(a, b) < 14,
           Self.isOpenFront([deltaE(ch, a), deltaE(ch, b), deltaE(cl, a), deltaE(cl, b)], jacketSeen: jacketScore >= 0.2) {
            let sleevesMatch = upperArms.contains { deltaE($0, a) < 16 || deltaE($0, b) < 16 }
            if sleevesMatch || jacketScore >= 0.08 {
                // Open jacket over an inner top: the inner strip runs from the neckline to the hem.
                let jacket = s.tighten(CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: hemY(matching: a) - outer.minY)) ?? outer
                // Open over a bare chest there's no inner top to offer.
                if looksBare(ch, skin) || looksBare(cl, skin) {
                    return [LiveDetection(category: .jacket, bounds: jacket, confidence: min(1, 0.6 + Double(jacketScore)), color: (a + b) / 2)]
                }
                let inner = CGRect(x: cx - w * 0.17, y: shoulderY - torso * 0.02, width: w * 0.34, height: hip.y - shoulderY + torso * 0.04)
                return [
                    LiveDetection(category: .jacket, bounds: jacket, confidence: min(1, 0.6 + Double(jacketScore)), color: (a + b) / 2),
                    LiveDetection(category: .tshirt, bounds: inner.intersection(jacket), confidence: 0.6, color: (ch + cl) / 2),
                ]
            }
        }

        let bareForearm = forearms.contains { isSkin($0, skin) }
        let bareUpperArm = upperArms.contains { isSkin($0, skin) }
        let shortSleeves = bareForearm && !bareUpperArm
        if jacketScore >= 0.2, !shortSleeves {
            let jacket = s.tighten(CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: hemY(matching: panelA) - outer.minY)) ?? outer
            return [LiveDetection(category: .jacket, bounds: jacket, confidence: Double(jacketScore), color: panelA ?? centreHigh)]
        }
        // A bare torso is never a T-shirt, however the arms read (shaded arms can look like sleeves).
        guard ![panelA, panelB, centreHigh].contains(where: { looksBare($0, skin) }) else { return [] }
        if shortSleeves || teeScore >= 0.2 {
            // Without long sleeves the garment is the torso plus upper arms, not out to the wrists.
            let elbowXs = [j[.leftElbow], j[.rightElbow]].compactMap { $0?.x } + [minS, maxS]
            let teeTop = shoulderY - torso * 0.2  // the collar sits well above the shoulder joints
            let tee = s.tighten(CGRect(x: (elbowXs.min() ?? minS) - w * 0.15, y: teeTop,
                                       width: (elbowXs.max() ?? maxS) - (elbowXs.min() ?? minS) + w * 0.3, height: hem - teeTop))
            return tee.map { [LiveDetection(category: .tshirt, bounds: $0, confidence: 0.6, color: centreHigh ?? panelA)] } ?? []
        }
        // A clear top on a visible torso: both side panels are the same fabric and neither they nor the
        // chest look like bare skin. Long sleeves land here too; the live categories have one top.
        #if DEBUG
        if let a = panelA, let b = panelB, let ch = centreHigh {
            Self.trace?("clear top: panels ΔE \(Int(deltaE(a, b))) bare \(looksBare(a, skin)) \(looksBare(b, skin)) \(looksBare(ch, skin)) lab \(labString(a)) \(labString(ch))")
        }
        #endif
        if let a = panelA, let b = panelB, centreHigh != nil, deltaE(a, b) < 14 {
            let elbowXs = [j[.leftElbow], j[.rightElbow]].compactMap { $0?.x } + [minS, maxS]
            let teeTop = shoulderY - torso * 0.2
            let tee = s.tighten(CGRect(x: (elbowXs.min() ?? minS) - w * 0.15, y: teeTop,
                                       width: (elbowXs.max() ?? maxS) - (elbowXs.min() ?? minS) + w * 0.3, height: hem - teeTop))
            return tee.map { [LiveDetection(category: .tshirt, bounds: $0, confidence: 0.5, color: (a + b) / 2)] } ?? []
        }
        return []
    }

    // MARK: Pants

    private func pants(_ s: Scene, skin: SIMD3<Float>?, time: Double) -> LiveDetection? {
        let j = s.joints
        guard let hip = j.mid(.leftHip, .rightHip) else { return nil }
        let ankleY = [j[.leftAnkle], j[.rightAnkle]].compactMap { $0.map { Double($0.y) } }.max()
        let kneeY = [j[.leftKnee], j[.rightKnee]].compactMap { $0.map { Double($0.y) } }.max()
        #if DEBUG
        Self.trace?(String(format: "pants joints: hip %.3f knee %@ ankle %@", hip.y, kneeY.map { String(format: "%.3f", $0) } ?? "-", ankleY.map { String(format: "%.3f", $0) } ?? "-"))
        #endif
        // Hip to ankle. Waist-to-knee framing has no ankles: the shin is about as long as the thigh.
        let span: Double, anklesInView: Bool
        if let ankleY, ankleY - hip.y > 0.08 {
            span = ankleY - hip.y
            anklesInView = true
        } else if let kneeY, kneeY - hip.y > 0.05, kneeY < 0.985 {
            span = (kneeY - hip.y) * 2
            anklesInView = false
        } else {
            return nil
        }
        let legs: [(PoseJoints.Name, PoseJoints.Name, PoseJoints.Name)] = [(.leftHip, .leftKnee, .leftAnkle), (.rightHip, .rightKnee, .rightAnkle)]
        var covered = false, bare = false, neutral = false
        var thighs: [SIMD3<Float>] = []
        for (h, k, a) in legs {
            guard let hp = j[h], let kn = j[k] else { continue }
            let thigh = s.sample(at: lerp(hp, kn, 0.5), size: span * 0.06)
            // Just above the knee: shorts end here, trousers don't.
            let aboveKnee = s.sample(at: lerp(hp, kn, 0.85), size: span * 0.05)
            let shin = j[a].flatMap { s.sample(at: lerp(kn, $0, 0.55), size: span * 0.05) }
            if looksBare(thigh, skin) || looksBare(aboveKnee, skin) || looksBare(shin, skin) { bare = true }
            // Same garment top to bottom: the same colour, allowing for shading down the leg.
            // Shading changes lightness, not hue, but white against gray isn't shading.
            let lower = shin ?? aboveKnee
            if let thigh, let lower, deltaE(thigh, lower) < 16 || chromaDelta(thigh, lower) < 10 && lightnessDelta(thigh, lower) < 28 {
                covered = true
            }
            if let thigh {
                thighs.append(thigh)
                if Self.isNeutralMidtone(thigh) { neutral = true }
            }
            #if DEBUG
            if let thigh, let lower { Self.trace?(String(format: "pants leg: ΔE %.0f, chroma Δ %.0f thighLab %@ lowerLab %@ skinLab %@", deltaE(thigh, lower), chromaDelta(thigh, lower), labString(thigh), labString(lower), skin.map(labString) ?? "-")) }
            #endif
        }
        #if DEBUG
        Self.trace?("pants: covered \(covered), bare \(bare), ankles \(anklesInView), face skin \(skin != nil)")
        #endif
        guard !bare, let thighColor = thighs.first else { return nil }

        let xs = j.xs(anklesInView ? [.leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle] : [.leftHip, .rightHip, .leftKnee, .rightKnee])
        let pad = span * 0.12 * s.aspect
        // Without ankles the trousers run on past the bottom of the frame.
        let height = anklesInView ? span * 1.03 : 1 - (hip.y - span * 0.04)
        guard let box = s.tighten(CGRect(x: (xs.min() ?? hip.x) - pad, y: hip.y - span * 0.04,
                                         width: (xs.max() ?? hip.x) - (xs.min() ?? hip.x) + pad * 2, height: height)) else { return nil }
        // Ask the classifier when the colours alone can't tell: the leg didn't read as one garment, a
        // gray leg could be skin under poor light, or (waist-to-knee) one thigh with no skin to compare.
        let needsClassifier = !covered || (skin == nil && neutral) || (!anklesInView && thighs.count < 2 && skin == nil)
        let jeans = needsClassifier ? score(["jeans"], in: scores(key: "legs", box: box, s, time: time)) : 0
        #if DEBUG
        Self.trace?(String(format: "pants: jeans %.2f", jeans))
        #endif
        // Gray legs with no skin to compare against could be bare legs under poor light, so they need more.
        let needed = !covered ? 0.25 : skin == nil && neutral ? 0.5 : 0.15
        guard !needsClassifier || jeans >= Float(needed) else { return nil }
        return LiveDetection(category: .pants, bounds: box, confidence: min(1, 0.55 + Double(jeans)), color: thighColor)
    }

    // MARK: Shoes

    private enum ShoeResult { case found(LiveDetection), feetOutOfFrame, notFound }

    private func shoes(_ s: Scene, skin: SIMD3<Float>?, time: Double) -> ShoeResult {
        let j = s.joints
        let ankles = [j[.leftAnkle], j[.rightAnkle]].compactMap { $0 }
        guard !ankles.isEmpty else {
            // Hips or knees but no ankles: the feet are below the frame.
            return j.mid(.leftHip, .rightHip) != nil || j.y([.leftKnee, .rightKnee]) != nil ? .feetOutOfFrame : .notFound
        }
        let ys = ankles.map { Double($0.y) }, xs = ankles.map { Double($0.x) }
        guard let highest = ys.min(), let lowest = ys.max() else { return .notFound }
        let hipSpan = j.y([.leftHip, .rightHip]).map { lowest - $0 } ?? 0
        let kneeSpan = j.y([.leftKnee, .rightKnee]).map { (lowest - $0) * 2 } ?? 0
        let leg = max(hipSpan, kneeSpan)
        guard leg > 0.04 else { return .notFound }
        let pad = leg * 0.16 * s.aspect
        let depth = leg * (s.mask == nil ? 0.25 : 0.4)
        let band = CGRect(x: (xs.min() ?? 0.5) - pad, y: highest - leg * 0.06,
                          width: (xs.max() ?? 0.5) - (xs.min() ?? 0.5) + pad * 2, height: lowest - highest + depth)
        // The person mask ends at the soles, so the box stops there rather than on the floor.
        guard let box = s.tighten(band) else { return .notFound }
        guard box.maxY < 0.985 else { return .feetOutOfFrame }
        // Vision's labels are hierarchical: "footwear" covers socks too, so only shoe labels count.
        let shoeLabels = ["shoes", "sneaker", "boot", "high_heel", "sandal", "loafer", "ski_boot"]
        let feet = scores(key: "feet", box: box, s, time: time)
        var shoeScore = score(shoeLabels, in: feet)
        let sock = feet["sock"] ?? 0
        if shoeScore < 0.1, sock >= 0.1 || (feet["footwear"] ?? 0) >= 0.1 {
            // Footwear, but which kind is unclear: dark shoes under dark trousers read as socks when
            // cropped tight, and small feet get only the parent label. With the lower legs and some floor
            // in view the classifier can tell. Socks alone still score no shoe label.
            let context = CGRect(x: box.minX - box.width * 0.3, y: box.minY - box.height * 0.8,
                                 width: box.width * 1.6, height: box.height * 2)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            shoeScore = max(shoeScore, score(shoeLabels, in: scores(key: "feet-context", box: context, s, time: time)))
        }
        #if DEBUG
        Self.trace?("feet scores: " + feet.filter { $0.value > 0.05 }.sorted { $0.value > $1.value }.prefix(12).map { String(format: "%@ %.2f", $0.key, $0.value) }.joined(separator: ", "))
        #endif
        #if DEBUG
        Self.trace?(String(format: "shoes: leg %.3f, box y %.3f–%.3f, score %.2f, sock %.2f", leg, box.minY, box.maxY, shoeScore, sock))
        #endif
        guard shoeScore >= 0.1 else { return .notFound }
        // The lower half of the box is shoe, not trouser hem; only the person's pixels count, not the ground.
        let soles = s.mean(CGRect(x: box.minX, y: box.midY, width: box.width, height: box.height / 2))
        // Bare feet: skin-coloured and close to the person's skin. Dark shoes on a shaded floor can sit near
        // a dark skin reference, so the colour has to be skin-like as well. Sandals show skin too, so a
        // clear shoe label still wins (bare feet score about 0.02, sandals 0.3–0.96).
        let bareFeet = soles.map { sole in Self.plausibleSkin(sole) && (skin.map { deltaE(sole, $0) < 30 } ?? true) } ?? false
        #if DEBUG
        Self.trace?("shoes: soles \(soles.map(labString) ?? "-"), bare \(bareFeet)")
        #endif
        if bareFeet, shoeScore < 0.3 { return .notFound }
        return .found(LiveDetection(category: .shoes, bounds: box, confidence: min(1, 0.5 + Double(shoeScore)), color: soles))
    }

    // MARK: Classifier

    /// The highest of `labels`' confidences in `scores`.
    private func score(_ labels: [String], in scores: [String: Float]) -> Float {
        labels.compactMap { scores[$0] }.max() ?? 0
    }

    /// Vision's image classifier, run on the box's crop. Cached per body area while the box hasn't moved much.
    private func scores(key: String, box: CGRect, _ s: Scene, time: Double) -> [String: Float] {
        if let cached = classified[key], time - cached.time < 0.5, iou(cached.box, box) > 0.65 {
            return cached.scores
        }
        guard let crop = LiveGarmentSelection.crop(s.image, to: box),
              crop.width >= 16, crop.height >= 16 else { return [:] }
        let request = VNClassifyImageRequest()
        let start = CACurrentMediaTime()
        defer { timings.classify += (CACurrentMediaTime() - start) * 1000 }
        guard (try? VNImageRequestHandler(cgImage: crop, orientation: .up).perform([request])) != nil else { return [:] }
        var scores: [String: Float] = [:]
        for observation in request.results ?? [] where observation.confidence > 0.01 {
            scores[observation.identifier] = observation.confidence
        }
        classified[key] = (time, box, scores)
        return scores
    }
}

// MARK: - Helpers

nonisolated func iou(_ a: CGRect, _ b: CGRect) -> Double {
    let i = a.intersection(b)
    guard !i.isNull else { return 0 }
    let inter = i.width * i.height
    let union = a.width * a.height + b.width * b.height - inter
    return union > 0 ? inter / union : 0
}

nonisolated private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
}

/// Difference in hue and saturation only (Lab a*b*), ignoring lightness, so shading doesn't count.
nonisolated func chromaDelta(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    let la = lab(a), lb = lab(b)
    let da = la.y - lb.y, db = la.z - lb.z
    return (da * da + db * db).squareRoot()
}

/// Difference in CIELAB lightness only.
nonisolated func lightnessDelta(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    abs(lab(a).x - lab(b).x)
}

/// CIE76 colour difference between two sRGB colours (0–1 components).
nonisolated func deltaE(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    let la = lab(a), lb = lab(b)
    let d = la - lb
    return (d * d).sum().squareRoot()
}

#if DEBUG
nonisolated func labString(_ c: SIMD3<Float>) -> String { let l = lab(c); return String(format: "(%.0f %.0f %.0f)", l.x, l.y, l.z) }
#endif

nonisolated private func lab(_ c: SIMD3<Float>) -> SIMD3<Float> {
    func linear(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4) }
    let r = linear(c.x), g = linear(c.y), b = linear(c.z)
    let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    func f(_ t: Float) -> Float { t > 0.008856 ? cbrtf(t) : 7.787 * t + 16 / 116 }
    let fx = f(x), fy = f(y), fz = f(z)
    return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
}

/// Confident body-pose joints, normalized with a top-left origin.
nonisolated struct PoseJoints {
    typealias Name = VNHumanBodyPoseObservation.JointName
    static let anchors: [Name] = [.leftShoulder, .rightShoulder, .leftHip, .rightHip, .root, .leftKnee, .rightKnee]
    let points: [Name: CGPoint]

    init(points: [Name: CGPoint]) { self.points = points }

    init(_ observation: VNHumanBodyPoseObservation) {
        let recognized = (try? observation.recognizedPoints(.all)) ?? [:]
        points = recognized.compactMapValues {
            guard $0.confidence >= 0.3, (0...1).contains($0.location.x), (0...1).contains($0.location.y) else { return nil }
            return CGPoint(x: $0.location.x, y: 1 - $0.location.y)
        }
    }

    subscript(_ name: Name) -> CGPoint? { points[name] }

    var bounds: CGRect {
        let xs = points.values.map(\.x), ys = points.values.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .zero }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    func anchorDistance(to other: PoseJoints) -> Double? {
        let distances = Self.anchors.compactMap { name -> Double? in
            guard let a = self[name], let b = other[name] else { return nil }
            return hypot(a.x - b.x, a.y - b.y)
        }
        guard distances.count >= 2 else { return nil }
        return distances.reduce(0, +) / Double(distances.count)
    }

    func isAligned(with other: PoseJoints) -> Bool {
        guard Set(points.keys) == Set(other.points.keys) else { return false }
        return points.allSatisfy { name, a in
            guard let b = other[name] else { return false }
            return hypot(a.x - b.x, a.y - b.y) < 0.018
        }
    }

    private var torsoProbes: [CGPoint?] {
        let shoulders = mid(.leftShoulder, .rightShoulder)
        let hips = mid(.leftHip, .rightHip)
        let torso = shoulders.flatMap { start in hips.map { lerp(start, $0, 0.5) } }
        return [torso, shoulders, hips]
    }

    /// Interior pose samples are less likely to hit the edge of a low-resolution mask.
    var maskProbes: [CGPoint] {
        (torsoProbes + [self[.leftKnee], self[.rightKnee], self[.nose]]).compactMap { $0 }
    }

    func support(for category: GarmentCategory, in box: CGRect) -> Int {
        let probes: [CGPoint?] = switch category {
        case .jacket, .tshirt:
            torsoProbes
        case .pants:
            [mid(.leftHip, .leftKnee), mid(.rightHip, .rightKnee), self[.leftKnee], self[.rightKnee]]
        case .shoes:
            [self[.leftAnkle], self[.rightAnkle]].map { $0.map { CGPoint(x: $0.x, y: $0.y + 0.015) } }
        default: []
        }
        let expanded = box.insetBy(dx: -box.width * 0.08, dy: -box.height * 0.08)
        return probes.compactMap { $0 }.filter { expanded.contains($0) }.count
    }

    func mid(_ a: Name, _ b: Name) -> CGPoint? {
        let found = [points[a], points[b]].compactMap { $0 }
        guard !found.isEmpty else { return nil }
        return CGPoint(x: found.map(\.x).reduce(0, +) / Double(found.count), y: found.map(\.y).reduce(0, +) / Double(found.count))
    }

    func y(_ names: [Name]) -> Double? {
        let ys = names.compactMap { points[$0].map { Double($0.y) } }
        return ys.isEmpty ? nil : ys.reduce(0, +) / Double(ys.count)
    }

    func xs(_ names: [Name]) -> [Double] { names.compactMap { points[$0].map { Double($0.x) } } }
}

/// Starts on the prominent pose, then prefers proximity to the last confident landmarks.
/// A missing or ambiguous match holds the lock for `grace`. After that, a person found close to
/// where the subject was last seen, within `resumeWindow`, is treated as the same person coming
/// back (a pose dropout) rather than a new subject; anyone else starts a new subject.
nonisolated final class LiveSubjectTracker {
    static let grace = 0.6
    static let resumeWindow = 2.0
    private var last: (joints: PoseJoints, time: Double)?
    private(set) var isLocked = false

    func reset() {
        last = nil
        isLocked = false
    }

    func update(_ candidates: [PoseJoints], time: Double) -> (index: Int, acquired: Bool)? {
        let usable = candidates.indices.filter { index in
            candidates[index].points.count >= 3 && PoseJoints.anchors.filter { candidates[index][$0] != nil }.count >= 2
        }
        if let last, time - last.time < Self.grace {
            isLocked = true
            let ranked = rank(usable, candidates, near: last.joints, limit: Self.limit(for: last.joints))
            guard let best = ranked.first,
                  ranked.count == 1 || ranked[1].distance - best.distance >= 0.025 else { return nil }
            self.last = (candidates[best.index], time)
            return (best.index, false)
        }
        isLocked = false
        guard let best = usable.max(by: { prominence(candidates[$0]) < prominence(candidates[$1]) }) else {
            if let last, time - last.time >= Self.resumeWindow { self.last = nil }
            return nil
        }
        // The same person back after a dropout: nearest to the last landmarks, and unambiguous.
        if let last, time - last.time < Self.resumeWindow {
            let ranked = rank(usable, candidates, near: last.joints, limit: Self.limit(for: last.joints) * 1.5)
            if let near = ranked.first, ranked.count == 1 || ranked[1].distance - near.distance >= 0.025 {
                self.last = (candidates[near.index], time)
                isLocked = true
                return (near.index, false)
            }
        }
        last = (candidates[best], time)
        isLocked = true
        return (best, true)
    }

    private static func limit(for joints: PoseJoints) -> Double {
        min(0.14, max(0.05, joints.bounds.height * 0.20))
    }

    private func rank(_ usable: [Int], _ candidates: [PoseJoints], near joints: PoseJoints,
                      limit: Double) -> [(index: Int, distance: Double)] {
        usable.compactMap { index -> (index: Int, distance: Double)? in
            guard let distance = joints.anchorDistance(to: candidates[index]), distance < limit else { return nil }
            return (index, distance)
        }.sorted { $0.distance < $1.distance }
    }

    private func prominence(_ joints: PoseJoints) -> Double {
        let bounds = joints.bounds
        return bounds.width * bounds.height / (1 + 2 * abs(bounds.midX - 0.5))
    }
}

/// The frame downscaled to a small RGB grid for colour sampling.
nonisolated struct ColorGrid {
    let width: Int
    let height: Int
    private let rgb: [Float]

    init?(_ image: CGImage, maxWidth: Int = 240) {
        let w = min(maxWidth, image.width)
        let h = max(1, Int((Double(image.height) * Double(w) / Double(image.width)).rounded()))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w
        height = h
        var rgb = [Float](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3] = Float(bytes[i * 4]) / 255
            rgb[i * 3 + 1] = Float(bytes[i * 4 + 1]) / 255
            rgb[i * 3 + 2] = Float(bytes[i * 4 + 2]) / 255
        }
        self.rgb = rgb
    }

    /// Mean colour inside a normalized rect, counting only the person's pixels when a mask is given.
    func mean(in rect: CGRect, mask: ByteMask?) -> SIMD3<Float>? {
        let x0 = max(0, Int(rect.minX * Double(width))), x1 = min(width - 1, Int(rect.maxX * Double(width)))
        let y0 = max(0, Int(rect.minY * Double(height))), y1 = min(height - 1, Int(rect.maxY * Double(height)))
        guard x0 <= x1, y0 <= y1 else { return nil }
        var sum = SIMD3<Float>(0, 0, 0), n = 0
        for y in y0...y1 {
            for x in x0...x1 {
                if let mask, !mask.isOn(x: (Double(x) + 0.5) / Double(width), y: (Double(y) + 0.5) / Double(height)) { continue }
                let i = (y * width + x) * 3
                sum += SIMD3(rgb[i], rgb[i + 1], rgb[i + 2])
                n += 1
            }
        }
        return n >= 3 ? sum / Float(n) : nil
    }

    /// Mean absolute Laplacian of brightness. Higher is sharper; only meaningful relative to
    /// other frames of the same scene.
    var sharpness: Double {
        guard width > 2, height > 2 else { return 0 }
        func luma(_ x: Int, _ y: Int) -> Float {
            let i = (y * width + x) * 3
            return 0.299 * rgb[i] + 0.587 * rgb[i + 1] + 0.114 * rgb[i + 2]
        }
        var total: Float = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                total += abs(4 * luma(x, y) - luma(x - 1, y) - luma(x + 1, y) - luma(x, y - 1) - luma(x, y + 1))
            }
        }
        return Double(total) / Double((width - 2) * (height - 2))
    }
}

extension LabelMask {
    /// Select the label covering most of the locked subject's probes. Reject merged silhouettes
    /// when another pose also places several probes on that label.
    nonisolated func instance(for subject: PoseJoints, excluding others: [PoseJoints]) -> UInt8? {
        let probes = subject.maskProbes
        let labels = probes.map { label(atNormalized: $0.x, $0.y) }.filter { $0 != 0 }
        let counts = Dictionary(grouping: labels, by: { $0 }).mapValues(\.count)
        guard let best = counts.max(by: { $0.value < $1.value }), best.value >= 2,
              best.value * 2 > probes.count else { return nil }
        guard others.allSatisfy({ pose in
            pose.maskProbes.filter { label(atNormalized: $0.x, $0.y) == best.key }.count < 2
        }) else { return nil }
        return best.key
    }
}

/// The tracked person's instance in Vision's mask, row 0 at the top.
nonisolated struct ByteMask {
    let labels: LabelMask
    let instance: UInt8
    var width: Int { labels.width }
    var height: Int { labels.height }

    init(_ labels: LabelMask, instance: UInt8) {
        self.labels = labels
        self.instance = instance
    }

    func isOn(x: Double, y: Double) -> Bool {
        labels.label(atNormalized: x, y) == instance
    }

    /// Bounding box of the person's pixels inside `rect` (normalized), or nil if there are too few.
    func box(in rect: CGRect) -> CGRect? {
        let x0 = max(0, Int(rect.minX * Double(width))), x1 = min(width - 1, Int(rect.maxX * Double(width)))
        let y0 = max(0, Int(rect.minY * Double(height))), y1 = min(height - 1, Int(rect.maxY * Double(height)))
        guard x0 <= x1, y0 <= y1 else { return nil }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, count = 0
        for y in y0...y1 {
            for x in x0...x1 where labels.labels[y * width + x] == instance {
                count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let area = (x1 - x0 + 1) * (y1 - y0 + 1)
        guard count >= max(12, area / 20) else { return nil }
        return CGRect(x: Double(minX) / Double(width), y: Double(minY) / Double(height),
                      width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height)).intersection(rect)
    }
}
