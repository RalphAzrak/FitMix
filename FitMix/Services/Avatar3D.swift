import Foundation

/// Where one 3D avatar build stands on the FitMix backend.
nonisolated struct Avatar3DBuildState: Decodable, Sendable, Equatable {
    enum Status: String, Decodable, Sendable { case queued, running, done, failed }
    struct Failure: Decodable, Sendable, Equatable { var code: String; var message: String }

    var job: String
    var status: Status
    /// The step the builder is on: cutout, shape, face or package.
    var stage: String?
    /// How far the whole build is, 0 to 100. Counted from the builder's real steps, not from a clock.
    var progress: Int?
    /// How many other builds are ahead of this one.
    var position: Int
    /// False when the head couldn't be placed precisely on the model, so the face has only the lower detail of the
    /// whole-figure texture.
    var faceSharpened: Bool?
    var error: Failure?

    enum CodingKeys: String, CodingKey {
        case job, status, stage, progress, position, error
        case faceSharpened = "face_sharpened"
    }
}

/// Builds a 3D model from the accepted portrait. A build takes minutes, so it is started, followed and then
/// collected in separate calls.
nonisolated protocol Avatar3DBuilding: Sendable {
    func start(portrait: Data) async throws -> Avatar3DBuildState
    func state(of job: String) async throws -> Avatar3DBuildState
    /// The finished model as USDZ data.
    func model(of job: String) async throws -> Data
    /// Stops a build that is no longer wanted. Failing to reach the server is not an error here.
    func cancel(_ job: String) async
}

/// Talks to the FitMix backend, which builds the model on its own computer and sends nothing to anyone else.
nonisolated struct BackendAvatar3DBuilder: Avatar3DBuilding {
    var config: BackendConfig?
    var session: URLSession = BackendAvatar3DBuilder.makeSession()

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral   // nothing about the request is cached on disk
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    func start(portrait: Data) async throws -> Avatar3DBuildState {
        var form = MultipartForm()
        form.add(file: portrait, name: "portrait", fileName: "avatar.png", type: "image/png")
        var request = try request("v1/avatar-3d", method: "POST")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        return try decode(await send(request, body: form.finished(), expecting: 202))
    }

    func state(of job: String) async throws -> Avatar3DBuildState {
        try decode(await send(request("v1/avatar-3d/\(job)"), expecting: 200))
    }

    func model(of job: String) async throws -> Data {
        let data = try await send(request("v1/avatar-3d/\(job)/model"), expecting: 200)
        // A USDZ is a zip archive. Only hand back something that really is one.
        guard data.count > 1024, data.prefix(2) == Data("PK".utf8) else { throw AvatarGenerationError.invalidResponse }
        return data
    }

    func cancel(_ job: String) async {
        guard let request = try? request("v1/avatar-3d/\(job)", method: "DELETE") else { return }
        _ = try? await session.data(for: request)
    }

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        guard let config else { throw AvatarGenerationError.notConfigured }
        var request = URLRequest(url: config.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let token = config.token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func send(_ request: URLRequest, body: Data? = nil, expecting status: Int) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = if let body { try await session.upload(for: request, from: body) } else { try await session.data(for: request) }
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
        guard http.statusCode == status else {
            struct Failure: Decodable { struct Detail: Decodable { var message: String }; var error: Detail }
            if let failure = try? JSONDecoder().decode(Failure.self, from: data) { throw AvatarGenerationError.service(failure.error.message) }
            throw AvatarGenerationError.invalidResponse
        }
        return data
    }

    private func decode(_ data: Data) throws -> Avatar3DBuildState {
        guard let state = try? JSONDecoder().decode(Avatar3DBuildState.self, from: data) else { throw AvatarGenerationError.invalidResponse }
        return state
    }
}
