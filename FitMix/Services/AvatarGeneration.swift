import CryptoKit
import Foundation
import OSLog
import ImageIO

/// Where the FitMix backend is. The backend holds the OpenAI key; the app never does.
nonisolated struct BackendConfig: Sendable, Equatable {
    var baseURL: URL
    /// A shared secret the backend may ask for. It is not the OpenAI key.
    var token: String?

    /// The hosted backend, from Info.plist: `FitMixBackendURL` (and optional `FitMixBackendToken`). Release builds use
    /// only this. Until it's set, only Debug builds made on a Mac running `Backend/run.sh` reach a backend.
    static let production: BackendConfig? = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let text = (info["FitMixBackendURL"] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
              let url = URL(string: text), url.scheme == "https" || url.scheme == "http" else { return nil }
        let token = (info["FitMixBackendToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return BackendConfig(baseURL: url, token: token)
    }()

    /// Debug builds made after `Backend/run.sh` carry `Backend.local.json` (ignored by Git), which points at
    /// the backend on the developer's Mac. Release builds only ever use `production`.
    static let current: BackendConfig? = {
        #if DEBUG
        struct Local: Decodable { var url: URL; var token: String? }
        if let text = ProcessInfo.processInfo.environment["FITMIX_BACKEND_URL"], let url = URL(string: text) {
            return BackendConfig(baseURL: url, token: ProcessInfo.processInfo.environment["FITMIX_BACKEND_TOKEN"])
        }
        if let file = Bundle.main.url(forResource: "Backend.local", withExtension: "json"),
           let data = try? Data(contentsOf: file), let local = try? JSONDecoder().decode(Local.self, from: data) {
            return BackendConfig(baseURL: local.url, token: local.token)
        }
        #endif
        return production
    }()
}

/// Exactly what leaves the phone for one avatar: the pictures as prepared for upload, and the measurements.
nonisolated struct AvatarGenerationRequest: Sendable {
    var bodyPhoto: Data
    var selfie: Data?
    var heightCm: Double
    var weightKg: Double
    var regenerate = false
}

nonisolated enum AvatarGenerationError: LocalizedError, Equatable {
    case notConfigured
    case offline
    case unreachable
    case timedOut
    /// The service answered with a reason written for the user (for example, the photos were declined).
    case service(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Avatar generation isn't set up in this build of FitMix."
        case .offline: "You're offline. Connect to the internet and try again."
        case .unreachable: "FitMix couldn't reach its avatar service. Check your connection and try again."
        case .timedOut: "Creating the avatar took too long. Try again."
        case .service(let message): message
        case .invalidResponse: "The avatar service sent back something FitMix couldn't use. Try again."
        }
    }
}

/// Whether the avatar service can take a request right now. Asking sends nothing about the user.
nonisolated enum AvatarServiceStatus: Equatable, Sendable {
    case ready
    /// The service answered but cannot make avatars (for example, it has no OpenAI key yet).
    case notReady
    case unreachable
}

/// Turns photos and measurements into a portrait. The app talks to this, never to OpenAI directly.
nonisolated protocol AvatarGenerating: Sendable {
    func status() async -> AvatarServiceStatus

    /// Returns the finished portrait as image data. Throws `CancellationError` if the task is cancelled.
    func generate(_ request: AvatarGenerationRequest) async throws -> Data
}

/// Sends the request to the FitMix backend, which calls OpenAI and returns the portrait.
nonisolated struct BackendAvatarGenerator: AvatarGenerating {
    var config: BackendConfig?
    var session: URLSession = BackendAvatarGenerator.makeSession()
    var ownerID: UUID? = nil

    private static let installScope: String = {
        let key = "fitmix.imagePreviewScope"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }()

    private static let catalogResults = CatalogPreviewCache()

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral   // nothing about the request is cached on disk
        configuration.timeoutIntervalForRequest = 300           // the server is silent while the picture is drawn
        configuration.timeoutIntervalForResource = 330
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    func status() async -> AvatarServiceStatus {
        guard let config else { return .notReady }
        struct Health: Decodable { var ready: Bool }
        var request = URLRequest(url: config.baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 8
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let health = try? JSONDecoder().decode(Health.self, from: data) else { return .unreachable }
        return health.ready ? .ready : .notReady
    }

    func generate(_ request: AvatarGenerationRequest) async throws -> Data {
        var form = MultipartForm()
        form.add(file: request.bodyPhoto, name: "body_photo", fileName: "body.jpg", type: "image/jpeg")
        if let selfie = request.selfie { form.add(file: selfie, name: "selfie", fileName: "selfie.jpg", type: "image/jpeg") }
        let requestLocale = Locale(identifier: "en_US_POSIX")
        form.add(value: String(format: "%.1f", locale: requestLocale, request.heightCm), name: "height_cm")
        form.add(value: String(format: "%.1f", locale: requestLocale, request.weightKg), name: "weight_kg")
        if request.regenerate { form.add(value: "true", name: "regenerate") }

        return try await uploadImage(form, endpoint: "v1/avatar").0
    }

    func style(portrait: Data, garments: [(AvatarOutfitSlot, Data)], regenerate: Bool = false) async throws -> Data {
        var form = MultipartForm()
        form.add(file: portrait, name: "portrait", fileName: "portrait.jpg", type: "image/jpeg")
        for (slot, data) in garments {
            form.add(file: data, name: slot.rawValue, fileName: "\(slot.rawValue).jpg", type: "image/jpeg")
        }
        if regenerate { form.add(value: "true", name: "regenerate") }
        let (data, response) = try await uploadImage(form, endpoint: "v1/avatar-outfit")
        guard response.value(forHTTPHeaderField: "X-FitMix-Mock") != "1" else {
            throw AvatarGenerationError.service("This FitMix server is in test mode. A live server is needed to preview your outfit.")
        }
        return data
    }

    func catalogPhoto(_ photo: Data) async throws -> WardrobeCatalogPhoto {
        let key = (config?.baseURL.absoluteString ?? "") + (ownerID?.uuidString ?? "")
            + SHA256.hash(data: photo).description
        if let cached = await Self.catalogResults.photo(for: key) { return cached }
        var form = MultipartForm()
        form.add(file: photo, name: "photo", fileName: "garment.jpg", type: "image/jpeg")
        let (data, response) = try await upload(form, endpoint: "v1/wardrobe-photo", accept: "image/*")
        if response.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("image/") == true {
            let category = response.value(forHTTPHeaderField: "X-FitMix-Wardrobe-Category").flatMap(WardrobeCategory.init(rawValue:))
            let result = WardrobeCatalogPhoto(category: category, image: data, message: nil)
            if CGImageSourceCreateWithData(data as CFData, nil) != nil {
                await Self.catalogResults.remember(result, for: key)
            }
            return result
        }
        guard let result = try? JSONDecoder().decode(WardrobeCatalogPhoto.self, from: data) else {
            throw AvatarGenerationError.invalidResponse
        }
        if let image = result.image, CGImageSourceCreateWithData(image as CFData, nil) != nil {
            await Self.catalogResults.remember(result, for: key)
        }
        return result
    }

    private func uploadImage(_ form: MultipartForm, endpoint: String) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await upload(form, endpoint: endpoint)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { throw AvatarGenerationError.invalidResponse }
        return (data, response)
    }

    private func upload(_ form: MultipartForm, endpoint: String, accept: String? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let config else { throw AvatarGenerationError.notConfigured }
        var urlRequest = URLRequest(url: config.baseURL.appendingPathComponent(endpoint))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(accept, forHTTPHeaderField: "Accept")
        let scope = Self.installScope + (ownerID?.uuidString ?? "")
        let digest = SHA256.hash(data: Data(scope.utf8)).description
        urlRequest.setValue(digest, forHTTPHeaderField: "X-FitMix-Image-Scope")
        if let token = config.token, !token.isEmpty { urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.upload(for: urlRequest, from: form.finished(),
                                                        delegate: ImageRequestMetrics(endpoint: endpoint))
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .notConnectedToInternet, .dataNotAllowed: throw AvatarGenerationError.offline
            case .timedOut: throw AvatarGenerationError.timedOut
            default: throw AvatarGenerationError.unreachable
            }
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AvatarGenerationError.invalidResponse }
        guard http.statusCode == 200 else {
            struct Failure: Decodable { struct Detail: Decodable { var message: String }; var error: Detail }
            if let failure = try? JSONDecoder().decode(Failure.self, from: data) { throw AvatarGenerationError.service(failure.error.message) }
            throw AvatarGenerationError.invalidResponse
        }
        return (data, http)
    }
}

private actor CatalogPreviewCache {
    private var entries: [(key: String, photo: WardrobeCatalogPhoto, expiry: ContinuousClock.Instant)] = []

    func photo(for key: String) -> WardrobeCatalogPhoto? {
        let now = ContinuousClock.now
        entries.removeAll { $0.expiry <= now }
        return entries.first { $0.key == key }?.photo
    }

    func remember(_ photo: WardrobeCatalogPhoto, for key: String) {
        guard let size = photo.image?.count, size <= 2_000_000 else { return }
        entries.removeAll { $0.key == key }
        entries.append((key, photo, .now.advanced(by: .seconds(600))))
        if entries.count > 4 { entries.removeFirst() }
    }
}

private nonisolated final class ImageRequestMetrics: NSObject, URLSessionTaskDelegate {
    private static let log = Logger(subsystem: "app.fitmix", category: "ImagePreviews")
    let endpoint: String

    init(endpoint: String) { self.endpoint = endpoint }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last else { return }
        let upload = Self.ms(from: transaction.requestStartDate, to: transaction.requestEndDate)
        let wait = Self.ms(from: transaction.requestEndDate, to: transaction.responseStartDate)
        let download = Self.ms(from: transaction.responseStartDate, to: transaction.responseEndDate)
        let server = (task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Server-Timing") ?? ""
        Self.log.info("\(self.endpoint, privacy: .public) upload \(upload) ms, server wait \(wait) ms, download \(download) ms \(server, privacy: .public)")
    }

    private static func ms(from start: Date?, to end: Date?) -> Int {
        guard let start, let end else { return 0 }
        return Int(max(0, end.timeIntervalSince(start) * 1000))
    }
}

/// A multipart/form-data body.
nonisolated struct MultipartForm {
    private let boundary = "fitmix-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func add(value: String, name: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func add(file: Data, name: String, fileName: String, type: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n".utf8))
    }

    func finished() -> Data { body + Data("--\(boundary)--\r\n".utf8) }
}
