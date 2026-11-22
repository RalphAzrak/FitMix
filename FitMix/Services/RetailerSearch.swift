import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

// MARK: - Retailer matching for one garment

/// Exactly what leaves the phone for one search.
nonisolated struct GarmentSearchRequest: Sendable {
    var category: GarmentCategory
    /// JPEG of the garment crop only, long edge ≤ 640 px.
    var crop: Data
    /// Text read on-device for structured product-code verification.
    var detectedText: [String]
    var brand: String = ""
}

/// How sure FitMix is that a listing is the garment the user tapped.
nonisolated enum MatchTier: String, Sendable, Equatable, Comparable {
    /// Corroborated: a product code, the same image, or brand + model + colour.
    case exact
    /// Only the brand is supported.
    case brand
    /// The closest real alternative.
    case similar

    private var order: Int { self == .exact ? 0 : self == .brand ? 1 : 2 }
    static func < (a: MatchTier, b: MatchTier) -> Bool { a.order < b.order }
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
    var tier: MatchTier
    /// The brand the evidence supports, for "Likely from <brand>".
    var brand: String?
    /// Why the listing got its label, in words ("brand Converse read on the garment matches").
    var evidence: [String] = []
    /// Which search found it (e.g. "google_lens", "ebay").
    var provider: String = ""
    /// Development data, not a real listing.
    var isFixture: Bool
    var visualScore: Int? = nil
    var bestMatch = false
    /// The product photo the backend compared with the garment, as JPEG. Shown without asking the store again.
    var thumbnail: Data? = nil
}

nonisolated enum RetailerSearchOutcome: Sendable, Equatable {
    case matches([RetailerListing])
    /// The provider answered, but nothing credible in this category.
    case noMatch
    case outfit(searchID: String, listings: [RetailerListing], description: String? = nil, garmentLabel: String? = nil)
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
    func cheaperListings(category: GarmentCategory, searchID: String, cap: Decimal) async throws -> [RetailerListing]
}

extension RetailerSearching {
    nonisolated func cheaperListings(category: GarmentCategory, searchID: String, cap: Decimal) async throws -> [RetailerListing] { [] }
}

enum RetailerSearchers {
    /// The search Studio uses: OpenAI web search through the FitMix backend, in Debug and Release.
    /// Debug builds can opt in to clearly labeled fixtures instead with FM_DEBUG_MATCH_FIXTURE=match|nomatch|error|slow.
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

/// `POST /v1/outfit-match` on the FitMix backend.
nonisolated struct BackendRetailerSearch: RetailerSearching {
    /// Matches the backend cutoff, including when connected to an older FitMix server.
    private static let minimumVisualScore = 65
    var config: BackendConfig?
    var session: URLSession = BackendRetailerSearch.makeSession()

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral  // nothing cached on disk
        configuration.timeoutIntervalForRequest = 65
        configuration.timeoutIntervalForResource = 70
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
            var brand: String?
            var evidence: [String]?
            var provider: String?
            var fixture: Bool?
            var visual_score: Int?
            var best_match: Bool?
            var variant_color: String?
            var thumbnail: String?
        }
        var status: String
        var fixture: Bool?
        var search_id: String
        var currency: String
        var results: [Listing]
        var description: String?
        var garment_label: String?
    }

    private struct Failure: Decodable {
        struct Detail: Decodable { var code: String; var message: String }
        var error: Detail
    }

    func search(_ request: GarmentSearchRequest) async throws -> RetailerSearchOutcome {
        var form = MultipartForm()
        form.add(file: request.crop, name: "crop", fileName: "garment.jpg", type: "image/jpeg")
        form.add(value: request.category.rawValue, name: "category")
        if !request.detectedText.isEmpty { form.add(value: request.detectedText.joined(separator: ","), name: "text") }
        if !request.brand.isEmpty { form.add(value: request.brand, name: "brand") }
        let response = try await submit(form)
        return .outfit(searchID: response.search_id, listings: Self.listings(response), description: response.description,
                       garmentLabel: response.garment_label)
    }

    func cheaperListings(category: GarmentCategory, searchID: String, cap: Decimal) async throws -> [RetailerListing] {
        var form = MultipartForm()
        form.add(value: category.rawValue, name: "category")
        form.add(value: searchID, name: "search_id")
        form.add(value: NSDecimalNumber(decimal: cap).stringValue, name: "max_price")
        return Self.listings(try await submit(form))
    }

    private func submit(_ form: MultipartForm) async throws -> Response {
        guard let config else {
            throw RetailerSearchError.notConfigured("Start the FitMix backend and rebuild to enable outfit matching.")
        }
        var urlRequest = URLRequest(url: config.baseURL.appendingPathComponent("v1/outfit-match"))
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
        guard let body = try? JSONDecoder().decode(Response.self, from: data),
              body.currency == "CAD", ["matched", "no_match"].contains(body.status) else {
            throw RetailerSearchError.invalidResponse
        }
        return body
    }

    private static func listings(_ body: Response) -> [RetailerListing] {
        guard body.status == "matched" else { return [] }
        return body.results.compactMap { item in
            guard !item.id.isEmpty, !item.title.isEmpty, !item.retailer.isEmpty,
                  let score = item.visual_score, (minimumVisualScore...100).contains(score),
                  // Every result is shown with its product photo: one without a photo is not a result.
                  let image = item.image_url.flatMap(URL.init(string:)), image.scheme == "https", image.host() != nil,
                  let link = item.url.flatMap(URL.init(string:)), link.scheme == "https", link.host() != nil else { return nil }
            // A page found on the web may not state a price. One that does must state a usable one.
            var amount: Decimal?
            if let cost = item.price {
                guard cost.currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil,
                      let value = Decimal(string: cost.value, locale: Locale(identifier: "en_US_POSIX")), value > 0 else { return nil }
                amount = value
            }
            let color = item.variant_color?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = if let color, !color.isEmpty, !item.title.localizedCaseInsensitiveContains(color) {
                "\(item.title) · \(color)"
            } else {
                item.title
            }
            return RetailerListing(id: item.id, title: title, retailer: item.retailer, seller: item.seller,
                                   imageURL: image, listingURL: link, price: amount, currency: item.price?.currency,
                                   tier: MatchTier(rawValue: item.match) ?? .similar,
                                   brand: item.brand, evidence: item.evidence ?? [], provider: item.provider ?? "",
                                   isFixture: item.fixture ?? body.fixture ?? false, visualScore: score,
                                   bestMatch: item.best_match ?? false,
                                   thumbnail: item.thumbnail.flatMap { Data(base64Encoded: $0) })
        }
    }
}

// MARK: - Request from the tapped crop

nonisolated enum GarmentSearchInput {
    /// Downscales the crop to JPEG (no metadata) and reads its clues, on-device.
    @concurrent
    static func make(category: GarmentCategory, crop: CGImage, brand: String = "") async -> GarmentSearchRequest? {
        guard let jpeg = jpegData(crop, maxDimension: 640) else { return nil }
        return GarmentSearchRequest(category: category, crop: jpeg,
                                    detectedText: GarmentClues.words(in: crop), brand: brand)
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
}

/// Product photos that arrived with the search results, by the address the store serves them from. A card
/// shows the photo from here first, so a store that is slow or refuses the phone can't leave a card blank.
@MainActor
enum ListingThumbnails {
    private static var images: [URL: UIImage] = [:]

    static func image(for url: URL) -> UIImage? { images[url] }

    static func store(_ data: Data?, for url: URL?) {
        guard let data, let url, let image = UIImage(data: data) else { return }
        if images.count >= 120 { images.removeAll() }  // A few searches' worth. Older ones reload from the store.
        images[url] = image
    }
}

/// Downloads the selected product photo for the existing try-on handoff.
nonisolated enum ListingPhoto {
    static func download(_ url: URL, session: URLSession) async -> CGImage? {
        guard url.scheme == "https" || url.scheme == "http" else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request), data.count < 4_000_000,
              (response as? HTTPURLResponse)?.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                               kCGImageSourceThumbnailMaxPixelSize: 600,
                                                               kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    }
}

// MARK: - Debug fixtures

#if DEBUG
/// Development-only stand-in for the backend. Every listing is marked as a fixture and Studio labels it
/// "Test fixture"; none of its names, prices or links are real.
nonisolated struct FixtureRetailerSearch: RetailerSearching {
    enum Mode: String { case match, branded, nomatch, error, slow, budget }
    let mode: Mode

    init?(mode: String) {
        guard let mode = Mode(rawValue: mode) else { return nil }
        self.mode = mode
    }

    func search(_ request: GarmentSearchRequest) async throws -> RetailerSearchOutcome {
        if mode == .budget {
            let delay: Duration = switch request.category {
            case .jacket: .milliseconds(200)
            case .tshirt: .milliseconds(500)
            case .pants: .seconds(1)
            default: .seconds(2.5)
            }
            try await Task.sleep(for: delay)
            return .outfit(searchID: request.category.rawValue, listings: [budgetListing(request.category, cheaper: false)])
        }
        try await Task.sleep(for: mode == .slow ? .seconds(6) : .seconds(1.2))
        let name = request.category.title.lowercased()
        func listing(_ id: String, _ title: String, _ tier: MatchTier, brand: String? = nil, price: Decimal? = 42,
                     evidence: [String] = []) -> RetailerListing {
            RetailerListing(id: "fixture-\(request.category.rawValue)-\(id)", title: "Test fixture \(title) (not a real listing)",
                            retailer: "FitMix test fixture", seller: nil, imageURL: nil, listingURL: nil,
                            price: price, currency: price == nil ? nil : "USD", tier: tier, brand: brand,
                            evidence: evidence, provider: "fixture", isFixture: true)
        }
        switch mode {
        case .nomatch: return .noMatch
        case .error: throw RetailerSearchError.providerBusy("Test fixture: the product search is temporarily unavailable.")
        case .branded:
            return .matches([
                listing("1", "Example Brand \(name), exact model", .exact, brand: "Example Brand",
                        evidence: ["test fixture: product code matches"]),
                listing("2", "Example Brand \(name), other model", .brand, brand: "Example Brand", price: nil,
                        evidence: ["test fixture: brand matches"]),
                listing("3", "similar \(name)", .similar),
            ])
        case .match, .slow, .budget:
            return .matches([listing("1", name, .similar, price: request.category == .shoes ? nil : 42), listing("2", "\(name) B", .similar)])
        }
    }

    func cheaperListings(category: GarmentCategory, searchID: String, cap: Decimal) async throws -> [RetailerListing] {
        guard mode == .budget else { return [] }
        try await Task.sleep(for: .milliseconds(300))
        let listing = budgetListing(category, cheaper: true)
        return (listing.price ?? 0) <= cap ? [listing] : []
    }

    private func budgetListing(_ category: GarmentCategory, cheaper: Bool) -> RetailerListing {
        let prices: (Int, Int) = switch category {
        case .jacket: (70, 40)
        case .tshirt: (45, 20)
        case .pants: (55, 35)
        default: (60, 45)
        }
        return RetailerListing(id: "fixture-\(category.rawValue)-\(cheaper ? "budget" : "close")",
                               title: "Test fixture \(category.title) \(cheaper ? "budget option" : "closest option")",
                               retailer: "FitMix test fixture", seller: nil, imageURL: nil, listingURL: nil,
                               price: Decimal(cheaper ? prices.1 : prices.0), currency: "CAD", tier: .similar,
                               brand: nil, isFixture: true, visualScore: cheaper ? 75 : 92)
    }
}
#endif
