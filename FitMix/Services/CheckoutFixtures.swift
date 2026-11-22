import Foundation

#if DEBUG
/// Debug builds only (`FM_DEBUG_CHECKOUT_FIXTURE=1`): Studio Fit's search answers with fixed listings so
/// cart and checkout can be tested without outfit recognition or a search backend. Installed through
/// `StudioStore.searcher`, the same interface the real search uses; nothing in recognition or matching
/// changes. Everything after the search (choosing a listing, Add to Cart, the cart, Checkout) is the
/// real path.
///
/// | Piece | Listings, best first | What it tests |
/// | --- | --- | --- |
/// | T-shirt | Kotn tee (Shopify, CAD), then Uniqlo AIRism tee (not Shopify, USD) | Choosing the alternative; a non-Shopify store whose URL has `/products/` |
/// | Pants | Frank And Oak chino (Shopify, CAD) | A prefilled cart with an exact variant and quantity |
/// | Shoes | A test fixture with no link (CAD) | A disabled checkout action |
/// | Jacket | A test fixture with an `http://` link (USD) | A disabled checkout action |
///
/// The Kotn, Uniqlo and Frank And Oak listings are real product pages, hand-picked on 21 Nov 2026
/// (titles, photos and listed prices as the stores showed them). Their evidence says so.
nonisolated struct CheckoutFixtureSearch: RetailerSearching {
    static let handPicked = ["Debug: hand-picked real listing for checkout testing, not found by visual search"]

    static let listings: [GarmentCategory: [RetailerListing]] = [
        .tshirt: [
            RetailerListing(
                id: "shopify-kotn-womens-shrunken-tee-in-black-v2", title: "Women's Shrunken Tee in Black", retailer: "Kotn",
                seller: nil, imageURL: URL(string: "https://cdn.shopify.com/s/files/1/0932/1356/files/WOMENS_SHRUNKEN_TEE_BLACK_02.jpg"),
                listingURL: URL(string: "https://kotn.com/products/womens-shrunken-tee-in-black-v2"),
                price: 48, currency: "CAD", tier: .brand, brand: "Kotn", evidence: handPicked, provider: "debug-checkout", isFixture: false),
            RetailerListing(
                id: "uniqlo-us-E465185-000", title: "Unisex AIRism Cotton Oversized T-Shirt | Half-Sleeve", retailer: "Uniqlo",
                seller: nil, imageURL: URL(string: "https://image.uniqlo.com/UQ/ST3/us/imagesgoods/465185/item/usgoods_39_465185_3x4.jpg"),
                listingURL: URL(string: "https://www.uniqlo.com/us/en/products/E465185-000/00"),
                price: 24.90, currency: "USD", tier: .similar, brand: "Uniqlo", evidence: handPicked, provider: "debug-checkout", isFixture: false),
        ],
        .pants: [
            RetailerListing(
                id: "shopify-frankandoak-mens-woven-pants-classic-navy", title: "Essential Slim Chino Pant", retailer: "Frank And Oak",
                seller: nil, imageURL: URL(string: "https://cdn.shopify.com/s/files/1/0553/7100/6130/files/2MWP0001FE-BLUE-2698.jpg"),
                listingURL: URL(string: "https://www.frankandoak.com/products/mens-woven-pants-classic-navy-2mwp0001fe-dcnavy"),
                price: 81.75, currency: "CAD", tier: .similar, brand: "Frank And Oak", evidence: handPicked, provider: "debug-checkout", isFixture: false),
        ],
        .shoes: [
            RetailerListing(
                id: "fixture-checkout-shoes-no-link", title: "Test fixture sneaker with no link (not a real listing)", retailer: "FitMix Test Store",
                seller: nil, imageURL: nil, listingURL: nil, price: 120, currency: "CAD", tier: .similar,
                evidence: ["test fixture: listing without a product URL"], provider: "debug-checkout", isFixture: true),
        ],
        .jacket: [
            RetailerListing(
                id: "fixture-checkout-jacket-insecure-link", title: "Test fixture jacket with an insecure link (not a real listing)",
                retailer: "FitMix Test Outlet", seller: nil, imageURL: nil, listingURL: URL(string: "http://example.com/products/test-jacket"),
                price: 60, currency: "USD", tier: .similar,
                evidence: ["test fixture: listing whose URL isn't https"], provider: "debug-checkout", isFixture: true),
        ],
    ]

    static var isEnabled: Bool { ProcessInfo.processInfo.environment["FM_DEBUG_CHECKOUT_FIXTURE"] == "1" }

    func search(_ request: GarmentSearchRequest) async throws -> RetailerSearchOutcome {
        try await Task.sleep(for: .seconds(0.8))
        guard let found = Self.listings[request.category] else { return .noMatch }
        return .matches(found)
    }
}
#endif
