import SwiftUI
import UIKit

// MARK: - Camera → Studio handoff contract
//
// The Camera scanner builds one `OutfitScan` per confirmed capture and hands it to Studio with
// `StudioStore.open(_:)`. Everything Studio shows about the street look comes from this value.
// Fields are optional wherever the vision pipeline may not produce them; Studio shows an honest
// fallback for each one.

/// What the Camera produced for one confirmed capture of one chosen person.
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

enum GarmentCategory: String, CaseIterable, Hashable {
    case jacket, top, dress, pants, skirt, shorts, shoes, bag, hat, accessory, other

    var title: String {
        switch self {
        case .jacket: "Jacket"
        case .top: "Top"
        case .dress: "Dress"
        case .pants: "Pants"
        case .skirt: "Skirt"
        case .shorts: "Shorts"
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
        case .jacket, .top, .dress: "tshirt"
        case .pants, .shorts, .skirt: "figure.stand"
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
        /// The catalog has this exact item.
        case exact
        /// Only visually similar to the detected garment.
        case similar
    }

    let id: String
    let name: String
    let brand: String?
    let category: GarmentCategory
    let match: Match
    let image: ProductImage?
    /// Nil when the catalog has no price for it. Never estimated.
    let price: Price?
    /// Sizes in stock. Empty means unknown, not "one size".
    let sizes: [String]
    let retailerURL: URL?

    init(id: String, name: String, brand: String? = nil, category: GarmentCategory, match: Match,
         image: ProductImage? = nil, price: Price? = nil, sizes: [String] = [], retailerURL: URL? = nil) {
        self.id = id
        self.name = name
        self.brand = brand
        self.category = category
        self.match = match
        self.image = image
        self.price = price
        self.sizes = sizes
        self.retailerURL = retailerURL
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

        var id: UUID { detected.id }
        var isSwapped: Bool { replacement != nil }

        /// What this piece would be bought as: the confirmed replacement, or the scan's best match.
        var product: CatalogProduct? { replacement ?? detected.matches.first }

        /// Alternatives the user can swap to, limited to this garment's category.
        var alternatives: [CatalogProduct] {
            detected.matches.filter { $0.category == detected.category }
        }

        var displayName: String? { replacement?.name ?? detected.label ?? detected.matches.first?.name }
    }

    let scanID: UUID
    var pieces: [Piece]

    init(scan: OutfitScan) {
        scanID = scan.id
        pieces = scan.garments.map { Piece(detected: $0) }
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
