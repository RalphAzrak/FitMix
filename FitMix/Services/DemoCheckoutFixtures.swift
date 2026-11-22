import Foundation

#if DEBUG
/// Debug builds only (`FM_DEBUG_CART_SEED=multistore`): a cart from four stores in two currencies, one
/// piece without a price, so the demo checkout can be tested without a camera, a search backend or a
/// network connection. Every piece is marked as a test fixture and labeled so in the cart. Names, prices
/// and links are copied from real listings seen on 21 Nov 2026; the photos only load when online.
enum DemoCheckoutFixtures {
    struct Seed {
        var product: CatalogProduct
        var size: String?
        var quantity: Int
    }

    static let multistore: [Seed] = [
        Seed(product: CatalogProduct(id: "fixture-kotn-shrunken-tee", name: "Women's Shrunken Tee in Black", brand: "Kotn", retailer: "Kotn",
                                     category: .tshirt, match: .similar,
                                     image: URL(string: "https://cdn.shopify.com/s/files/1/0932/1356/files/WOMENS_SHRUNKEN_TEE_BLACK_02.jpg").map(ProductImage.remote),
                                     price: Price(amount: 48, currencyCode: "CAD"), sizes: ["S", "M", "L"],
                                     retailerURL: URL(string: "https://kotn.com/products/womens-shrunken-tee-in-black-v2"), isFixture: true),
             size: "M", quantity: 1),
        Seed(product: CatalogProduct(id: "fixture-uniqlo-airism-tee", name: "Unisex AIRism Cotton Oversized T-Shirt", brand: "Uniqlo", retailer: "Uniqlo",
                                     category: .tshirt, match: .similar,
                                     image: URL(string: "https://image.uniqlo.com/UQ/ST3/us/imagesgoods/465185/item/usgoods_39_465185_3x4.jpg").map(ProductImage.remote),
                                     price: Price(amount: Decimal(string: "24.90")!, currencyCode: "USD"),
                                     retailerURL: URL(string: "https://www.uniqlo.com/us/en/products/E465185-000/00"), isFixture: true),
             size: nil, quantity: 2),
        Seed(product: CatalogProduct(id: "fixture-frankandoak-chino", name: "Essential Slim Chino Pant", brand: "Frank And Oak", retailer: "Frank And Oak",
                                     category: .pants, match: .similar,
                                     image: URL(string: "https://cdn.shopify.com/s/files/1/0553/7100/6130/files/2MWP0001FE-BLUE-2698.jpg").map(ProductImage.remote),
                                     price: Price(amount: Decimal(string: "81.75")!, currencyCode: "CAD"), sizes: ["30X32", "32X32"],
                                     retailerURL: URL(string: "https://www.frankandoak.com/products/mens-woven-pants-classic-navy-2mwp0001fe-dcnavy"), isFixture: true),
             size: "32X32", quantity: 1),
        Seed(product: CatalogProduct(id: "fixture-test-store-sneaker", name: "Test fixture sneaker (no listed price)", retailer: "FitMix Test Store",
                                     category: .shoes, match: .similar, isFixture: true),
             size: nil, quantity: 1),
    ]

    /// Two stores, two currencies: Kotn (CAD) and Uniqlo (USD).
    static var twostores: [Seed] { multistore.filter { ["fixture-kotn-shrunken-tee", "fixture-uniqlo-airism-tee"].contains($0.product.id) } }

    /// Replaces the cart with the named set, so a run always starts from the same cart.
    @MainActor
    static func seed(_ name: String, into cart: CartStore) {
        let seeds: [Seed]
        switch name {
        case "multistore": seeds = multistore
        case "twostores": seeds = twostores
        case "empty": seeds = []
        default: return
        }
        try? cart.removeAll()
        for seed in seeds where !cart.contains(productID: seed.product.id, size: seed.size) {
            do {
                try cart.add(seed.product, size: seed.size)
                if let line = cart.items.first(where: { $0.isSameLine(productID: seed.product.id, size: seed.size) }), seed.quantity > 1 {
                    try cart.setQuantity(seed.quantity, for: line.id)
                }
            } catch {
                CheckoutLog.record("debug-seed-failed", store: seed.product.retailer ?? "-", note: error.localizedDescription)
            }
        }
        CheckoutLog.record("debug-seeded", store: "-", note: "items=\(cart.items.count) pieces=\(cart.count) stores=\(cart.groups.map(\.name))")
    }
}
#endif
