import Foundation
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
        guard let config else { throw AvatarGenerationError.notConfigured }
        var form = MultipartForm()
        form.add(file: request.bodyPhoto, name: "body_photo", fileName: "body.jpg", type: "image/jpeg")
        if let selfie = request.selfie { form.add(file: selfie, name: "selfie", fileName: "selfie.jpg", type: "image/jpeg") }
        form.add(value: String(format: "%.1f", request.heightCm), name: "height_cm")
        form.add(value: String(format: "%.1f", request.weightKg), name: "weight_kg")

        var urlRequest = URLRequest(url: config.baseURL.appendingPathComponent("v1/avatar"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        if let token = config.token, !token.isEmpty { urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.upload(for: urlRequest, from: form.finished())
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
        // Only hand back something that really is a picture.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw AvatarGenerationError.invalidResponse }
        return data
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
