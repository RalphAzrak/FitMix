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
    /// The 3D model built from the accepted portrait, under the name used before each build had its own.
    var model3D: URL { directory.appendingPathComponent("avatar3d.usdz") }
    func model3D(_ record: Avatar3DRecord) -> URL { record.file.map { directory.appendingPathComponent($0) } ?? model3D }

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

/// Where a 3D build stands. Not saved, apart from the backend's job id (see `AvatarProfile.model3DJob`).
enum Build3DPhase: Equatable {
    case idle
    /// `stage` is the builder's current step, `ahead` is how many other builds are in front of this one, and
    /// `percent` is how far the whole build is (0 to 100).
    case building(stage: String?, ahead: Int, percent: Int)
    case failed(String)

    var isBuilding: Bool { if case .building = self { true } else { false } }
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
    private(set) var build3D: Build3DPhase = .idle
    /// Set when saving to disk fails, so the UI can say so.
    var storageErrorMessage: String?

    let files: AvatarFiles
    /// False when this build has no avatar service to call.
    let generationAvailable: Bool
    @ObservationIgnored private let generator: any AvatarGenerating
    @ObservationIgnored private let builder3D: any Avatar3DBuilding
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var build3DTask: Task<Void, Never>?
    @ObservationIgnored private var photoSaveTask: Task<Void, Never>?

    init(files: AvatarFiles = .standard, backend: BackendConfig? = .current) {
        var files = files
        #if DEBUG
        if let seeded = DebugSeed.prepare() { files = seeded }
        #endif
        self.files = files
        generationAvailable = backend != nil
        generator = BackendAvatarGenerator(config: backend)
        builder3D = BackendAvatar3DBuilder(config: backend)

        let manager = FileManager.default
        if let data = try? Data(contentsOf: files.profile), let saved = try? JSONDecoder().decode(AvatarProfile.self, from: data) {
            profile = saved
        }
        // The files are the truth: a record without its picture is dropped, and so is a step that needs one.
        profile.hasBodyPhoto = manager.fileExists(atPath: files.bodyPhoto.path)
        profile.hasSelfie = manager.fileExists(atPath: files.selfie.path)
        if !manager.fileExists(atPath: files.avatar.path) { profile.avatar = nil }
        if !manager.fileExists(atPath: files.candidate.path) { profile.candidate = nil }
        if let model = profile.model3D, profile.avatar == nil || !manager.fileExists(atPath: files.model3D(model).path) {
            profile.model3D = nil
        }
        if profile.avatar == nil { profile.model3DJob = nil }

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
        // A 3D build that was still running when FitMix was last closed carries on from where it is.
        if let job = profile.model3DJob { resume3DBuild(job) }
    }

    var homeState: HomeState {
        switch generation {
        case .generating: return .generating
        case .failed(let message): return .error(message)
        case .idle: break
        }
        if profile.hasCurrentCandidate { return .reviewPending }
        if profile.avatar != nil { return .ready }
        return profile.setupStarted ? .setupInProgress : .empty
    }

    /// Where the creation flow should open so the user carries on from where they were.
    var resumeStep: SetupStep {
        if profile.hasCurrentCandidate { return .review }
        if !profile.hasBodyPhoto { return .bodyPhoto }
        switch profile.currentStep {
        case .review, .generate: return profile.readyToGenerate ? .generate : .measurements
        default: return profile.currentStep
        }
    }

    // MARK: Photos and measurements

    /// A picked photo made upright and checked on-device, ready to show the user before it is saved.
    struct CheckedBodyPhoto: Identifiable {
        let id = UUID()
        var image: UIImage
        /// `nil` means the check could not run.
        var analysis: BodyPhotoAnalysis?
    }

    struct CheckedSelfie: Identifiable {
        let id = UUID()
        var image: UIImage
        /// `nil` means the check could not run.
        var hasFace: Bool?
    }

    /// Prepares a photo straight from the camera or library and checks that a whole person is in it.
    /// Nothing is saved until `saveBodyPhoto`.
    func checkBodyPhoto(_ picked: UIImage) async -> CheckedBodyPhoto {
        let image = await picked.normalizedInBackground()
        let analysis: BodyPhotoAnalysis? = if let cg = image.cgImage { await BodyPhotoAnalyzer.analyze(image: cg) } else { nil }
        return CheckedBodyPhoto(image: image, analysis: analysis)
    }

    /// Prepares a selfie and checks that it shows a face. Nothing is saved until `saveSelfie`.
    func checkSelfie(_ picked: UIImage) async -> CheckedSelfie {
        let image = await picked.normalizedInBackground(maxDimension: 1600)
        let hasFace: Bool? = if let cg = image.cgImage { await SelfieCheck.hasFace(cg) } else { nil }
        return CheckedSelfie(image: image, hasFace: hasFace)
    }

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
        bodyThumbnail = nil
        profile.hasBodyPhoto = false
        profile.photoAnalysis = nil
        persist()
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
        let regenerate = profile.avatar != nil || profile.candidate != nil
        generationTask = Task { [weak self] in
            do {
                // A photo chosen a moment ago may still be on its way to disk.
                await self?.photoSaveTask?.value
                var request = try await AvatarStore.makeRequest(files: files, includeSelfie: includeSelfie, heightCm: heightCm, weightKg: weightKg)
                request.regenerate = regenerate
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
        guard profile.hasCurrentCandidate, let record = profile.candidate, let portrait = candidateImage else { return false }
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
        remove3DModel()   // it shows the previous avatar
        persist()
        return true
    }

    // MARK: 3D avatar

    /// The 3D model of the current avatar, once one has been built.
    var model3DURL: URL? { profile.model3D.map(files.model3D) }

    /// Sends the accepted portrait to the FitMix backend, which builds a 3D model from it, and saves the model
    /// when it is ready. Call only after the user has agreed to the upload.
    func build3DAvatar() {
        guard !build3D.isBuilding, profile.avatar != nil else { return }
        build3D = .building(stage: nil, ahead: 0, percent: 0)
        let files = files, builder = builder3D
        build3DTask = Task { [weak self] in
            do {
                let portrait = try await AvatarStore.read(files.avatar)
                let started = try await builder.start(portrait: portrait)
                guard let self else { return }
                profile.model3DJob = started.job
                persist()
                try await follow3DBuild(started)
            } catch is CancellationError {
                // The user cancelled; nothing was changed.
            } catch {
                self?.fail3DBuild(error.localizedDescription)
            }
        }
    }

    func cancel3DBuild() {
        build3DTask?.cancel()
        build3DTask = nil
        if let job = profile.model3DJob {
            let builder = builder3D
            Task { await builder.cancel(job) }
        }
        profile.model3DJob = nil
        persist()
        build3D = .idle
    }

    private func resume3DBuild(_ job: String) {
        build3D = .building(stage: nil, ahead: 0, percent: 0)
        let builder = builder3D
        build3DTask = Task { [weak self] in
            do {
                let state = try await builder.state(of: job)
                try await self?.follow3DBuild(state)
            } catch is CancellationError {
            } catch {
                self?.fail3DBuild(error.localizedDescription)
            }
        }
    }

    /// Checks on the build every few seconds until it ends, then collects and saves the model.
    private func follow3DBuild(_ first: Avatar3DBuildState) async throws {
        let portraitDate = profile.avatar?.createdAt
        var state = first
        var missed = 0
        while true {
            switch state.status {
            case .queued, .running:
                build3D = .building(stage: state.stage, ahead: state.position, percent: state.progress ?? 0)
            case .failed:
                fail3DBuild(state.error?.message ?? "The 3D avatar couldn't be built. Try again.")
                return
            case .done:
                let data = try await builder3D.model(of: state.job)
                // The model belongs to the portrait it was built from. If that was replaced meanwhile, drop it.
                guard profile.avatar?.createdAt == portraitDate else { cancel3DBuild(); return }
                try prepareDirectory()
                let previous = profile.model3D.map(files.model3D)
                let record = Avatar3DRecord(createdAt: .now, faceSharpened: state.faceSharpened ?? false,
                                            file: "avatar3d-\(Int(Date.now.timeIntervalSince1970)).usdz")
                guard await AvatarStore.save(data, to: files.model3D(record)) else { throw AvatarError.saveFailed }
                profile.model3D = record
                profile.model3DJob = nil
                guard persist() else { throw AvatarError.saveFailed }
                // The model it replaces goes only now that the new one is safely saved.
                if let previous, previous != files.model3D(record) { try? FileManager.default.removeItem(at: previous) }
                build3D = .idle
                let builder = builder3D, job = state.job
                Task { await builder.cancel(job) }   // the server can forget it now
                return
            }
            try await Task.sleep(for: .seconds(3))
            do {
                state = try await builder3D.state(of: state.job)
                missed = 0
            } catch let error as AvatarGenerationError where error == .unreachable || error == .timedOut || error == .offline {
                // A dropped connection (or the app coming back from the background) is not the end of the build.
                missed += 1
                if missed > 20 { throw error }
            }
        }
    }

    private func fail3DBuild(_ message: String) {
        profile.model3DJob = nil
        persist()
        build3D = .failed(message)
    }

    /// Removes the 3D model. Used when the avatar it was built from is replaced.
    private func remove3DModel() {
        if build3D.isBuilding || profile.model3DJob != nil { cancel3DBuild() }
        if let model = profile.model3D { try? FileManager.default.removeItem(at: files.model3D(model)) }
        profile.model3D = nil
        build3D = .idle
    }

    /// Removes the avatar, the photos and the measurements from this iPhone.
    func deleteEverything() {
        generationTask?.cancel()
        generationTask = nil
        photoSaveTask?.cancel()
        photoSaveTask = nil
        if build3D.isBuilding || profile.model3DJob != nil { cancel3DBuild() }
        build3D = .idle
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
    private nonisolated static func read(_ url: URL) async throws -> Data {
        try Data(contentsOf: url)
    }

    @concurrent
    private nonisolated static func save(_ data: Data, to url: URL) async -> Bool {
        (try? data.write(to: url, options: [.atomic, .completeFileProtection])) != nil
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
///   FM_DEBUG_SEED_MODEL   path to a USDZ used as the saved 3D model of that avatar
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
        var profile = AvatarProfile()
        profile.hasBodyPhoto = hasPhoto
        profile.hasSelfie = hasSelfie
        if body.count > 1 { profile.heightCm = body[0]; profile.weightKg = body[1] }
        if hasAvatar {
            // FM_DEBUG_SEED_AVATAR_OLD: the avatar was made before the weight was last edited.
            let weight = (profile.weightKg ?? 74) - (env["FM_DEBUG_SEED_AVATAR_OLD"] != nil ? 6 : 0)
            profile.avatar = AvatarRecord(createdAt: .now, usedSelfie: hasSelfie, heightCm: profile.heightCm ?? 178, weightKg: weight)
            if let model = env["FM_DEBUG_SEED_MODEL"], (try? manager.copyItem(atPath: model, toPath: files.model3D.path)) != nil {
                profile.model3D = Avatar3DRecord(createdAt: .now, faceSharpened: true)
            }
        }
        if let step = env["FM_DEBUG_STEP"].flatMap(SetupStep.init(rawValue:)) { profile.currentStep = step }
        try? JSONEncoder().encode(profile).write(to: files.profile)
        return files
    }
}
#endif
