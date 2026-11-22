import Foundation
import os

// MARK: - Checking out a multi-store cart
//
// One FitMix cart can hold pieces from several stores. Each store is checked out on its own site:
// FitMix never takes payment and never stores payment details. For each store, FitMix either opens
// that store's cart already filled with the exact variants and quantities (only when it has a
// verified way to do that; today that's a Shopify cart permalink) or opens each item's product page
// for the shopper to add there. Opening a store never counts as a purchase: only a verified order
// confirmation removes anything from the cart. See Docs/Checkout.md.

/// Retailer links in the cart: unwrapping, checking, and naming the store they belong to.
nonisolated enum RetailerLink {
    enum Problem: Error, Equatable, Sendable {
        case missing, notWeb, insecure

        /// Why the item's checkout action is disabled, for the shopper.
        var explanation: String {
            switch self {
            case .missing: "FitMix has no link to this listing, so it can't open it. Find it on the store's site, or remove it."
            case .notWeb: "This listing's link isn't a web page FitMix can open. Find it on the store's site, or remove it."
            case .insecure: "This listing's link isn't secure (it doesn't use https), so FitMix won't open it for checkout."
            }
        }
    }

    /// Google Lens result links (`google.com/goto?url=` or `/url?q=`) → the listing they point to.
    static func unwrap(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(), host == "google.com" || host.hasSuffix(".google.com"),
              ["/goto", "/url"].contains(url.path),
              let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                  .first(where: { $0.name == "url" || $0.name == "q" })?.value,
              let target = URL(string: inner) else { return url }
        return target
    }

    /// A link FitMix will open for checkout: a public https page. Anything else says why not.
    static func check(_ url: URL?) -> Result<URL, Problem> {
        guard let url else { return .failure(.missing) }
        let link = unwrap(url)
        guard let scheme = link.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = link.host?.lowercased(), host.contains("."), host != "localhost" else { return .failure(.notWeb) }
        guard scheme == "https" else { return .failure(.insecure) }
        return .success(link)
    }

    /// `www.Kotn.com` → `kotn.com`: the same store whatever subdomain a listing used.
    static func storeKey(host: String) -> String {
        let host = host.lowercased()
        for prefix in ["www.", "m.", "shop."] where host.hasPrefix(prefix) { return String(host.dropFirst(prefix.count)) }
        return host
    }
}

/// A store's own cart, opened already filled with exact variants and quantities.
struct PrefilledCart: Identifiable, Equatable {
    /// How FitMix knows the cart will hold the right variants. Only verified ways are listed.
    enum Kind: Equatable {
        /// `https://<store>/cart/<variant>:<qty>,…` with numeric variant IDs read from the store's
        /// own product data. Opened in Shopify Checkout Kit, which reports a completed order.
        case shopifyCartPermalink
    }

    var kind: Kind
    /// The cart group this belongs to (`CartItem.retailerKey`).
    var store: String
    var storeName: String
    var url: URL
    /// What FitMix sent: variant → quantity. Used to clear the cart if a completion event's line items
    /// can't be read.
    var lines: [Int64: Int]
    /// The cart lines this covers.
    var itemIDs: [UUID]
    var id: String { url.absoluteString }
}

/// How one store in the cart is checked out.
struct StoreCheckoutPlan: Identifiable {
    struct ItemAction: Identifiable {
        var item: CartItem
        /// The product page to open, or why it can't be opened.
        var destination: Result<URL, RetailerLink.Problem>
        var id: UUID { item.id }
        var url: URL? { if case .success(let url) = destination { url } else { nil } }
        var problem: RetailerLink.Problem? { if case .failure(let problem) = destination { problem } else { nil } }
    }

    var id: String
    var storeName: String
    var items: [CartItem]
    /// The store's cart with these lines already in it, when FitMix has a verified way to fill it.
    var prefilledCart: PrefilledCart?
    /// Lines the shopper opens one by one and adds on the store's site.
    var itemActions: [ItemAction]

    init(group: CartStore.RetailerGroup, prefill: CheckoutPrefill? = CheckoutPrefill.debugDefault) {
        id = group.id
        storeName = group.name
        items = group.items
        prefilledCart = PrefilledCart.shopify(store: group.id, storeName: group.name, items: group.items, prefill: prefill)
        let covered = Set(prefilledCart?.itemIDs ?? [])
        itemActions = group.items.filter { !covered.contains($0.id) }
            .map { ItemAction(item: $0, destination: RetailerLink.check($0.retailerURL)) }
    }

    /// Items with a link FitMix can open (inside the prefilled cart or one by one).
    var openableCount: Int { (prefilledCart?.itemIDs.count ?? 0) + itemActions.filter { $0.url != nil }.count }
}

/// What a store's completed checkout told FitMix. Only built from a verified completion event.
nonisolated struct CheckoutReceipt: Identifiable, Equatable, Sendable {
    struct Line: Equatable, Sendable {
        var variantID: Int64?
        var title: String
        var quantity: Int
    }
    var id: String { checkoutID }
    var store: String
    var storeName: String
    var checkoutID: String
    /// The store's order ID, when the completion event carries one.
    var orderID: String?
    /// e.g. "#1001".
    var orderLabel: String?
    /// The buyer's order status page.
    var orderURL: URL?
    var lines: [Line]
    var completedAt: Date
    /// Debug builds only: built by FitMix to test cart clearing. No order exists.
    var isSimulated: Bool { checkoutID.hasPrefix("simulated-") }
}

/// Checkout logging: what was opened, what came back, and what the cart holds afterwards. Never
/// logs payment or buyer details (FitMix doesn't receive payment details at all).
enum CheckoutLog {
    static let logger = Logger(subsystem: "app.fitmix", category: "checkout")

    static func record(_ kind: String, store: String, note: String? = nil) {
        var summary = "[checkout] \(kind) store=\(store)"
        if let note { summary += " \(note)" }
        logger.info("\(summary, privacy: .public)")
        #if DEBUG
        print(summary)
        #endif
    }

    static func describe(_ items: [CartItem]) -> String {
        "[" + items.map { "\($0.retailerKey):\($0.name)×\($0.quantity)" }.joined(separator: "; ") + "]"
    }
}
