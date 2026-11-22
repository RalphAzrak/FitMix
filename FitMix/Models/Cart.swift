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
    /// The colour the shopper chose or the store's variant names. Nil when unknown.
    var color: String?
    /// The store's own identifier for the exact variant (e.g. a Shopify variant ID), when known.
    var variantID: String?
    /// The store's name for that variant, e.g. "Black / M".
    var variantTitle: String?
    var quantity: Int
    var retailerURL: URL?
    /// Development/test data, not a real listing. Always labeled as such.
    var isFixture: Bool
    var addedAt: Date
    /// The exact store variant, when the listing is a Shopify product FitMix could resolve. Lines with
    /// one can go into that store's cart already filled in; others open at the retailer's product page.
    /// Optional, like every field added after the first version, so older saved carts still load.
    var shopify: ShopifyLine?

    init(id: UUID = UUID(), productID: String, name: String, brand: String? = nil, retailer: String? = nil,
         categoryRaw: String, imageURL: URL? = nil, priceAmount: Decimal? = nil, currencyCode: String? = nil,
         size: String? = nil, color: String? = nil, variantID: String? = nil, variantTitle: String? = nil,
         quantity: Int = 1, retailerURL: URL? = nil, isFixture: Bool = false, addedAt: Date = .now, shopify: ShopifyLine? = nil) {
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
        self.color = color
        self.variantID = variantID
        self.variantTitle = variantTitle
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

    /// The listing's link, with search-engine redirects (Google Lens `goto` links) removed.
    var productLink: URL? { retailerURL.map(RetailerLink.unwrap) }

    /// Which store this line is bought from: one checkout per store. The store's web host
    /// (`www.` dropped) when the line has a usable link, else the retailer's name.
    var retailerKey: String {
        if let shopify { return RetailerLink.storeKey(host: shopify.storeDomain) }
        if case .success(let url) = RetailerLink.check(retailerURL), let host = url.host { return RetailerLink.storeKey(host: host) }
        return storeName.lowercased()
    }

    /// What to call the store: "Kotn", "eBay" (the seller is shown separately), else the web host.
    var storeName: String {
        if let shopify { return shopify.storeName }
        if let name = retailer?.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        if let host = productLink?.host { return RetailerLink.storeKey(host: host) }
        return "Other retailer"
    }

    /// The selected size, colour and variant, as the cart shows them. Empty when none is known.
    var variantDetails: [String] {
        if let shopify {
            return shopify.displayOptions + (shopify.colourFixedByListing ? ["Colour as pictured"] : [])
        }
        return [size.map { "Size \($0)" }, color.map { "Colour \($0)" },
                variantTitle.flatMap { $0 == size || $0 == color ? nil : $0 }].compactMap { $0 }
    }
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
///
/// - Version 1: the first cart (no variant fields).
/// - Version 2: `color`, `variantID`, `variantTitle` and `shopify` on each line. Every new field is
///   optional, so a version 1 file decodes unchanged.
nonisolated struct CartData: Codable, Equatable, Sendable {
    static let currentVersion = 2
    var version = CartData.currentVersion
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
