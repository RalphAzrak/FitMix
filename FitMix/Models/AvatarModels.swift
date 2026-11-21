import Foundation

nonisolated enum UnitSystem: String, Codable, CaseIterable, Sendable {
    case metric, imperial

    var title: String { self == .metric ? "Metric" : "Imperial" }
}

/// How the avatar's face was captured.
nonisolated enum FaceCaptureKind: String, Codable, Sendable {
    /// ARKit face-tracking geometry (TrueDepth camera).
    case mesh
    /// A single front-facing photo. The result is a photo-based approximation.
    case photo
}

nonisolated enum SetupStep: Int, Codable, CaseIterable, Sendable {
    case face, body, metrics, review
}

nonisolated enum GenerationState: Codable, Equatable, Sendable {
    case idle
    case generating
    case ready
    case failed(String)
}

/// Everything FitMix remembers about the avatar, apart from the capture files themselves.
nonisolated struct AvatarProfile: Codable, Equatable, Sendable {
    var setupCompleted = false
    var currentStep: SetupStep = .face
    var faceKind: FaceCaptureKind?
    var hasBodyPhoto = false
    var heightCm: Double?
    var weightKg: Double?
    var units: UnitSystem = .metric
    var generation: GenerationState = .idle
    var shape: BodyShape?
    /// Result of checking the full-body photo. `nil` means the check could not run.
    var photoAnalysis: BodyPhotoAnalysis?

    var hasMetrics: Bool { heightCm != nil && weightKg != nil }
    var stepsDone: Int { (faceKind != nil ? 1 : 0) + (hasBodyPhoto ? 1 : 0) + (hasMetrics ? 1 : 0) }
    var setupStarted: Bool { stepsDone > 0 }
}

/// What the full-body photo check measured. Widths are fractions of the person's height in the photo.
nonisolated struct BodyPhotoAnalysis: Codable, Equatable, Sendable {
    var personDetected: Bool
    var fullBodyVisible: Bool
    var shoulderRatio: Double?
    var chestRatio: Double?
    var waistRatio: Double?
    var hipRatio: Double?
}

/// Approximate body proportions for the avatar, in metres.
nonisolated struct BodyShape: Codable, Equatable, Sendable {
    var heightM: Double
    var shoulderWidth: Double
    var chestWidth: Double
    var waistWidth: Double
    var hipWidth: Double
    /// Overall girth factor from BMI (1 = reference build).
    var girth: Double
    /// True when the photo outline adjusted the widths; false when only height and weight were used.
    var usedPhotoOutline: Bool

    static let template = estimate(heightCm: 172, weightKg: 63.6, analysis: nil)

    /// Starts from average proportions scaled by height and BMI, then nudges the widths
    /// toward the photo outline when a full body was found. This is an approximation, not a measurement.
    static func estimate(heightCm: Double, weightKg: Double, analysis: BodyPhotoAnalysis?) -> BodyShape {
        let h = heightCm / 100
        let bmi = weightKg / (h * h)
        let g = min(max((bmi / 21.5).squareRoot(), 0.78), 1.5)
        var shoulder = 0.252 * pow(g, 0.35)
        var chest = 0.176 * g
        var waist = 0.150 * pow(g, 1.25)
        var hip = 0.186 * g
        var used = false

        if let a = analysis, a.personDetected, a.fullBodyVisible {
            func nudge(_ prior: Double, _ measured: Double?) -> Double {
                guard let m = measured, m > 0 else { return prior }
                used = true
                // Clothing and arms widen the outline, so keep the photo's influence bounded.
                let bounded = min(max(m, prior * 0.82), prior * 1.22)
                return prior + 0.6 * (bounded - prior)
            }
            shoulder = nudge(shoulder, a.shoulderRatio)
            chest = nudge(chest, a.chestRatio)
            waist = nudge(waist, a.waistRatio)
            hip = nudge(hip, a.hipRatio)
        }
        return BodyShape(heightM: h, shoulderWidth: shoulder * h, chestWidth: chest * h,
                         waistWidth: waist * h, hipWidth: hip * h, girth: g, usedPhotoOutline: used)
    }
}

/// ARKit face geometry saved from the scan, in metres, in the face anchor's coordinate space.
nonisolated struct FaceMeshData: Codable, Sendable {
    /// x, y, z per vertex.
    var vertices: [Float]
    /// u, v per vertex into the face texture, with v measured from the top of the image. Empty if there is no texture.
    var uvs: [Float]
    var indices: [UInt32]

    var vertexCount: Int { vertices.count / 3 }

    var isValid: Bool {
        vertexCount >= 3 && vertices.count % 3 == 0 && indices.count >= 3 && indices.count % 3 == 0
            && (uvs.isEmpty || uvs.count == vertexCount * 2)
            && indices.allSatisfy { Int($0) < vertexCount }
            && vertices.allSatisfy { $0.isFinite }
    }
}

nonisolated enum BodyMeasurements {
    static let heightRangeCm = 100.0...250.0
    static let weightRangeKg = 30.0...300.0
    static let cmPerInch = 2.54
    static let lbPerKg = 2.2046226218

    static func feetInches(fromCm cm: Double) -> (feet: Int, inches: Int) {
        let total = Int((cm / cmPerInch).rounded())
        return (total / 12, total % 12)
    }

    static func cm(feet: Double, inches: Double) -> Double { (feet * 12 + inches) * cmPerInch }
    static func pounds(fromKg kg: Double) -> Double { kg * lbPerKg }
    static func kg(fromPounds lb: Double) -> Double { lb / lbPerKg }

    static func bmi(heightCm: Double, weightKg: Double) -> Double {
        let h = heightCm / 100
        return weightKg / (h * h)
    }

    /// Shortest sensible text for a number: "178", "68.5".
    static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    static func heightText(cm: Double, units: UnitSystem) -> String {
        switch units {
        case .metric: return "\(trimmed(cm)) cm"
        case .imperial:
            let (ft, inch) = feetInches(fromCm: cm)
            return "\(ft) ft \(inch) in"
        }
    }

    static func weightText(kg: Double, units: UnitSystem) -> String {
        switch units {
        case .metric: return "\(trimmed(kg)) kg"
        case .imperial: return "\(trimmed(pounds(fromKg: kg))) lb"
        }
    }

    static func heightError(cm: Double?, units: UnitSystem) -> String? {
        guard let cm else { return nil }
        if heightRangeCm.contains(cm) { return nil }
        return units == .metric ? "Enter a height between 100 and 250 cm."
                                : "Enter a height between 3 ft 4 in and 8 ft 2 in."
    }

    static func weightError(kg: Double?, units: UnitSystem) -> String? {
        guard let kg else { return nil }
        if weightRangeKg.contains(kg) { return nil }
        return units == .metric ? "Enter a weight between 30 and 300 kg."
                                : "Enter a weight between 67 and 661 lb."
    }

    static func isValid(heightCm: Double?, weightKg: Double?) -> Bool {
        guard let heightCm, let weightKg else { return false }
        return heightRangeCm.contains(heightCm) && weightRangeKg.contains(weightKg)
    }
}
