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
/// There's no checkout yet. When there is, the server prices the order; `subtotal` here is only
/// the sum of the prices the listings showed when they were added.
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

    func localImage(for item: CartItem) -> UIImage? { localImages[item.productID] }

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
        if let index = items.firstIndex(where: { $0.isSameLine(productID: item.productID, size: item.size) }) {
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
