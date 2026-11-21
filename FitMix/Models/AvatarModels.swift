import Foundation

nonisolated enum UnitSystem: String, Codable, CaseIterable, Sendable {
    case metric, imperial

    var title: String { self == .metric ? "Metric" : "Imperial" }
}

/// The steps of creating an avatar, in order.
nonisolated enum SetupStep: String, Codable, CaseIterable, Sendable {
    case bodyPhoto, selfie, measurements, generate, review
}

/// What one generated portrait was made from. Kept with the picture so the screen can say so, and can tell
/// when the measurements have changed since.
nonisolated struct AvatarRecord: Codable, Equatable, Sendable {
    var createdAt: Date
    var usedSelfie: Bool
    var heightCm: Double
    var weightKg: Double
}

/// Everything FitMix remembers about the avatar, apart from the pictures themselves.
nonisolated struct AvatarProfile: Codable, Equatable, Sendable {
    var hasBodyPhoto = false
    var hasSelfie = false
    var heightCm: Double?
    var weightKg: Double?
    var units: UnitSystem = .metric
    var currentStep: SetupStep = .bodyPhoto
    /// Result of checking the full-body photo. `nil` means the check could not run.
    var photoAnalysis: BodyPhotoAnalysis?
    /// Whether a face was found in the selfie. `nil` means the check could not run.
    var selfieHasFace: Bool?
    /// The avatar the user accepted. It stays until they accept a replacement.
    var avatar: AvatarRecord?
    /// A newly generated portrait the user has not decided on yet.
    var candidate: AvatarRecord?

    var hasMetrics: Bool { heightCm != nil && weightKg != nil }
    var setupStarted: Bool { hasBodyPhoto || hasSelfie || hasMetrics || avatar != nil || candidate != nil }
    var readyToGenerate: Bool { hasBodyPhoto && BodyMeasurements.isValid(heightCm: heightCm, weightKg: weightKg) }

    /// True when height or weight differ from what the accepted avatar was made with.
    var measurementsChangedSinceAvatar: Bool {
        guard let avatar, let heightCm, let weightKg else { return false }
        return abs(avatar.heightCm - heightCm) > 0.05 || abs(avatar.weightKg - weightKg) > 0.05
    }

    init() {}

    /// Also reads profiles saved by the earlier 3D-avatar version of FitMix: the full-body photo, height, weight
    /// and units carry over, and everything that version stored about its 3D model is ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasBodyPhoto = (try? c.decodeIfPresent(Bool.self, forKey: .hasBodyPhoto)) ?? false
        hasSelfie = (try? c.decodeIfPresent(Bool.self, forKey: .hasSelfie)) ?? false
        heightCm = try? c.decodeIfPresent(Double.self, forKey: .heightCm)
        weightKg = try? c.decodeIfPresent(Double.self, forKey: .weightKg)
        units = (try? c.decodeIfPresent(UnitSystem.self, forKey: .units)) ?? .metric
        currentStep = (try? c.decodeIfPresent(SetupStep.self, forKey: .currentStep)) ?? .bodyPhoto
        photoAnalysis = try? c.decodeIfPresent(BodyPhotoAnalysis.self, forKey: .photoAnalysis)
        selfieHasFace = try? c.decodeIfPresent(Bool.self, forKey: .selfieHasFace)
        avatar = try? c.decodeIfPresent(AvatarRecord.self, forKey: .avatar)
        candidate = try? c.decodeIfPresent(AvatarRecord.self, forKey: .candidate)
    }
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
