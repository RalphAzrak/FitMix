import SwiftUI
import UIKit

// MARK: - Camera → Studio handoff contract
//
// One `OutfitScan` is built per garment tapped in the Camera (`StudioStore.openLive`), or comes ready-made
// from a Debug sample scan through Outfit Review (`StudioStore.open`). Everything Studio shows about the
// street look comes from this value.
// Fields are optional wherever the vision pipeline may not produce them; Studio shows an honest
// fallback for each one.

/// What the Camera produced for one frame of one chosen person.
struct OutfitScan: Identifiable {
    let id: UUID
    let capturedAt: Date
    /// The captured frame, or the crop around the selected person. Shown uncropped in Studio.
    let image: UIImage
    /// Where the chosen person is in `image`, normalized (0–1, top-left origin). Optional.
    let subjectBounds: CGRect?
    /// Garments on the chosen person, in display order (outer layers first works best).
    let garments: [DetectedGarment]

    init(id: UUID = UUID(), capturedAt: Date = .now, image: UIImage, subjectBounds: CGRect? = nil, garments: [DetectedGarment]) {
        self.id = id
        self.capturedAt = capturedAt
        self.image = image
        self.subjectBounds = subjectBounds
        self.garments = garments
    }
}

/// One garment the vision pipeline found on the chosen person.
struct DetectedGarment: Identifiable {
    let id: UUID
    let category: GarmentCategory
    /// Short description from the pipeline, e.g. "Olive bomber". Optional.
    let label: String?
    /// Garment region in the scan image, normalized (0–1, top-left origin). Optional.
    let bounds: CGRect?
    /// Segmentation cutout with a transparent background. Preferred for the garment card.
    let cutout: UIImage?
    /// Rectangular crop of the garment. Used when there is no cutout.
    let crop: UIImage?
    /// Catalog products for this garment, best first. Empty when nothing was matched.
    let matches: [CatalogProduct]

    init(id: UUID = UUID(), category: GarmentCategory, label: String? = nil, bounds: CGRect? = nil,
         cutout: UIImage? = nil, crop: UIImage? = nil, matches: [CatalogProduct] = []) {
        self.id = id
        self.category = category
        self.label = label
        self.bounds = bounds
        self.cutout = cutout
        self.crop = crop
        self.matches = matches
    }
}

nonisolated enum GarmentCategory: String, CaseIterable, Hashable, Sendable {
    case jacket, tshirt, top, dress, pants, skirt, shorts, bottoms, shoes, bag, hat, accessory, other

    /// The four categories the live scanner can tell apart and search for.
    static let liveScannable: [GarmentCategory] = [.jacket, .tshirt, .pants, .shoes]

    var title: String {
        switch self {
        case .jacket: "Jacket"
        case .tshirt: "T-shirt"
        case .top: "Top"
        case .dress: "Dress"
        case .pants: "Pants"
        case .skirt: "Skirt"
        case .shorts: "Shorts"
        /// Lower-body garment whose exact type wasn't identified (pants, skirt, or shorts).
        case .bottoms: "Bottoms"
        case .shoes: "Shoes"
        case .bag: "Bag"
        case .hat: "Hat"
        case .accessory: "Accessory"
        case .other: "Piece"
        }
    }

    /// Shown when the scan has no image for the garment.
    var symbol: String {
        switch self {
        case .jacket, .tshirt, .top, .dress: "tshirt"
        case .pants, .shorts, .skirt, .bottoms: "figure.stand"
        case .shoes: "shoe"
        case .bag: "bag"
        case .hat: "graduationcap"
        case .accessory, .other: "sparkles"
        }
    }
}

/// A product from the catalog that the Camera's matching step returned.
struct CatalogProduct: Identifiable, Hashable {
    enum Match: Hashable {
        /// Corroborated as this exact item (product code, same image, or brand + model + colour).
        case exact
        /// Only the brand is supported: "Likely from <brand>".
        case brand
        /// Only visually similar to the detected garment.
        case similar
    }

    /// What the card calls this match.
    var matchLabel: String {
        switch match {
        case .exact: "Exact match"
        case .brand: brand.map { "Likely from \($0)" } ?? "Likely same brand"
        case .similar: visualScore == nil ? "Similar match" : "Closest match"
        }
    }

    var visualMatchLabel: String {
        visualScore.map { "\(matchLabel) · \($0)% visual match" } ?? matchLabel
    }

    var visualScore: Int? = nil
    let id: String
    let name: String
    let brand: String?
    /// Where the listing is sold, e.g. "eBay · sellername". Nil for the sample catalog.
    let retailer: String?
    let category: GarmentCategory
    let match: Match
    let image: ProductImage?
    /// Nil when the catalog has no price for it. Never estimated.
    let price: Price?
    /// Sizes in stock. Empty means unknown, not "one size".
    let sizes: [String]
    let retailerURL: URL?
    /// Development/test data, not a real listing. Always labeled as such where shown.
    let isFixture: Bool
    /// Why it got its match label, in words.
    var evidence: [String] = []

    init(id: String, name: String, brand: String? = nil, retailer: String? = nil, category: GarmentCategory, match: Match,
         image: ProductImage? = nil, price: Price? = nil, sizes: [String] = [], retailerURL: URL? = nil, isFixture: Bool = false,
         evidence: [String] = [], visualScore: Int? = nil) {
        self.id = id
        self.name = name
        self.brand = brand
        self.retailer = retailer
        self.category = category
        self.match = match
        self.image = image
        self.price = price
        self.sizes = sizes
        self.retailerURL = retailerURL
        self.isFixture = isFixture
        self.evidence = evidence
        self.visualScore = visualScore
    }
}

enum ProductImage: Hashable {
    case local(UIImage)
    case remote(URL)
}

struct Price: Hashable {
    var amount: Decimal
    /// ISO 4217, e.g. "USD".
    var currencyCode: String

    var formatted: String { amount.formatted(.currency(code: currencyCode)) }
}

// MARK: - Working look

/// The look being edited in Studio. Built from a scan and never writes back to it, so the
/// original capture and detections stay as the reference for what the person was wearing.
struct WorkingLook {
    struct Piece: Identifiable {
        let detected: DetectedGarment
        /// Set after the user confirms a swap.
        var replacement: CatalogProduct?
        /// The live retailer search's best listing for this garment, once one has arrived.
        var retailerMatch: CatalogProduct?

        var id: UUID { detected.id }
        var isSwapped: Bool { replacement != nil }

        /// What this piece would be bought as: the confirmed replacement, the retailer match, or
        /// the scan's best match.
        var product: CatalogProduct? { replacement ?? retailerMatch ?? detected.matches.first }

        /// Alternatives the user can swap to, limited to this garment's category.
        var alternatives: [CatalogProduct] {
            detected.matches.filter { $0.category == detected.category }
        }

        var displayName: String? { replacement?.name ?? retailerMatch?.name ?? detected.label ?? detected.matches.first?.name }
    }

    var pieces: [Piece]

    /// - Parameter selected: garments chosen in Outfit Review; nil keeps every detected garment.
    init(scan: OutfitScan, selected: Set<UUID>? = nil) {
        pieces = scan.garments.filter { selected?.contains($0.id) ?? true }.map { Piece(detected: $0) }
    }

    /// Prices of the pieces that have one, if they share a currency.
    var total: (price: Price, pricedCount: Int)? {
        let prices = pieces.compactMap { $0.product?.price }
        guard let currency = prices.first?.currencyCode, prices.allSatisfy({ $0.currencyCode == currency }) else { return nil }
        let sum = prices.reduce(Decimal.zero) { $0 + $1.amount }
        return (Price(amount: sum, currencyCode: currency), prices.count)
    }

    var hasMixedCurrencies: Bool {
        Set(pieces.compactMap { $0.product?.price?.currencyCode }).count > 1
    }
}

// MARK: - Studio hero frame

/// What Studio's top image shows for a scan: a crop around the selected person that keeps every
/// detected garment in view, or the whole captured frame when the scan has no subject region.
/// Garment regions are converted into this image's coordinates so outlines and zoom line up.
struct HeroFrame {
    /// Image shown in Studio and in zoom.
    let image: UIImage
    /// The part of `OutfitScan.image` that `image` shows, normalized.
    let region: CGRect

    /// Room left around the person, as a fraction of the crop's own size.
    private static let margin: CGFloat = 0.06

    init(scan: OutfitScan) {
        guard let subject = scan.subjectBounds?.standardized, subject.width > 0, subject.height > 0 else {
            image = scan.image
            region = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }
        let outfit = scan.garments.compactMap(\.bounds).reduce(subject) { $0.union($1) }
        let padded = outfit.insetBy(dx: -outfit.width * Self.margin, dy: -outfit.height * Self.margin)
        let clamped = padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull, clamped.width < 0.98 || clamped.height < 0.98 else {
            image = scan.image
            region = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }
        region = clamped
        image = Self.crop(scan.image, to: clamped)
    }

    /// A region of the scan image, in this frame's coordinates. Nil if it falls outside the frame.
    func convert(_ bounds: CGRect) -> CGRect? {
        let visible = bounds.intersection(region)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        return CGRect(x: (visible.minX - region.minX) / region.width,
                      y: (visible.minY - region.minY) / region.height,
                      width: visible.width / region.width,
                      height: visible.height / region.height)
    }

    /// Crops in display orientation (the way the photo looks), so EXIF-rotated camera images work.
    private static func crop(_ image: UIImage, to region: CGRect) -> UIImage {
        let size = image.size
        let rect = CGRect(x: region.minX * size.width, y: region.minY * size.height,
                          width: region.width * size.width, height: region.height * size.height).integral
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            image.draw(at: CGPoint(x: -rect.minX, y: -rect.minY))
        }
    }
}
