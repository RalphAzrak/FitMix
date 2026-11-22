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
// clues read on-device (`GarmentClues`: printed text and codes, colour, pattern, style). Studio's search is
// Google Lens through the backend (`LensSearch.swift`), which answers with one listing or none. Lists of
// listings labeled exact / brand / similar, and the on-device photo comparison that orders them
// (`VisualReranker`), now come only from the Debug fixtures at the end of this file. The full outfit frame,
// profile photos and avatar images never leave the iPhone for search. See Docs/LiveGarmentMatch.md and
// Backend/README.md.

/// Exactly what leaves the phone for one search.
nonisolated struct GarmentSearchRequest: Sendable {
    var category: GarmentCategory
    /// JPEG of the garment crop only, long edge ≤ 640 px.
    var crop: Data
    /// What the phone read on the crop.
    var clues: GarmentClueSet
}

/// How sure FitMix is that a listing is the garment the user tapped.
nonisolated enum MatchTier: Sendable, Equatable, Comparable {
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
    /// The search failed in a way that may pass (busy, rate limited, outage). Only the Debug fixtures throw this.
    case providerBusy(String)
    /// The Google Lens search failed (provider error, timeout, not configured, unreachable). The detail is for
    /// Debug builds; people see "Couldn't search. Try again."
    case lensFailed(String)
    /// The monthly Google Lens allowance is used up (server cap or Scrappa credits).
    case searchLimitReached

    var errorDescription: String? {
        switch self {
        case .providerBusy(let message): message
        case .lensFailed: "Couldn't search. Try again."
        case .searchLimitReached: "FitMix has used this month's product searches."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .providerBusy, .lensFailed: true
        case .searchLimitReached: false
        }
    }
}

nonisolated protocol RetailerSearching: Sendable {
    func search(_ request: GarmentSearchRequest) async throws -> RetailerSearchOutcome
}

enum RetailerSearchers {
    /// The search Studio uses: Google Lens through the FitMix backend (`/v1/lens-search`), in Debug and Release.
    /// Debug builds can opt in to clearly labeled fixtures instead with FM_DEBUG_MATCH_FIXTURE=match|branded|nomatch|error|slow|shopify.
    static var current: RetailerSearching {
        #if DEBUG
        if let mode = ProcessInfo.processInfo.environment["FM_DEBUG_MATCH_FIXTURE"], let fixture = FixtureRetailerSearch(mode: mode) {
            return fixture
        }
        #endif
        return LensRetailerSearch(config: .current)
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
    /// FM_DEBUG_MATCH_FIXTURE=shopify: one real Shopify listing for the T-shirt and one for the pants.
    static let shopifyListings: [GarmentCategory: RetailerListing] = [
        .tshirt: RetailerListing(
            id: "shopify-kotn-womens-shrunken-tee-in-black-v2", title: "Women's Shrunken Tee in Black", retailer: "Kotn",
            seller: nil, imageURL: URL(string: "https://cdn.shopify.com/s/files/1/0932/1356/files/WOMENS_SHRUNKEN_TEE_BLACK_02.jpg"),
            listingURL: URL(string: "https://kotn.com/products/womens-shrunken-tee-in-black-v2"),
            price: 48, currency: "CAD", tier: .similar, brand: "Kotn",
            evidence: ["Debug: hand-picked real Shopify listing, not found by visual search"], provider: "debug-shopify", score: 0, isFixture: false),
        .pants: RetailerListing(
            id: "shopify-frankandoak-mens-woven-pants-classic-navy", title: "Essential Slim Chino Pant", retailer: "Frank And Oak",
            seller: nil, imageURL: URL(string: "https://cdn.shopify.com/s/files/1/0553/7100/6130/files/2MWP0001FE-BLUE-2698.jpg"),
            listingURL: URL(string: "https://www.frankandoak.com/products/mens-woven-pants-classic-navy-2mwp0001fe-dcnavy"),
            price: 81.75, currency: "CAD", tier: .similar, brand: "Frank And Oak",
            evidence: ["Debug: hand-picked real Shopify listing, not found by visual search"], provider: "debug-shopify", score: 0, isFixture: false),
    ]

    enum Mode: String { case match, branded, nomatch, error, slow, shopify }
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
        case .shopify:
            // Real product pages on two Shopify stores, hand-picked because no visual search provider is
            // configured here. Everything after this (product mapping, variant lookup, cart, checkout)
            // is the real path. Labeled as hand-picked in the evidence.
            guard let listing = Self.shopifyListings[request.category] else { return .noMatch }
            return .matches([listing])
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
