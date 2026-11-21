import SwiftUI
import UIKit

/// Where the avatar's files live. Everything stays in the app's own container on this device.
nonisolated struct AvatarFiles: Sendable {
    let directory: URL
    var profile: URL { directory.appendingPathComponent("profile.json") }
    var bodyPhoto: URL { directory.appendingPathComponent("bodyPhoto.jpg") }
    var faceMesh: URL { directory.appendingPathComponent("faceMesh.plist") }
    /// Camera crop mapped onto the face mesh, or the cropped face photo for the photo fallback.
    var faceTexture: URL { directory.appendingPathComponent("faceTexture.jpg") }
    /// Upright picture of the face capture, shown when reviewing.
    var faceThumbnail: URL { directory.appendingPathComponent("faceThumbnail.jpg") }

    static var standard: AvatarFiles {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AvatarFiles(directory: base.appendingPathComponent("Avatar", isDirectory: true))
    }
}

/// A finished face scan, before it is saved.
struct FaceMeshCapture {
    var mesh: FaceMeshData
    var texture: CGImage?
    var thumbnail: UIImage?
}

enum AvatarError: LocalizedError {
    case missingFace, missingBodyPhoto, missingMeasurements, unreadableFaceScan, saveFailed

    var errorDescription: String? {
        switch self {
        case .missingFace: "Your face capture is missing. Delete the avatar and run setup again."
        case .missingBodyPhoto: "Your full-body photo is missing. Add a photo and try again."
        case .missingMeasurements: "Your height and weight are missing. Enter them and try again."
        case .unreadableFaceScan: "Your face scan couldn't be read. Delete the avatar and scan again."
        case .saveFailed: "FitMix couldn't save to this iPhone. Check available storage and try again."
        }
    }
}

enum HomeState: Equatable {
    case empty
    case setupInProgress
    case generating
    case ready
    case error(String)
}

/// Owns the saved avatar: setup progress, captures, measurements, and generation.
/// Captures are never logged or sent anywhere.
@Observable
final class AvatarStore {
    private(set) var profile = AvatarProfile()
    private(set) var bodyPhoto: UIImage?
    private(set) var faceThumbnail: UIImage?
    private(set) var progressLabel = ""
    /// Changes whenever the avatar on screen needs rebuilding.
    private(set) var avatarRevision = 0
    /// Set when saving to disk fails, so the UI can say so.
    var storageErrorMessage: String?

    let files: AvatarFiles
    @ObservationIgnored private var generationTask: Task<Void, Never>?

    init(files: AvatarFiles = .standard) {
        self.files = files
        if let data = try? Data(contentsOf: files.profile),
           let saved = try? JSONDecoder().decode(AvatarProfile.self, from: data) {
            profile = saved
        }
        bodyPhoto = UIImage(contentsOfFile: files.bodyPhoto.path)
        faceThumbnail = UIImage(contentsOfFile: files.faceThumbnail.path)
        // The app was closed mid-generation: pick it back up.
        if profile.setupCompleted, profile.generation == .generating { generate() }
    }

    var homeState: HomeState {
        guard profile.setupCompleted else { return profile.setupStarted ? .setupInProgress : .empty }
        switch profile.generation {
        case .generating: return .generating
        case .ready: return profile.shape == nil ? .error(AvatarError.saveFailed.localizedDescription) : .ready
        case .failed(let message): return .error(message)
        case .idle: return .setupInProgress
        }
    }

    /// The personalized result is shown only once it has been generated and saved.
    var hasPersonalizedAvatar: Bool { profile.setupCompleted && profile.shape != nil && profile.faceKind != nil }

    // MARK: Setup and edits

    func setStep(_ step: SetupStep) {
        profile.currentStep = step
        persist()
    }

    func saveFaceScan(_ capture: FaceMeshCapture) {
        do {
            try prepareDirectory()
            try write(PropertyListEncoder.binary.encode(capture.mesh), to: files.faceMesh)
            if let texture = capture.texture, let data = UIImage(cgImage: texture).jpegData(compressionQuality: 0.92) {
                try write(data, to: files.faceTexture)
            } else {
                try? FileManager.default.removeItem(at: files.faceTexture)
            }
            if let thumb = capture.thumbnail?.normalized(maxDimension: 600), let data = thumb.jpegData(compressionQuality: 0.85) {
                try write(data, to: files.faceThumbnail)
                faceThumbnail = thumb
            } else {
                try? FileManager.default.removeItem(at: files.faceThumbnail)
                faceThumbnail = nil
            }
            profile.faceKind = .mesh
            faceDidChange()
        } catch { storageErrorMessage = AvatarError.saveFailed.localizedDescription }
    }

    func saveFacePhoto(crop: CGImage) {
        let image = UIImage(cgImage: crop).normalized(maxDimension: 1024)
        guard let data = image.jpegData(compressionQuality: 0.92) else { return }
        do {
            try prepareDirectory()
            try write(data, to: files.faceTexture)
            try write(data, to: files.faceThumbnail)
            try? FileManager.default.removeItem(at: files.faceMesh)
            faceThumbnail = image
            profile.faceKind = .photo
            faceDidChange()
        } catch { storageErrorMessage = AvatarError.saveFailed.localizedDescription }
    }

    func saveBodyPhoto(_ image: UIImage, analysis: BodyPhotoAnalysis?) {
        let normalized = image.normalized()
        guard let data = normalized.jpegData(compressionQuality: 0.9) else { return }
        do {
            try prepareDirectory()
            try write(data, to: files.bodyPhoto)
            bodyPhoto = normalized
            profile.hasBodyPhoto = true
            profile.photoAnalysis = analysis
            persist()
            if profile.setupCompleted { generate() }
        } catch { storageErrorMessage = AvatarError.saveFailed.localizedDescription }
    }

    /// Removes the full-body (try-on) photo from this iPhone. The avatar keeps the shape it already
    /// has; updating it later needs a new photo. Studio drops the photo too (see `MyApp`).
    func removeBodyPhoto() {
        do {
            if FileManager.default.fileExists(atPath: files.bodyPhoto.path) {
                try FileManager.default.removeItem(at: files.bodyPhoto)
            }
        } catch {
            storageErrorMessage = "FitMix couldn't remove the photo from this iPhone. Try again."
            return
        }
        bodyPhoto = nil
        profile.hasBodyPhoto = false
        profile.photoAnalysis = nil
        persist()
    }

    func setMeasurements(heightCm: Double, weightKg: Double) {
        guard BodyMeasurements.isValid(heightCm: heightCm, weightKg: weightKg) else { return }
        let changed = profile.heightCm != heightCm || profile.weightKg != weightKg
        profile.heightCm = heightCm
        profile.weightKg = weightKg
        persist()
        if changed, profile.setupCompleted { generate() }
    }

    func setUnits(_ units: UnitSystem) {
        guard profile.units != units else { return }
        profile.units = units
        persist()
    }

    func completeSetup() {
        profile.setupCompleted = true
        profile.currentStep = .review
        generate()
    }

    /// Removes the avatar, the face capture, the full-body photo, and the measurements.
    func deleteEverything() {
        generationTask?.cancel()
        generationTask = nil
        try? FileManager.default.removeItem(at: files.directory)
        profile = AvatarProfile()
        bodyPhoto = nil
        faceThumbnail = nil
        progressLabel = ""
        avatarRevision += 1
    }

    // MARK: Generation

    func generate() {
        generationTask?.cancel()
        profile.generation = .generating
        progressLabel = "Reading your full-body photo…"
        persist()
        let files = files
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let height = profile.heightCm, let weight = profile.weightKg else { throw AvatarError.missingMeasurements }
                guard let faceKind = profile.faceKind else { throw AvatarError.missingFace }
                guard FileManager.default.fileExists(atPath: files.bodyPhoto.path) else { throw AvatarError.missingBodyPhoto }

                let analysis = await BodyPhotoAnalyzer.analyze(fileURL: files.bodyPhoto)
                try Task.checkCancellation()

                progressLabel = "Shaping body proportions…"
                let shape = BodyShape.estimate(heightCm: height, weightKg: weight, analysis: analysis)

                progressLabel = "Fitting your face…"
                switch faceKind {
                case .mesh:
                    guard let mesh = AvatarStore.loadFaceMesh(from: files), mesh.isValid else { throw AvatarError.unreadableFaceScan }
                case .photo:
                    guard FileManager.default.fileExists(atPath: files.faceTexture.path) else { throw AvatarError.missingFace }
                }
                try Task.checkCancellation()

                profile.photoAnalysis = analysis
                profile.shape = shape
                profile.generation = .ready
                guard persist() else { throw AvatarError.saveFailed }
                avatarRevision += 1
            } catch is CancellationError {
                // A newer request replaced this one.
            } catch {
                profile.generation = .failed(error.localizedDescription)
                persist()
            }
        }
    }

    static func loadFaceMesh(from files: AvatarFiles) -> FaceMeshData? {
        guard let data = try? Data(contentsOf: files.faceMesh) else { return nil }
        return try? PropertyListDecoder().decode(FaceMeshData.self, from: data)
    }

    // MARK: Disk

    private func faceDidChange() {
        persist()
        avatarRevision += 1
        if profile.setupCompleted { generate() }
    }

    private func prepareDirectory() throws {
        var dir = files.directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        // Keep captures on this device only: no iCloud or computer backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try prepareDirectory()
            try write(JSONEncoder().encode(profile), to: files.profile)
            return true
        } catch {
            storageErrorMessage = AvatarError.saveFailed.localizedDescription
            return false
        }
    }
}

private extension PropertyListEncoder {
    static var binary: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}
