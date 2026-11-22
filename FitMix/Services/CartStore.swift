import Foundation
import UIKit

enum CartStoreError: LocalizedError, Equatable {
    case saveFailed, unreadable, notFound

    var errorDescription: String? {
        switch self {
        case .saveFailed: "FitMix couldn't save your cart on this iPhone. Check available storage and try again."
        case .unreadable: "Your saved cart couldn't be read. Clear the cart to start a new one."
        case .notFound: "That item was already removed from your cart."
        }
    }
}

/// Owns the cart: the pieces the user means to buy, with size and quantity.
///
/// Signed in, the cart is saved per account at `Application Support/Accounts/<user-id>/cart.json`
/// with complete file protection, the same approach as `ProfileStore`. Signed out, the cart lives in
/// memory only. Those items move into the account's cart when the user signs in. Signing out
/// clears the cart from memory; the saved file comes back when that account signs in again.
///
/// Lines are grouped by retailer, and each Shopify store gets its own checkout inside FitMix
/// (`RetailerCheckout`). The store prices the order; `subtotal` here is only the sum of the prices
/// the listings showed when they were added. A completed checkout removes only what that store sold.
@Observable
final class CartStore {
    static let maxQuantity = 10

    private(set) var items: [CartItem] = []
    private(set) var accountID: UUID?
    /// Set when the signed-in account's saved cart couldn't be read. The file is never overwritten
    /// then; `removeAll()` deletes it so the user can start over.
    private(set) var loadError: String?

    @ObservationIgnored let baseDirectory: URL
    /// Sample-catalog photos for this session. They can't be saved, so after a relaunch those
    /// items show the category symbol instead.
    @ObservationIgnored private var localImages: [String: UIImage] = [:]

    init(baseDirectory: URL = ProfileStore.standardDirectory) {
        self.baseDirectory = baseDirectory
    }

    /// Total number of pieces, counting quantities.
    var count: Int { items.reduce(0) { $0 + $1.quantity } }
    var isEmpty: Bool { items.isEmpty }

    func contains(productID: String, size: String?) -> Bool {
        items.contains { $0.isSameLine(productID: productID, size: size) }
    }

    /// True when any line of this product is in the cart, whatever its variant.
    func containsProduct(_ productID: String) -> Bool { items.contains { $0.productID == productID } }

    func localImage(for item: CartItem) -> UIImage? { localImages[item.productID] }

    // MARK: Retailers

    struct RetailerGroup: Identifiable {
        var id: String
        var name: String
        var items: [CartItem]
        /// Every line is an exact Shopify variant, so this store can be checked out in FitMix.
        var canCheckOutInApp: Bool { items.allSatisfy { $0.shopify != nil } }
        var count: Int { items.reduce(0) { $0 + $1.quantity } }
    }

    /// Lines grouped by store, in the order each store was first added.
    var groups: [RetailerGroup] {
        var order: [String] = []
        var byKey: [String: [CartItem]] = [:]
        for item in items {
            if byKey[item.retailerKey] == nil { order.append(item.retailerKey) }
            byKey[item.retailerKey, default: []].append(item)
        }
        return order.map { key in
            let lines = byKey[key] ?? []
            return RetailerGroup(id: key, name: lines.first?.shopify?.storeName ?? lines.first?.retailer ?? key, items: lines)
        }
    }

    /// Receipts of checkouts completed in this session, newest first.
    private(set) var receipts: [CheckoutReceipt] = []

    // MARK: Account switching

    /// Loads `accountID`'s saved cart, or clears the cart from memory when nil (signed out).
    func activate(accountID: UUID?) {
        guard accountID != self.accountID else { return }
        // A guest cart (signed out) moves into the account that signs in. Switching straight
        // from one account to another never carries items across.
        let guestItems = self.accountID == nil ? items : []
        self.accountID = accountID
        items = []
        loadError = nil
        guard accountID != nil else { return }
        load()
        guard !guestItems.isEmpty, loadError == nil else { return }
        try? update { items in
            for guest in guestItems { Self.merge(guest, into: &items) }
        }
    }

    // MARK: Editing

    /// Adds one of `product` in `size`. Adding the same product and size again raises its quantity.
    func add(_ product: CatalogProduct, size: String?) throws {
        if case .local(let image)? = product.image { localImages[product.id] = image }
        let item = CartItem(product: product, size: size)
        try update { Self.merge(item, into: &$0) }
    }

    /// Adds one exact store variant of `product`, resolved from the store's product data.
    func add(_ product: CatalogProduct, resolved: ShopifyProduct, variant: ShopifyProduct.Variant, quantity: Int = 1) throws {
        if case .local(let image)? = product.image { localImages[product.id] = image }
        let choices = resolved.options.indices.map { index in
            ShopifyLine.Choice(name: resolved.options[index].name, value: variant.values.indices.contains(index) ? variant.values[index] : "")
        }
        let line = ShopifyLine(storeDomain: resolved.link.host, storeName: product.retailer ?? resolved.vendor ?? resolved.link.host,
                               productHandle: resolved.link.handle, variantID: variant.id, variantTitle: variant.title,
                               options: choices, colourFixedByListing: resolved.colourIsFixedByListing)
        var item = CartItem(product: product, size: choices.first { ["size", "taille"].contains($0.name.lowercased()) }?.value)
        item.shopify = line
        item.quantity = min(max(quantity, 1), Self.maxQuantity)
        if item.imageURL == nil { item.imageURL = resolved.imageURL }
        // The store's current variant price, in the listing's currency when the listing gave one.
        if let price = variant.price, item.currencyCode != nil { item.priceAmount = price }
        try update { Self.merge(item, into: &$0) }
    }

    /// A store's checkout finished. Removes what that order contains (by variant and quantity) from
    /// that store's lines only; other stores' lines are never touched.
    func completeCheckout(store: String, purchased: [Int64: Int], order: CheckoutReceipt) throws {
        receipts.insert(order, at: 0)
        try update { items in
            var remaining = purchased
            items = items.compactMap { item in
                guard item.retailerKey == store, let variant = item.shopify?.variantID, let bought = remaining[variant], bought > 0 else { return item }
                let taken = min(bought, item.quantity)
                remaining[variant] = bought - taken
                var item = item
                item.quantity -= taken
                return item.quantity > 0 ? item : nil
            }
        }
    }

    func setQuantity(_ quantity: Int, for id: UUID) throws {
        guard items.contains(where: { $0.id == id }) else { throw CartStoreError.notFound }
        let clamped = min(max(quantity, 1), Self.maxQuantity)
        try update { items in
            if let index = items.firstIndex(where: { $0.id == id }) { items[index].quantity = clamped }
        }
    }

    func remove(id: UUID) throws {
        guard items.contains(where: { $0.id == id }) else { throw CartStoreError.notFound }
        try update { items in items.removeAll { $0.id == id } }
    }

    /// Empties the cart. Also deletes a saved cart that couldn't be read.
    func removeAll() throws {
        if let url = fileURL, FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) } catch { throw CartStoreError.saveFailed }
        }
        items = []
        loadError = nil
    }

    private static func merge(_ item: CartItem, into items: inout [CartItem]) {
        if let index = items.firstIndex(where: { $0.isSameLine(as: item) }) {
            items[index].quantity = min(items[index].quantity + item.quantity, maxQuantity)
        } else {
            items.append(item)
        }
    }

    // MARK: Totals

    /// Sum of the listed prices of the items that have one, if they share a currency.
    var subtotal: (price: Price, pricedCount: Int)? {
        let priced = items.compactMap(\.lineTotal)
        guard let currency = priced.first?.currencyCode, priced.allSatisfy({ $0.currencyCode == currency }) else { return nil }
        let sum = priced.reduce(Decimal.zero) { $0 + $1.amount }
        return (Price(amount: sum, currencyCode: currency), items.filter { $0.unitPrice != nil }.count)
    }

    var hasMixedCurrencies: Bool {
        Set(items.compactMap(\.currencyCode)).count > 1
    }

    // MARK: Disk

    private var fileURL: URL? {
        accountID.map {
            baseDirectory.appendingPathComponent($0.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent("cart.json")
        }
    }

    private func load() {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            items = try JSONDecoder().decode(CartData.self, from: Data(contentsOf: url)).items
        } catch {
            items = []
            loadError = CartStoreError.unreadable.localizedDescription
        }
    }

    /// Applies a change and, when signed in, writes it to disk. Memory only changes once the write
    /// succeeds, so a failed save never shows as saved. Signed out, the change stays in memory.
    private func update(_ change: (inout [CartItem]) -> Void) throws {
        guard loadError == nil else { throw CartStoreError.unreadable }
        var next = items
        change(&next)
        if let url = fileURL {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.protectionKey: FileProtectionType.complete])
                try JSONEncoder().encode(CartData(items: next)).write(to: url, options: [.atomic, .completeFileProtection])
            } catch {
                throw CartStoreError.saveFailed
            }
        }
        items = next
    }
}
