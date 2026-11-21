import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import Vision

// MARK: - Retailer match for one selected garment
//
// After a tap, the iPhone sends the FitMix backend only the selected garment's crop, its category, and the
// clues read on-device (`GarmentClues`: printed text and codes, colour, pattern, style). The backend asks
// every enabled visual search provider, reads the listing pages, and returns ranked listings labeled
// exact / brand / similar. The phone then compares the top listing photos with the crop on-device
// (`VisualReranker`) to order listings within each label. The full outfit frame, profile photos and avatar
// images never leave the iPhone for search. See Docs/LiveGarmentMatch.md and Backend/README.md.

/// Exactly what leaves the phone for one search.
nonisolated struct GarmentSearchRequest: Sendable {
    var category: GarmentCategory
    /// JPEG of the garment crop only, long edge ≤ 640 px.
    var crop: Data
    /// What the phone read on the crop.
    var clues: GarmentClueSet
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
    /// The backend's score; the phone adds photo similarity within a tier.
    var score: Double = 0
    /// Development data, not a real listing.
    var isFixture: Bool
}

nonisolated enum RetailerSearchOutcome: Sendable, Equatable {
    case matches([RetailerListing])
    /// The provider answered, but nothing credible in this category.
    case noMatch
    /// Google Lens: the best credible retailer listing ("Similar match").
    case lensMatch(RetailerListing)
    /// Google Lens answered, but nothing close and usable.
    case lensNoMatch
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
    /// The Google Lens search failed (provider error, timeout, not configured, unreachable). The detail is for
    /// Debug builds; people see "Couldn't search. Try again."
    case lensFailed(String)
    /// The monthly Google Lens allowance is used up (server cap or Scrappa credits).
    case searchLimitReached

    var errorDescription: String? {
        switch self {
        case .notConfigured(let message): message
        case .offline: "You're offline. Connect to the internet and try again."
        case .unreachable: "FitMix couldn't reach its product search. Check your connection and try again."
        case .timedOut: "The product search took too long. Try again."
        case .providerBusy(let message), .providerRejected(let message): message
        case .invalidResponse: "The product search sent back something FitMix couldn't read. Try again."
        case .lensFailed: "Couldn't search. Try again."
        case .searchLimitReached: "FitMix has used this month's product searches."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .offline, .unreachable, .timedOut, .providerBusy, .invalidResponse, .lensFailed: true
        case .notConfigured, .providerRejected, .searchLimitReached: false
        }
    }
}

nonisolated protocol RetailerSearching: Sendable {
    func search(_ request: GarmentSearchRequest) async throws -> RetailerSearchOutcome
}

enum RetailerSearchers {
    /// The search Studio uses: Google Lens through the FitMix backend (`/v1/lens-search`), in Debug and Release.
    /// Debug builds can opt in to clearly labeled fixtures instead with FM_DEBUG_MATCH_FIXTURE=match|nomatch|error|slow.
    static var current: RetailerSearching {
        #if DEBUG
        if let mode = ProcessInfo.processInfo.environment["FM_DEBUG_MATCH_FIXTURE"], let fixture = FixtureRetailerSearch(mode: mode) {
            return fixture
        }
        #endif
        return LensRetailerSearch(config: .current)
    }
}

// MARK: - Backend

/// `POST /v1/garment-match` on the FitMix backend.
nonisolated struct BackendRetailerSearch: RetailerSearching {
    var config: BackendConfig?
    var session: URLSession = BackendRetailerSearch.makeSession()

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral  // nothing cached on disk
        // Visual search providers can take tens of seconds (Scrappa advises a 45 s client timeout).
        configuration.timeoutIntervalForRequest = 60
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
            var score: Double?
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
        let clues = request.clues
        if let color = clues.color { form.add(value: color, name: "color") }
        if !clues.brandHints.isEmpty { form.add(value: clues.brandHints.joined(separator: ","), name: "brand_hints") }
        if !clues.text.isEmpty { form.add(value: clues.text.joined(separator: ","), name: "text") }
        if let pattern = clues.pattern { form.add(value: pattern, name: "pattern") }
        if let style = clues.style { form.add(value: style, name: "style") }

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
                            tier: MatchTier(rawValue: item.match) ?? .similar,
                            brand: item.brand, evidence: item.evidence ?? [], provider: item.provider ?? "",
                            score: item.score ?? 0,
                            isFixture: item.fixture ?? body.fixture ?? false)
        }
        return listings.isEmpty || body.status == "no_match" ? .noMatch : .matches(listings)
    }
}

// MARK: - Request from the tapped crop

nonisolated enum GarmentSearchInput {
    /// Downscales the crop to JPEG (no metadata) and reads its clues, on-device.
    @concurrent
    static func make(category: GarmentCategory, crop: CGImage, measuredColor: SIMD3<Float>?) async -> GarmentSearchRequest? {
        guard let jpeg = jpegData(crop, maxDimension: 640) else { return nil }
        return GarmentSearchRequest(category: category, crop: jpeg,
                                    clues: GarmentClues.read(category: category, crop: crop, measuredColor: measuredColor))
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

// MARK: - On-device photo comparison

/// Orders listings within each match label by how much their photo looks like the tapped crop. Labels
/// never change here, and the backend's order (provider visual rank + evidence) stays the main signal:
/// Vision's generic feature prints tell colour and shape apart but not one shoe model from another, so the
/// photo comparison only nudges.
nonisolated enum VisualReranker {
    /// Listing photos downloaded here, by listing id, for the try-on handoff.
    typealias Photos = [String: CGImage]

    @concurrent
    static func rerank(_ listings: [RetailerListing], crop: CGImage, session: URLSession = .shared,
                       limit: Int = 6) async -> (listings: [RetailerListing], photos: Photos) {
        guard let query = SubjectPhoto(crop) else { return (listings, [:]) }
        let top = Array(listings.prefix(limit))
        var photos: Photos = [:]
        await withTaskGroup(of: (String, CGImage?).self) { group in
            for listing in top {
                guard let url = listing.imageURL else { continue }
                group.addTask { (listing.id, await download(url, session: session)) }
            }
            for await (id, image) in group { if let image { photos[id] = image } }
        }
        var adjusted = listings
        for index in adjusted.indices.prefix(limit) {
            guard let photo = photos[adjusted[index].id], let candidate = SubjectPhoto(photo) else { continue }
            adjusted[index].score += 0.15 * query.likeness(to: candidate)
        }
        // Stable within tier: label first, then score.
        let ordered = adjusted.enumerated().sorted { a, b in
            if a.element.tier != b.element.tier { return a.element.tier < b.element.tier }
            if a.element.score != b.element.score { return a.element.score > b.element.score }
            return a.offset < b.offset
        }.map(\.element)
        return (ordered, photos)
    }

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

/// A photo's main subject (garment or product) lifted onto neutral grey, with its own colour.
nonisolated struct SubjectPhoto {
    let print: VNFeaturePrintObservation
    let color: SIMD3<Float>

    init?(_ image: CGImage) {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        let lifted: CGImage
        let color: SIMD3<Float>
        if (try? handler.perform([request])) != nil, let result = request.results?.first,
           let mask = try? result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler),
           let made = Self.composite(image, mask: mask) {
            (lifted, color) = made
        } else {
            // No separable subject: compare the whole photo.
            guard let mean = ColorGrid(image, maxWidth: 48)?.mean(in: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), mask: nil) else { return nil }
            (lifted, color) = (image, mean)
        }
        guard let print = VisualSimilarity.featurePrint(lifted) else { return nil }
        self.print = print
        self.color = color
    }

    /// 0…1, higher is more alike: mostly the subject's colour, partly its feature print.
    func likeness(to other: SubjectPhoto) -> Double {
        let colour = 1 - min(Double(deltaE(color, other.color)), 60) / 60
        let shape = 1 - min(Double(VisualSimilarity.distance(print, other.print) ?? 1.5), 1.5) / 1.5
        return 0.7 * colour + 0.3 * shape
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    private static func composite(_ image: CGImage, mask: CVPixelBuffer) -> (CGImage, SIMD3<Float>)? {
        let photo = CIImage(cgImage: image)
        let maskImage = CIImage(cvPixelBuffer: mask)
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: photo.extent)
        let onGrey = photo.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: grey, kCIInputMaskImageKey: maskImage])
        let alone = photo.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: photo.extent),
                                                                          kCIInputMaskImageKey: maskImage])
        var pixel = [UInt8](repeating: 0, count: 4)
        let average = alone.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: photo.extent)])
        context.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let coverage = max(Float(pixel[3]) / 255, 0.01)
        guard coverage > 0.02, let lifted = context.createCGImage(onGrey, from: photo.extent) else { return nil }
        return (lifted, SIMD3(Float(pixel[0]) / 255 / coverage, Float(pixel[1]) / 255 / coverage, Float(pixel[2]) / 255 / coverage))
    }
}

// MARK: - Debug fixtures

#if DEBUG
/// Development-only stand-in for the backend. Every listing is marked as a fixture and Studio labels it
/// "Test fixture"; none of its names, prices or links are real.
nonisolated struct FixtureRetailerSearch: RetailerSearching {
    enum Mode: String { case match, branded, nomatch, error, slow }
    let mode: Mode

    init?(mode: String) {
        guard let mode = Mode(rawValue: mode) else { return nil }
        self.mode = mode
    }

    func search(_ request: GarmentSearchRequest) async throws -> RetailerSearchOutcome {
        try await Task.sleep(for: mode == .slow ? .seconds(6) : .seconds(1.2))
        let name = request.category.title.lowercased()
        func listing(_ id: String, _ title: String, _ tier: MatchTier, brand: String? = nil, price: Decimal? = 42,
                     evidence: [String] = []) -> RetailerListing {
            RetailerListing(id: "fixture-\(request.category.rawValue)-\(id)", title: "Test fixture \(title) (not a real listing)",
                            retailer: "FitMix test fixture", seller: nil, imageURL: nil, listingURL: nil,
                            price: price, currency: price == nil ? nil : "USD", tier: tier, brand: brand,
                            evidence: evidence, provider: "fixture", score: 0, isFixture: true)
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
        case .match, .slow:
            return .matches([listing("1", name, .similar, price: request.category == .shoes ? nil : 42), listing("2", "\(name) B", .similar)])
        }
    }
}
#endif
