import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import Vision

// MARK: - Retailer match for one selected garment
//
// The iPhone sends the FitMix backend only the selected garment's crop, its category, and a few
// attributes read on-device (dominant colour, visible brand text). The backend holds the retailer
// provider's credentials (eBay Browse API today) and returns real listings. The full outfit frame
// never leaves the iPhone. See Docs/LiveGarmentMatch.md and Backend/README.md.

/// Exactly what leaves the phone for one search.
nonisolated struct GarmentSearchRequest: Sendable {
    var category: GarmentCategory
    /// JPEG of the garment crop only, long edge ≤ 640 px.
    var crop: Data
    /// e.g. "navy". Nil when the colour isn't clear.
    var colorName: String?
    /// Words read on the garment (e.g. a logo), at most three.
    var brandHints: [String]
}

/// One retailer listing, exactly as the provider returned it.
nonisolated struct RetailerListing: Sendable, Equatable {
    var id: String
    var title: String
    /// Marketplace or store, e.g. "eBay".
    var retailer: String
    var seller: String?
    var imageURL: URL?
    var listingURL: URL?
    var price: Decimal?
    var currency: String?
    /// True only with evidence the listing is the very same product. FitMix has none yet.
    var exact: Bool
    /// Development data, not a real listing.
    var isFixture: Bool
}

nonisolated enum RetailerSearchOutcome: Sendable, Equatable {
    case matches([RetailerListing])
    /// The provider answered, but nothing credible in this category.
    case noMatch
}

nonisolated enum RetailerSearchError: LocalizedError, Equatable {
    /// No backend in this build, or the backend has no provider credentials.
    case notConfigured(String)
    case offline
    case unreachable
    case timedOut
    /// The provider failed in a way that may pass (busy, rate limited, outage).
    case providerBusy(String)
    /// The provider refused (bad credentials, account not approved). Retrying won't help.
    case providerRejected(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured(let message): message
        case .offline: "You're offline. Connect to the internet and try again."
        case .unreachable: "FitMix couldn't reach its product search. Check your connection and try again."
        case .timedOut: "The product search took too long. Try again."
        case .providerBusy(let message), .providerRejected(let message): message
        case .invalidResponse: "The product search sent back something FitMix couldn't read. Try again."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .offline, .unreachable, .timedOut, .providerBusy, .invalidResponse: true
        case .notConfigured, .providerRejected: false
        }
    }
}

nonisolated protocol RetailerSearching: Sendable {
    func search(_ request: GarmentSearchRequest) async throws -> RetailerSearchOutcome
}

enum RetailerSearchers {
    /// The search Studio uses. Debug builds can swap in clearly labeled fixtures with
    /// FM_DEBUG_MATCH_FIXTURE=match|nomatch|error|slow.
    static var current: RetailerSearching {
        #if DEBUG
        if let mode = ProcessInfo.processInfo.environment["FM_DEBUG_MATCH_FIXTURE"], let fixture = FixtureRetailerSearch(mode: mode) {
            return fixture
        }
        #endif
        return BackendRetailerSearch(config: .current)
    }
}

// MARK: - Backend

/// `POST /v1/garment-match` on the FitMix backend.
nonisolated struct BackendRetailerSearch: RetailerSearching {
    var config: BackendConfig?
    var session: URLSession = BackendRetailerSearch.makeSession()

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral  // nothing cached on disk
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 35
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    private struct Response: Decodable {
        struct Listing: Decodable {
            struct Amount: Decodable { var value: String; var currency: String }
            var id: String
            var title: String
            var retailer: String
            var seller: String?
            var image_url: String?
            var url: String?
            var price: Amount?
            var match: String
        }
        var status: String
        var fixture: Bool?
        var results: [Listing]
    }

    private struct Failure: Decodable {
        struct Detail: Decodable { var code: String; var message: String }
        var error: Detail
    }

    func search(_ request: GarmentSearchRequest) async throws -> RetailerSearchOutcome {
        guard let config else {
            throw RetailerSearchError.notConfigured("Retailer search isn't set up in this build. Start the FitMix backend (Backend/run.sh) and rebuild.")
        }
        var form = MultipartForm()
        form.add(file: request.crop, name: "crop", fileName: "garment.jpg", type: "image/jpeg")
        form.add(value: request.category.rawValue, name: "category")
        if let color = request.colorName { form.add(value: color, name: "color") }
        if !request.brandHints.isEmpty { form.add(value: request.brandHints.joined(separator: ","), name: "brand_hints") }

        var urlRequest = URLRequest(url: config.baseURL.appendingPathComponent("v1/garment-match"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        if let token = config.token, !token.isEmpty { urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.upload(for: urlRequest, from: form.finished())
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .notConnectedToInternet, .dataNotAllowed: throw RetailerSearchError.offline
            case .timedOut: throw RetailerSearchError.timedOut
            default: throw RetailerSearchError.unreachable
            }
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw RetailerSearchError.invalidResponse }
        guard http.statusCode == 200 else {
            guard let failure = try? JSONDecoder().decode(Failure.self, from: data) else {
                throw http.statusCode == 404 ? RetailerSearchError.notConfigured("The FitMix backend on this network doesn't have retailer search yet. Update and restart it.")
                    : RetailerSearchError.invalidResponse
            }
            switch failure.error.code {
            case "not_configured": throw RetailerSearchError.notConfigured(failure.error.message)
            case "provider_auth", "unauthorized": throw RetailerSearchError.providerRejected(failure.error.message)
            default: throw RetailerSearchError.providerBusy(failure.error.message)
            }
        }
        guard let body = try? JSONDecoder().decode(Response.self, from: data) else { throw RetailerSearchError.invalidResponse }
        let listings = body.results.map { item in
            RetailerListing(id: item.id, title: item.title, retailer: item.retailer, seller: item.seller,
                            imageURL: item.image_url.flatMap(URL.init(string:)),
                            listingURL: item.url.flatMap(URL.init(string:)),
                            price: item.price.flatMap { Decimal(string: $0.value, locale: Locale(identifier: "en_US_POSIX")) },
                            currency: item.price?.currency,
                            exact: item.match == "exact",
                            isFixture: body.fixture ?? false)
        }
        return listings.isEmpty || body.status == "no_match" ? .noMatch : .matches(listings)
    }
}

// MARK: - On-device attributes

nonisolated enum GarmentSearchInput {
    /// Builds the request from the crop: downscales it to JPEG and reads any text on it. The
    /// colour is the one measured on the garment at detection; without it, the crop's own colour
    /// is used only if one colour clearly dominates (background often fills a garment's box).
    @concurrent
    static func make(category: GarmentCategory, crop: CGImage, measuredColor: SIMD3<Float>?) async -> GarmentSearchRequest? {
        guard let jpeg = jpegData(crop, maxDimension: 640) else { return nil }
        let color = measuredColor.flatMap(colorName(of:)) ?? dominantColorName(of: crop)
        return GarmentSearchRequest(category: category, crop: jpeg, colorName: color, brandHints: brandHints(in: crop))
    }

    static func jpegData(_ image: CGImage, maxDimension: Int) -> Data? {
        let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        // No metadata is written: no location, no device details.
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The crop's central colour, only when most of the centre is that one colour.
    static func dominantColorName(of image: CGImage) -> String? {
        guard let grid = ColorGrid(image, maxWidth: 48) else { return nil }
        let centre = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        guard let mean = grid.mean(in: centre, mask: nil) else { return nil }
        var near = 0, total = 0
        for y in stride(from: centre.minY, to: centre.maxY, by: 1 / Double(grid.height)) {
            for x in stride(from: centre.minX, to: centre.maxX, by: 1 / Double(grid.width)) {
                let cell = CGRect(x: x, y: y, width: 0.5 / Double(grid.width), height: 0.5 / Double(grid.height))
                guard let c = grid.mean(in: cell, mask: nil) else { continue }
                total += 1
                if deltaE(c, mean) < 15 { near += 1 }
            }
        }
        guard total > 0, Double(near) / Double(total) >= 0.6 else { return nil }
        return colorName(of: mean)
    }

    /// The nearest name from a small fixed palette, or nil if none is close.
    static func colorName(of mean: SIMD3<Float>) -> String? {
        let palette: [(String, SIMD3<Float>)] = [
            ("black", [0.08, 0.08, 0.08]), ("white", [0.95, 0.95, 0.95]), ("gray", [0.55, 0.55, 0.55]),
            ("navy", [0.10, 0.14, 0.32]), ("blue", [0.20, 0.40, 0.80]), ("light blue", [0.60, 0.75, 0.90]),
            ("red", [0.80, 0.12, 0.12]), ("burgundy", [0.45, 0.08, 0.15]), ("pink", [0.95, 0.65, 0.75]),
            ("orange", [0.95, 0.50, 0.10]), ("yellow", [0.95, 0.85, 0.20]), ("beige", [0.85, 0.78, 0.65]),
            ("brown", [0.45, 0.30, 0.18]), ("olive", [0.40, 0.42, 0.20]), ("green", [0.15, 0.55, 0.25]),
            ("purple", [0.45, 0.25, 0.60]),
        ]
        guard let best = palette.min(by: { deltaE(mean, $0.1) < deltaE(mean, $1.1) }), deltaE(mean, best.1) < 25 else { return nil }
        return best.0
    }

    /// Up to three confident words printed on the garment, like a logo. Read on-device.
    static func brandHints(in image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])) != nil else { return [] }
        var words: [String] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.5 else { continue }
            for word in candidate.string.split(whereSeparator: { !$0.isLetter }) where word.count >= 3 {
                let token = String(word).lowercased()
                if !words.contains(token) { words.append(token) }
            }
        }
        return Array(words.prefix(3))
    }
}

// MARK: - Debug fixtures

#if DEBUG
/// Development-only stand-in for the backend. Every listing is marked as a fixture and Studio
/// labels it "Test fixture"; none of its names, prices or links are real.
nonisolated struct FixtureRetailerSearch: RetailerSearching {
    enum Mode: String { case match, nomatch, error, slow }
    let mode: Mode

    init?(mode: String) {
        guard let mode = Mode(rawValue: mode) else { return nil }
        self.mode = mode
    }

    func search(_ request: GarmentSearchRequest) async throws -> RetailerSearchOutcome {
        try await Task.sleep(for: mode == .slow ? .seconds(6) : .seconds(1.2))
        switch mode {
        case .nomatch: return .noMatch
        case .error: throw RetailerSearchError.providerBusy("Test fixture: the product search is temporarily unavailable.")
        case .match, .slow:
            let name = request.category.title
            return .matches([
                RetailerListing(id: "fixture-\(request.category.rawValue)", title: "Test fixture \(name.lowercased()) (not a real listing)",
                                retailer: "FitMix test fixture", seller: nil, imageURL: nil, listingURL: nil,
                                price: request.category == .shoes ? nil : 42, currency: request.category == .shoes ? nil : "USD",
                                exact: false, isFixture: true),
            ])
        }
    }
}
#endif
