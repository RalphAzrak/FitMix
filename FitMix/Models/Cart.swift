import Foundation
import UIKit

/// One line in the cart: a snapshot of a product as it was when the user added it.
///
/// Only plain values are stored (no `UIImage`, no `CatalogProduct`), so the cart can be saved to
/// disk and read back. The price is the listed price at the time it was added. A future checkout
/// must ask the server for the current price and never charge this stored value.
nonisolated struct CartItem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var productID: String
    var name: String
    var brand: String?
    /// e.g. "eBay · sellername".
    var retailer: String?
    /// `GarmentCategory.rawValue`. Stored as text so the saved file doesn't depend on the enum's conformances.
    var categoryRaw: String
    /// The listing's photo, when it came from the web. Local sample images aren't saved.
    var imageURL: URL?
    var priceAmount: Decimal?
    var currencyCode: String?
    /// Nil when the product lists no sizes (live retailer matches usually don't).
    var size: String?
    var quantity: Int
    var retailerURL: URL?
    /// Development/test data, not a real listing. Always labeled as such.
    var isFixture: Bool
    var addedAt: Date
    /// The exact store variant, when the listing is a Shopify product FitMix could resolve. Lines with
    /// one can be checked out inside FitMix; others still open at the retailer. Optional so carts saved
    /// before checkout existed still load.
    var shopify: ShopifyLine?

    init(id: UUID = UUID(), productID: String, name: String, brand: String? = nil, retailer: String? = nil,
         categoryRaw: String, imageURL: URL? = nil, priceAmount: Decimal? = nil, currencyCode: String? = nil,
         size: String? = nil, quantity: Int = 1, retailerURL: URL? = nil, isFixture: Bool = false, addedAt: Date = .now,
         shopify: ShopifyLine? = nil) {
        self.id = id
        self.productID = productID
        self.name = name
        self.brand = brand
        self.retailer = retailer
        self.categoryRaw = categoryRaw
        self.imageURL = imageURL
        self.priceAmount = priceAmount
        self.currencyCode = currencyCode
        self.size = size
        self.quantity = quantity
        self.retailerURL = retailerURL
        self.isFixture = isFixture
        self.addedAt = addedAt
        self.shopify = shopify
    }

    /// The same product in the same size (and, for store variants, the same variant) is one line
    /// with a higher quantity.
    func isSameLine(productID: String, size: String?, variantID: Int64? = nil) -> Bool {
        self.productID == productID && self.size == size && shopify?.variantID == variantID
    }

    func isSameLine(as other: CartItem) -> Bool {
        isSameLine(productID: other.productID, size: other.size, variantID: other.shopify?.variantID)
    }

    /// Which checkout this line belongs to: one per store.
    var retailerKey: String { shopify?.storeDomain ?? retailer ?? "Other retailers" }
}

/// One exact variant on a Shopify store, as resolved from the store's public product data.
nonisolated struct ShopifyLine: Codable, Equatable, Sendable {
    /// The host the listing used (custom domains work for cart permalinks), e.g. `kotn.com`.
    var storeDomain: String
    /// What to call the store in the cart, e.g. "Kotn".
    var storeName: String
    var productHandle: String
    /// Numeric variant ID, as a cart permalink needs it (not the GraphQL global ID).
    var variantID: Int64
    /// The store's own variant title, e.g. "Black / Black / M".
    var variantTitle: String
    /// Every option the store lists for this variant, in order, e.g. Size: M.
    var options: [Choice]
    /// True when the store sells each colour as its own product, so the colour is the listing's.
    var colourFixedByListing: Bool

    struct Choice: Codable, Equatable, Sendable {
        var name: String
        var value: String
    }

    /// "Color Black · Size M". Kotn lists the colour twice (Color and Colour); it's shown once.
    var displayOptions: [String] {
        var seenColour = false
        return options.compactMap { choice in
            let isColour = ["color", "colour", "couleur"].contains(choice.name.lowercased())
            if isColour { if seenColour { return nil }; seenColour = true }
            return choice.value.isEmpty ? nil : "\(choice.name) \(choice.value)"
        }
    }

    var colour: String? {
        options.first { ["color", "colour", "couleur"].contains($0.name.lowercased()) }?.value
    }
}

/// What FitMix saves for one account's cart on this iPhone.
nonisolated struct CartData: Codable, Equatable, Sendable {
    var version = 1
    var items: [CartItem] = []
}

@MainActor
extension CartItem {
    init(product: CatalogProduct, size: String?) {
        var imageURL: URL?
        if case .remote(let url)? = product.image { imageURL = url }
        self.init(productID: product.id, name: product.name, brand: product.brand, retailer: product.retailer,
                  categoryRaw: product.category.rawValue, imageURL: imageURL,
                  priceAmount: product.price?.amount, currencyCode: product.price?.currencyCode,
                  size: size, retailerURL: product.retailerURL, isFixture: product.isFixture)
    }

    var category: GarmentCategory { GarmentCategory(rawValue: categoryRaw) ?? .other }

    var unitPrice: Price? {
        guard let priceAmount, let currencyCode else { return nil }
        return Price(amount: priceAmount, currencyCode: currencyCode)
    }

    var lineTotal: Price? {
        unitPrice.map { Price(amount: $0.amount * Decimal(quantity), currencyCode: $0.currencyCode) }
    }
}
