import SwiftUI
import UIKit

/// Where the avatar's files live. Everything stays in the app's own container on this device.
nonisolated struct AvatarFiles: Sendable {
    let directory: URL
    var profile: URL { directory.appendingPathComponent("profile.json") }
    var bodyPhoto: URL { directory.appendingPathComponent("bodyPhoto.jpg") }
    var selfie: URL { directory.appendingPathComponent("selfie.jpg") }
    /// The portrait the user accepted. This is the base image for wardrobe try-on.
    var avatar: URL { directory.appendingPathComponent("avatar.png") }
    /// A generated portrait waiting for the user's decision.
    var candidate: URL { directory.appendingPathComponent("candidate.png") }
    /// Face scans and 3D-model data kept by the earlier 3D-avatar version. Nothing reads them any more.
    var legacy: [URL] {
        ["faceMesh.plist", "faceTexture.jpg", "faceThumbnail.jpg", "personalization.json"].map { directory.appendingPathComponent($0) }
    }

    static var standard: AvatarFiles {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AvatarFiles(directory: base.appendingPathComponent("Avatar", isDirectory: true))
    }
}

enum AvatarError: LocalizedError {
    case missingBodyPhoto, missingMeasurements, saveFailed

    var errorDescription: String? {
        switch self {
        case .missingBodyPhoto: "Your full-body photo is missing. Add a photo and try again."
        case .missingMeasurements: "Your height and weight are missing. Enter them and try again."
        case .saveFailed: "FitMix couldn't save to this iPhone. Check available storage and try again."
        }
    }
}

/// Where a generation request stands. Not saved: after a relaunch there is either a finished picture or nothing.
enum GenerationPhase: Equatable {
    case idle
    case generating
    case failed(String)
}

enum HomeState: Equatable {
    case empty
    case setupInProgress
    case generating
    /// A new portrait is waiting for the user to accept or discard it.
    case reviewPending
    case ready
    case error(String)
}

/// Owns the saved avatar: the photos, the measurements, the accepted portrait, and any portrait awaiting review.
/// Photos are never logged. They leave the phone only when the user asks for a portrait to be generated.
@Observable
final class AvatarStore {
    private(set) var profile = AvatarProfile()
    private(set) var bodyPhoto: UIImage?
    /// Small copy of the full-body photo for lists and cards, so scrolling never resizes the full picture.
    private(set) var bodyThumbnail: UIImage?
    private(set) var selfie: UIImage?
    private(set) var avatarImage: UIImage?
    private(set) var candidateImage: UIImage?
    private(set) var generation: GenerationPhase = .idle
    /// Set when saving to disk fails, so the UI can say so.
    var storageErrorMessage: String?

    let files: AvatarFiles
    /// False when this build has no avatar service to call.
    let generationAvailable: Bool
    @ObservationIgnored private let generator: any AvatarGenerating
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var photoSaveTask: Task<Void, Never>?

    init(files: AvatarFiles = .standard, backend: BackendConfig? = .current) {
        var files = files
        #if DEBUG
        if let seeded = DebugSeed.prepare() { files = seeded }
        #endif
        self.files = files
        generationAvailable = backend != nil
        generator = BackendAvatarGenerator(config: backend)

        let manager = FileManager.default
        if let data = try? Data(contentsOf: files.profile), let saved = try? JSONDecoder().decode(AvatarProfile.self, from: data) {
            profile = saved
        }
        // The files are the truth: a record without its picture is dropped, and so is a step that needs one.
        profile.hasBodyPhoto = manager.fileExists(atPath: files.bodyPhoto.path)
        profile.hasSelfie = manager.fileExists(atPath: files.selfie.path)
        if !manager.fileExists(atPath: files.avatar.path) { profile.avatar = nil }
        if !manager.fileExists(atPath: files.candidate.path) { profile.candidate = nil }
        // Face scans from the earlier 3D-avatar version are not used any more, so they are not kept.
        for old in files.legacy { try? manager.removeItem(at: old) }

        #if DEBUG
        // Which things are saved, never the things themselves.
        print("FM_STATE photo \(profile.hasBodyPhoto) selfie \(profile.hasSelfie) measurements \(profile.hasMetrics) avatar \(profile.avatar != nil) candidate \(profile.candidate != nil) service \(backend != nil)")
        #endif
        // Pictures are decoded in the background so the first screen appears straight away.
        Task { [weak self, files] in
            let images = await AvatarStore.readImages(files)
            guard let self else { return }
            if bodyPhoto == nil { bodyPhoto = images.body; bodyThumbnail = images.bodyThumbnail }
            if selfie == nil { selfie = images.selfie }
            if avatarImage == nil { avatarImage = images.avatar }
            if candidateImage == nil { candidateImage = images.candidate }
        }
    }

    var homeState: HomeState {
        switch generation {
        case .generating: return .generating
        case .failed(let message): return .error(message)
        case .idle: break
        }
        if profile.candidate != nil { return .reviewPending }
        if profile.avatar != nil { return .ready }
        return profile.setupStarted ? .setupInProgress : .empty
    }

    /// Where the creation flow should open so the user carries on from where they were.
    var resumeStep: SetupStep {
        if profile.candidate != nil { return .review }
        if !profile.hasBodyPhoto { return .bodyPhoto }
        switch profile.currentStep {
        case .review: return .generate
        case .generate where !profile.readyToGenerate: return .measurements
        default: return profile.currentStep
        }
    }

    // MARK: Photos and measurements

    func setStep(_ step: SetupStep) {
        guard profile.currentStep != step else { return }
        profile.currentStep = step
        persist()
    }

    /// Saves an already-upright photo (see `UIImage.normalizedInBackground`). The screen updates at once;
    /// the file is compressed and written in the background.
    func saveBodyPhoto(_ image: UIImage, analysis: BodyPhotoAnalysis?) {
        bodyPhoto = image
        bodyThumbnail = nil
        profile.hasBodyPhoto = true
        profile.photoAnalysis = analysis
        do { try prepareDirectory() } catch { storageErrorMessage = AvatarError.saveFailed.localizedDescription; return }
        photoSaveTask?.cancel()
        photoSaveTask = Task { [files] in
            let saved = await AvatarStore.writePhoto(image, to: files.bodyPhoto)
            guard !Task.isCancelled else { return }
            if bodyPhoto === image { bodyThumbnail = saved.thumbnail }
            if saved.ok { persist() } else { storageErrorMessage = AvatarError.saveFailed.localizedDescription }
        }
    }

    func saveSelfie(_ image: UIImage, hasFace: Bool?) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        do {
            try prepareDirectory()
            try write(data, to: files.selfie)
            selfie = image
            profile.hasSelfie = true
            profile.selfieHasFace = hasFace
            persist()
        } catch { storageErrorMessage = AvatarError.saveFailed.localizedDescription }
    }

    func removeSelfie() {
        try? FileManager.default.removeItem(at: files.selfie)
        selfie = nil
        profile.hasSelfie = false
        profile.selfieHasFace = nil
        persist()
    }

    func setMeasurements(heightCm: Double, weightKg: Double) {
        guard BodyMeasurements.isValid(heightCm: heightCm, weightKg: weightKg) else { return }
        profile.heightCm = heightCm
        profile.weightKg = weightKg
        persist()
    }

    func setUnits(_ units: UnitSystem) {
        guard profile.units != units else { return }
        profile.units = units
        persist()
    }

    // MARK: Generation

    /// Asks the avatar service whether it can take a request. Sends nothing about the user.
    func serviceStatus() async -> AvatarServiceStatus { await generator.status() }

    /// Sends the saved photos and measurements to the avatar service and keeps the result as a portrait to
    /// review. The accepted avatar is not touched. Call only after the user has agreed to the upload.
    func generate() {
        guard generation != .generating else { return }
        guard profile.hasBodyPhoto else { generation = .failed(AvatarError.missingBodyPhoto.localizedDescription); return }
        guard let heightCm = profile.heightCm, let weightKg = profile.weightKg,
              BodyMeasurements.isValid(heightCm: heightCm, weightKg: weightKg) else {
            generation = .failed(AvatarError.missingMeasurements.localizedDescription)
            return
        }
        generation = .generating
        let files = files, generator = generator, includeSelfie = profile.hasSelfie
        generationTask = Task { [weak self] in
            do {
                // A photo chosen a moment ago may still be on its way to disk.
                await self?.photoSaveTask?.value
                let request = try await AvatarStore.makeRequest(files: files, includeSelfie: includeSelfie, heightCm: heightCm, weightKg: weightKg)
                try Task.checkCancellation()
                let data = try await generator.generate(request)
                try Task.checkCancellation()
                guard let self else { return }
                try prepareDirectory()
                guard let portrait = await AvatarStore.savePortrait(data, to: files.candidate) else { throw AvatarError.saveFailed }
                try Task.checkCancellation()
                candidateImage = portrait
                profile.candidate = AvatarRecord(createdAt: .now, usedSelfie: request.selfie != nil, heightCm: heightCm, weightKg: weightKg)
                profile.currentStep = .review
                guard persist() else { throw AvatarError.saveFailed }
                generation = .idle
            } catch is CancellationError {
                // The user cancelled; nothing was changed.
            } catch {
                self?.generation = .failed(error.localizedDescription)
            }
        }
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        generation = .idle
    }

    func clearGenerationError() {
        if case .failed = generation { generation = .idle }
    }

    /// Makes the reviewed portrait the user's avatar. Until this succeeds the previous avatar stays in place.
    @discardableResult
    func acceptCandidate() -> Bool {
        guard let record = profile.candidate, let portrait = candidateImage else { return false }
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: files.avatar.path) {
                _ = try manager.replaceItemAt(files.avatar, withItemAt: files.candidate)
            } else {
                try manager.moveItem(at: files.candidate, to: files.avatar)
            }
        } catch {
            storageErrorMessage = AvatarError.saveFailed.localizedDescription
            return false
        }
        avatarImage = portrait
        candidateImage = nil
        profile.avatar = record
        profile.candidate = nil
        profile.currentStep = .bodyPhoto
        persist()
        return true
    }

    func discardCandidate() {
        try? FileManager.default.removeItem(at: files.candidate)
        candidateImage = nil
        profile.candidate = nil
        persist()
    }

    /// Removes the avatar, the photos and the measurements from this iPhone.
    func deleteEverything() {
        generationTask?.cancel()
        generationTask = nil
        photoSaveTask?.cancel()
        photoSaveTask = nil
        try? FileManager.default.removeItem(at: files.directory)
        profile = AvatarProfile()
        bodyPhoto = nil
        bodyThumbnail = nil
        selfie = nil
        avatarImage = nil
        candidateImage = nil
        generation = .idle
    }

    // MARK: Background work

    /// Prepares exactly what will be uploaded: each picture redrawn upright at a modest size, which also
    /// leaves out the camera's metadata (such as location).
    @concurrent
    private nonisolated static func makeRequest(files: AvatarFiles, includeSelfie: Bool, heightCm: Double, weightKg: Double) async throws -> AvatarGenerationRequest {
        guard let body = UIImage(contentsOfFile: files.bodyPhoto.path), let bodyData = await body.uploadJPEG() else {
            throw AvatarError.missingBodyPhoto
        }
        var selfieData: Data?
        if includeSelfie, let selfie = UIImage(contentsOfFile: files.selfie.path) { selfieData = await selfie.uploadJPEG(maxDimension: 1280) }
        return AvatarGenerationRequest(bodyPhoto: bodyData, selfie: selfieData, heightCm: heightCm, weightKg: weightKg)
    }

    @concurrent
    private nonisolated static func savePortrait(_ data: Data, to url: URL) async -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        do { try data.write(to: url, options: [.atomic, .completeFileProtection]) } catch { return nil }
        return image.preparingForDisplay() ?? image
    }

    @concurrent
    private nonisolated static func writePhoto(_ image: UIImage, to url: URL) async -> (ok: Bool, thumbnail: UIImage?) {
        let thumbnail = image.normalized(maxDimension: 360)
        guard let data = image.jpegData(compressionQuality: 0.9) else { return (false, thumbnail) }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return (true, thumbnail)
        } catch {
            return (false, thumbnail)
        }
    }

    private struct SavedImages: @unchecked Sendable {
        var body, bodyThumbnail, selfie, avatar, candidate: UIImage?
    }

    @concurrent
    private nonisolated static func readImages(_ files: AvatarFiles) async -> SavedImages {
        func display(_ url: URL) -> UIImage? { UIImage(contentsOfFile: url.path).map { $0.preparingForDisplay() ?? $0 } }
        let body = UIImage(contentsOfFile: files.bodyPhoto.path)
        return SavedImages(body: body, bodyThumbnail: body?.normalized(maxDimension: 360),
                           selfie: UIImage(contentsOfFile: files.selfie.path)?.normalized(maxDimension: 720),
                           avatar: display(files.avatar), candidate: display(files.candidate))
    }

    // MARK: Disk

    private func prepareDirectory() throws {
        var dir = files.directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        // Keep photos on this device only: no iCloud or computer backups.
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

#if DEBUG
/// Development aid: starts the app from test files in a scratch folder, so each screen can be checked in the
/// Simulator without a camera. The real saved avatar is not touched.
///   FM_DEBUG_SEED_PHOTO   path to a picture used as the saved full-body photo ("none" for a fresh start,
///                         "keep" to reuse what the last run left)
///   FM_DEBUG_SEED_SELFIE  path to a picture used as the saved selfie
///   FM_DEBUG_SEED_BODY    "heightCm,weightKg"
///   FM_DEBUG_SEED_AVATAR  path to a picture used as the accepted avatar
///   FM_DEBUG_SEED_LEGACY  1 = write the profile the way the earlier 3D-avatar version did, to check the carry-over
enum DebugSeed {
    static func prepare() -> AvatarFiles? {
        let env = ProcessInfo.processInfo.environment
        guard let photo = env["FM_DEBUG_SEED_PHOTO"] else { return nil }
        let manager = FileManager.default
        let files = AvatarFiles(directory: manager.temporaryDirectory.appendingPathComponent("AvatarSeed", isDirectory: true))
        // FM_DEBUG_SEED_PHOTO=keep reuses whatever the last run left, to check that things survive a relaunch.
        if photo == "keep" { return files }
        try? manager.removeItem(at: files.directory)
        try? manager.createDirectory(at: files.directory, withIntermediateDirectories: true)
        func copy(_ path: String?, to url: URL, png: Bool = false) -> Bool {
            guard let path, let image = UIImage(contentsOfFile: path) else { return false }
            return (try? (png ? image.pngData() : image.jpegData(compressionQuality: 0.9))?.write(to: url)) != nil
        }
        let hasPhoto = copy(photo, to: files.bodyPhoto)
        let hasSelfie = copy(env["FM_DEBUG_SEED_SELFIE"], to: files.selfie)
        let hasAvatar = copy(env["FM_DEBUG_SEED_AVATAR"], to: files.avatar, png: true)
        let body = (env["FM_DEBUG_SEED_BODY"] ?? "").split(separator: ",").compactMap { Double($0) }
        if env["FM_DEBUG_SEED_LEGACY"] != nil {
            let old: [String: Any] = ["setupCompleted": true, "currentStep": 3, "faceKind": "mesh", "hasBodyPhoto": hasPhoto,
                                      "heightCm": body.first ?? 178, "weightKg": body.count > 1 ? body[1] : 74, "units": "imperial",
                                      "generation": ["ready": [String: Any]()]]
            try? JSONSerialization.data(withJSONObject: old).write(to: files.profile)
            try? Data("old face scan".utf8).write(to: files.legacy[0])
            return files
        }
        var profile = AvatarProfile()
        profile.hasBodyPhoto = hasPhoto
        profile.hasSelfie = hasSelfie
        if body.count > 1 { profile.heightCm = body[0]; profile.weightKg = body[1] }
        if hasAvatar {
            // FM_DEBUG_SEED_AVATAR_OLD: the avatar was made before the weight was last edited.
            let weight = (profile.weightKg ?? 74) - (env["FM_DEBUG_SEED_AVATAR_OLD"] != nil ? 6 : 0)
            profile.avatar = AvatarRecord(createdAt: .now, usedSelfie: hasSelfie, heightCm: profile.heightCm ?? 178, weightKg: weight)
        }
        if let step = env["FM_DEBUG_STEP"].flatMap(SetupStep.init(rawValue:)) { profile.currentStep = step }
        try? JSONEncoder().encode(profile).write(to: files.profile)
        return files
    }
}
#endif
