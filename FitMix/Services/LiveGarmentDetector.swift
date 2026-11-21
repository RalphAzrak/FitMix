import CoreGraphics
import CoreML
import CoreVideo
import OSLog
import Vision

// MARK: - Live garment detection (on-device, per frame)
//
// Finds Jacket, T-shirt, Pants and Shoes on the main person in one upright camera frame. Nothing
// leaves the iPhone. Two engines, same output:
//
// 1. **Garment model** (preferred). If the app bundle contains `GarmentDetector.mlmodelc`, a Core ML
//    object detector (for example a YOLO model trained on a clothing dataset, exported with NMS),
//    its boxes are used directly. Labels are mapped to the four categories by `modelCategory(for:)`.
//    No such model ships with FitMix today; see Docs/LiveGarmentMatch.md.
// 2. **Vision fallback** (what runs today). Vision has no clothing detector, so this places regions
//    from body pose and person segmentation, then only reports a garment when there is evidence for
//    its category:
//    - Shoes: a box below the ankles, confirmed by Vision's image classifier (shoes / sneaker / boot…).
//    - Pants: hips to ankles, where the shin matches the thigh and isn't bare skin.
//    - Jacket over T-shirt: an open front, i.e. a centre strip that differs from both side panels
//      from chest to hem, with the side panels matching each other (and the sleeves, or the
//      classifier's "jacket" label). The T-shirt is the inner strip, so the two never share a box.
//    - Jacket alone: the classifier says jacket / hoodie / suit and the sleeves aren't short.
//    - T-shirt alone: short sleeves (bare forearm that matches the face's skin tone).
//    Anything else gets no target, rather than a guess.

nonisolated struct LiveDetection: Sendable, Equatable {
    var category: GarmentCategory
    /// Normalized to the analyzed frame, top-left origin.
    var bounds: CGRect
    var confidence: Double
    /// The garment's own colour (person pixels only, sRGB 0–1), when it could be measured.
    var color: SIMD3<Float>? = nil
}

nonisolated final class LiveGarmentDetector: @unchecked Sendable {
    enum Engine: Sendable, Equatable { case model, vision }

    /// What to tell the user when a frame has nothing (or not everything) selectable.
    enum Hint: Sendable, Equatable {
        case noPerson
        /// The person is found but their feet are cut off or not visible.
        case includeFeet
        /// Shoulders and hips weren't both visible.
        case includeUpperBody
    }

    struct Result: Sendable {
        var detections: [LiveDetection] = []
        var hint: Hint?
        /// Vision couldn't run at all (the iOS simulator can't run body pose).
        var failed = false
    }

    let engine: Engine
    #if DEBUG
    /// Debug builds: receives the measurements behind each decision (tests and the frame harness).
    nonisolated(unsafe) static var trace: ((String) -> Void)?
    #endif
    private let model: VNCoreMLModel?
    /// Classifier scores per body area, reused for a short time so each frame runs at most a few
    /// classifications.
    private var classified: [String: (time: Double, box: CGRect, scores: [String: Float])] = [:]
    private let log = Logger(subsystem: "app.fitmix", category: "LiveGarmentDetector")

    init(bundle: Bundle = .main) {
        if let url = bundle.url(forResource: "GarmentDetector", withExtension: "mlmodelc"),
           let ml = try? MLModel(contentsOf: url), let vn = try? VNCoreMLModel(for: ml) {
            model = vn
            engine = .model
        } else {
            model = nil
            engine = .vision
        }
    }

    /// `time` is seconds on any monotonic clock; it only paces the classifier cache.
    func detect(_ image: CGImage, time: Double) -> Result {
        if let model { return detectWithModel(model, image) }
        return detectWithVision(image, time: time)
    }

    // MARK: Core ML model

    private func detectWithModel(_ model: VNCoreMLModel, _ image: CGImage) -> Result {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit
        do { try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request]) } catch {
            log.error("Garment model failed: \(error.localizedDescription, privacy: .public)")
            return Result(failed: true)
        }
        var best: [GarmentCategory: LiveDetection] = [:]
        for observation in request.results as? [VNRecognizedObjectObservation] ?? [] {
            guard let label = observation.labels.first, label.confidence >= 0.5,
                  let category = Self.modelCategory(for: label.identifier) else { continue }
            let box = observation.boundingBox
            let detection = LiveDetection(category: category,
                                          bounds: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height),
                                          confidence: Double(label.confidence))
            if (best[category]?.confidence ?? 0) < detection.confidence { best[category] = detection }
        }
        return Result(detections: Array(best.values), hint: best.isEmpty ? .noPerson : nil)
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

    private func detectWithVision(_ image: CGImage, time: Double) -> Result {
        let pose = VNDetectHumanBodyPoseRequest()
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do { try VNImageRequestHandler(cgImage: image, orientation: .up).perform([pose, segmentation]) } catch {
            log.error("Vision failed: \(error.localizedDescription, privacy: .public)")
            return Result(failed: true)
        }
        // The largest pose is the person the user is pointing at.
        guard let joints = (pose.results ?? []).map(PoseJoints.init).filter({ $0.points.count >= 4 }).max(by: { $0.area < $1.area }),
              let grid = ColorGrid(image) else {
            return Result(hint: .noPerson)
        }
        let scene = Scene(image: image, joints: joints, grid: grid,
                          mask: segmentation.results?.first.map { ByteMask($0.pixelBuffer) },
                          aspect: Double(image.height) / Double(image.width))
        let skin = faceSkin(scene)

        var result = Result()
        let upper = upperBody(scene, skin: skin, time: time)
        result.detections += upper
        if let pants = pants(scene, skin: skin, time: time) { result.detections.append(pants) }
        switch shoes(scene, time: time) {
        case .found(let shoes): result.detections.append(shoes)
        case .feetOutOfFrame: result.hint = .includeFeet
        case .notFound: break
        }
        if result.hint == nil, joints[.leftShoulder] == nil || joints[.rightShoulder] == nil { result.hint = .includeUpperBody }
        return result
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
            return mask.box(in: clamped)
        }
    }

    /// The face's skin tone, sampled on the cheek just below the nose. Nil when the face isn't visible.
    private func faceSkin(_ s: Scene) -> SIMD3<Float>? {
        guard let nose = s.joints[.nose] else { return nil }
        let eyes = [s.joints[.leftEye], s.joints[.rightEye]].compactMap { $0 }
        let eyeGap = eyes.count == 2 ? abs(eyes[0].x - eyes[1].x) / s.aspect : 0.02
        let size = max(0.008, eyeGap * 0.5)
        return s.sample(at: CGPoint(x: nose.x, y: nose.y + size * 0.6), size: size)
    }

    private func isSkin(_ color: SIMD3<Float>?, _ skin: SIMD3<Float>?) -> Bool {
        guard let color, let skin else { return false }
        return deltaE(color, skin) < 16
    }

    // MARK: Upper body: Jacket and/or T-shirt

    private func upperBody(_ s: Scene, skin: SIMD3<Float>?, time: Double) -> [LiveDetection] {
        let j = s.joints
        guard let ls = j[.leftShoulder], let rs = j[.rightShoulder], let hip = j.mid(.leftHip, .rightHip) else { return [] }
        let shoulderY = (ls.y + rs.y) / 2
        let torso = hip.y - shoulderY
        let minS = min(ls.x, rs.x), maxS = max(ls.x, rs.x), w = maxS - minS
        guard torso > 0.05, w > 0.02 else { return [] }
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
        let jacketScore = score(["jacket", "hoodie", "suit", "lab_coat"], key: "upper", box: context, s, time: time)
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

        // With the classifier already seeing a jacket, a smaller contrast (dark tee, black jacket) counts.
        // A single garment measures 0–4 here, so 6 still keeps one closed top from splitting in two.
        let contrast: Float = jacketScore >= 0.2 ? 6 : 20
        if let ch = centreHigh, let cl = centreLow, let a = panelA, let b = panelB,
           deltaE(ch, a) > contrast, deltaE(ch, b) > contrast, deltaE(cl, a) > contrast, deltaE(cl, b) > contrast,
           deltaE(ch, cl) < 16, deltaE(a, b) < 14 {
            let sleevesMatch = upperArms.contains { deltaE($0, a) < 16 || deltaE($0, b) < 16 }
            if sleevesMatch || jacketScore >= 0.08 {
                // Open jacket over an inner top: the inner strip runs from the neckline to the hem.
                let jacket = s.tighten(CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: hemY(matching: a) - outer.minY)) ?? outer
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
        if shortSleeves, jacketScore < 0.2 {
            // Without long sleeves the garment is the torso plus upper arms, not out to the wrists.
            let elbowXs = [j[.leftElbow], j[.rightElbow]].compactMap { $0?.x } + [minS, maxS]
            let teeTop = shoulderY - torso * 0.2  // the collar sits well above the shoulder joints
            let tee = s.tighten(CGRect(x: (elbowXs.min() ?? minS) - w * 0.15, y: teeTop,
                                       width: (elbowXs.max() ?? maxS) - (elbowXs.min() ?? minS) + w * 0.3, height: hem - teeTop))
            return tee.map { [LiveDetection(category: .tshirt, bounds: $0, confidence: 0.6, color: centreHigh ?? panelA)] } ?? []
        }
        return []
    }

    // MARK: Pants

    private func pants(_ s: Scene, skin: SIMD3<Float>?, time: Double) -> LiveDetection? {
        let j = s.joints
        guard let hip = j.mid(.leftHip, .rightHip),
              let ankleY = [j[.leftAnkle], j[.rightAnkle]].compactMap({ $0.map { Double($0.y) } }).max() else { return nil }
        let legs: [(PoseJoints.Name, PoseJoints.Name, PoseJoints.Name)] = [(.leftHip, .leftKnee, .leftAnkle), (.rightHip, .rightKnee, .rightAnkle)]
        let span = ankleY - hip.y
        guard span > 0.08 else { return nil }
        var covered = false, bareShin = false
        var thighColor: SIMD3<Float>?
        for (h, k, a) in legs {
            guard let hp = j[h], let kn = j[k], let an = j[a] else { continue }
            let thigh = s.sample(at: lerp(hp, kn, 0.5), size: span * 0.06)
            let shin = s.sample(at: lerp(kn, an, 0.55), size: span * 0.05)
            if isSkin(shin, skin) { bareShin = true }
            if let thigh, let shin, deltaE(thigh, shin) < 16 { covered = true }
            thighColor = thighColor ?? thigh
        }
        guard covered, !bareShin else { return nil }

        let xs = j.xs([.leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle])
        let pad = span * 0.12 * s.aspect
        guard let box = s.tighten(CGRect(x: (xs.min() ?? hip.x) - pad, y: hip.y - span * 0.04,
                                         width: (xs.max() ?? hip.x) - (xs.min() ?? hip.x) + pad * 2, height: span * 1.03)) else { return nil }
        let jeans = score(["jeans"], key: "legs", box: box, s, time: time)
        // Without a face to compare skin against, bare legs look "covered", so ask the classifier too.
        guard skin != nil || jeans >= 0.15 else { return nil }
        return LiveDetection(category: .pants, bounds: box, confidence: min(1, 0.55 + Double(jeans)), color: thighColor)
    }

    // MARK: Shoes

    private enum ShoeResult { case found(LiveDetection), feetOutOfFrame, notFound }

    private func shoes(_ s: Scene, time: Double) -> ShoeResult {
        let j = s.joints
        let ankles = [j[.leftAnkle], j[.rightAnkle]].compactMap { $0 }
        guard !ankles.isEmpty else {
            // Hips or knees but no ankles: the feet are below the frame.
            return j.mid(.leftHip, .rightHip) != nil || j.y([.leftKnee, .rightKnee]) != nil ? .feetOutOfFrame : .notFound
        }
        guard let kneeY = j.y([.leftKnee, .rightKnee]), let hip = j.mid(.leftHip, .rightHip) else { return .notFound }
        let ys = ankles.map { Double($0.y) }, xs = ankles.map { Double($0.x) }
        let highest = ys.min() ?? 0, lowest = ys.max() ?? 0
        // Scale from the whole leg, which foreshortens less than the shin when filmed from above.
        let leg = max(lowest - hip.y, (lowest - kneeY) * 2)
        guard leg > 0.04 else { return .notFound }
        let pad = leg * 0.16 * s.aspect
        let band = CGRect(x: (xs.min() ?? 0.5) - pad, y: highest - leg * 0.06,
                          width: (xs.max() ?? 0.5) - (xs.min() ?? 0.5) + pad * 2, height: lowest - highest + leg * 0.5)
        // The person mask ends at the soles, so the box stops there rather than on the floor.
        guard let box = s.tighten(band) else { return .notFound }
        guard box.maxY < 0.985, band.maxY < 1.02 else { return .feetOutOfFrame }
        let shoeScore = score(["shoes", "footwear", "sneaker", "boot", "high_heel", "sandal"], key: "feet", box: box, s, time: time)
        #if DEBUG
        Self.trace?(String(format: "shoes: leg %.3f, box y %.3f–%.3f, score %.2f", leg, box.minY, box.maxY, shoeScore))
        #endif
        guard shoeScore >= 0.1 else { return .notFound }
        // The lower half of the box is shoe, not trouser hem; only the person's pixels count, not the ground.
        let soles = s.mean(CGRect(x: box.minX, y: box.midY, width: box.width, height: box.height / 2))
        return .found(LiveDetection(category: .shoes, bounds: box, confidence: min(1, 0.5 + Double(shoeScore)), color: soles))
    }

    // MARK: Classifier

    /// The highest of `labels`' confidences from Vision's image classifier, run on the box's crop.
    /// Cached per body area while the box hasn't moved much.
    private func score(_ labels: [String], key: String, box: CGRect, _ s: Scene, time: Double) -> Float {
        if let cached = classified[key], time - cached.time < 0.5, iou(cached.box, box) > 0.5 {
            return labels.compactMap { cached.scores[$0] }.max() ?? 0
        }
        let w = Double(s.image.width), h = Double(s.image.height)
        let pixels = CGRect(x: box.minX * w, y: box.minY * h, width: box.width * w, height: box.height * h).integral
        guard pixels.width >= 16, pixels.height >= 16, let crop = s.image.cropping(to: pixels) else { return 0 }
        let request = VNClassifyImageRequest()
        guard (try? VNImageRequestHandler(cgImage: crop, orientation: .up).perform([request])) != nil else { return 0 }
        var scores: [String: Float] = [:]
        for observation in request.results ?? [] where observation.confidence > 0.01 {
            scores[observation.identifier] = observation.confidence
        }
        classified[key] = (time, box, scores)
        return labels.compactMap { scores[$0] }.max() ?? 0
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

/// CIE76 colour difference between two sRGB colours (0–1 components).
nonisolated func deltaE(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    let la = lab(a), lb = lab(b)
    let d = la - lb
    return (d * d).sum().squareRoot()
}

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
    let points: [Name: CGPoint]

    init(_ observation: VNHumanBodyPoseObservation) {
        let recognized = (try? observation.recognizedPoints(.all)) ?? [:]
        points = recognized.compactMapValues { $0.confidence > 0.3 ? CGPoint(x: $0.location.x, y: 1 - $0.location.y) : nil }
    }

    subscript(_ name: Name) -> CGPoint? { points[name] }

    /// Area of the joints' bounding box, to pick the most prominent person.
    var area: Double {
        let xs = points.values.map(\.x), ys = points.values.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return 0 }
        return (x1 - x0) * (y1 - y0)
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

/// The frame downscaled to a small RGB grid, for colour sampling and a sharpness estimate.
nonisolated struct ColorGrid {
    let width: Int
    let height: Int
    private let rgb: [Float]

    init?(_ image: CGImage, maxWidth: Int = 160) {
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

/// Vision's person segmentation (one byte per pixel, row 0 = top).
nonisolated struct ByteMask {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        var bytes = [UInt8](repeating: 0, count: w * h)
        if let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
            for y in 0..<h { for x in 0..<w { bytes[y * w + x] = base[y * stride + x] } }
        }
        width = w
        height = h
        self.bytes = bytes
    }

    func isOn(x: Double, y: Double) -> Bool {
        let px = min(width - 1, max(0, Int(x * Double(width)))), py = min(height - 1, max(0, Int(y * Double(height))))
        return bytes[py * width + px] > 127
    }

    /// Bounding box of the person's pixels inside `rect` (normalized), or nil if there are too few.
    func box(in rect: CGRect) -> CGRect? {
        let x0 = max(0, Int(rect.minX * Double(width))), x1 = min(width - 1, Int(rect.maxX * Double(width)))
        let y0 = max(0, Int(rect.minY * Double(height))), y1 = min(height - 1, Int(rect.maxY * Double(height)))
        guard x0 <= x1, y0 <= y1 else { return nil }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, count = 0
        for y in y0...y1 {
            for x in x0...x1 where bytes[y * width + x] > 127 {
                count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let area = (x1 - x0 + 1) * (y1 - y0 + 1)
        guard count >= max(12, area / 20) else { return nil }
        return CGRect(x: Double(minX) / Double(width), y: Double(minY) / Double(height),
                      width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height))
    }
}
