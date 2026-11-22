import EmbeddedCheckoutProtocol
import Foundation
import os
import ShopifyCheckoutKit

// MARK: - One store's checkout, inside FitMix
//
// Each Shopify store in the cart gets its own checkout. FitMix builds a cart permalink from the
// store's domain and the lines' numeric variant IDs and quantities
// (`https://<store>/cart/<variant>:<qty>,<variant>:<qty>`), and Shopify Checkout Kit opens it in a
// sheet inside the app. No Storefront API token is needed for that. The store's own checkout prices
// the order, takes payment and creates the order; FitMix only receives the lifecycle events.
// See Docs/Checkout.md.

/// What a store's completed checkout told FitMix.
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
    /// Shopify's order ID, when the completion event carries one.
    var orderID: String?
    /// e.g. "#1001".
    var orderLabel: String?
    /// The buyer's order status page.
    var orderURL: URL?
    var lines: [Line]
    var completedAt: Date
}

/// A checkout FitMix is about to open, or has open, for one store.
struct RetailerCheckout: Identifiable, Equatable {
    var store: String
    var storeName: String
    /// What FitMix sent: variant → quantity. Used to clear the cart if the completion event's line
    /// items can't be read.
    var lines: [Int64: Int]
    var url: URL
    var id: String { url.absoluteString }

    /// The checkout for one retailer group, or nil when any line isn't an exact store variant.
    init?(group: CartStore.RetailerGroup, prefill: CheckoutPrefill? = CheckoutPrefill.debugDefault) {
        guard group.canCheckOutInApp, !group.items.isEmpty else { return nil }
        var lines: [Int64: Int] = [:]
        var order: [Int64] = []
        for item in group.items {
            guard let variant = item.shopify?.variantID else { return nil }
            if lines[variant] == nil { order.append(variant) }
            lines[variant, default: 0] += item.quantity
        }
        guard let url = Self.permalink(domain: group.id, lines: order.map { ($0, lines[$0] ?? 1) }, prefill: prefill) else { return nil }
        self.store = group.id
        self.storeName = group.name
        self.lines = lines
        self.url = url
    }

    /// `https://<domain>/cart/<variant>:<qty>,…` (Shopify's cart permalink, numeric variant IDs).
    nonisolated static func permalink(domain: String, lines: [(variant: Int64, quantity: Int)], prefill: CheckoutPrefill? = nil) -> URL? {
        guard !lines.isEmpty, lines.allSatisfy({ $0.quantity > 0 }) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = domain
        components.path = "/cart/" + lines.map { "\($0.variant):\($0.quantity)" }.joined(separator: ",")
        if let prefill { components.queryItems = prefill.queryItems }
        return components.url
    }

    /// Turns a completion event into a receipt and the variant → quantity that was bought.
    func receipt(from event: CheckoutCompleteEvent) -> (receipt: CheckoutReceipt, purchased: [Int64: Int]) {
        let checkout = event.checkout
        let lines = checkout.lineItems.map { line in
            CheckoutReceipt.Line(variantID: Self.numericID(line.item.id), title: line.item.title, quantity: line.quantity)
        }
        var purchased: [Int64: Int] = [:]
        for line in lines { if let id = line.variantID { purchased[id, default: 0] += line.quantity } }
        // If the event's line items don't name variants FitMix sent, fall back to what FitMix sent:
        // this checkout was opened from exactly those lines.
        if purchased.isEmpty || !purchased.keys.allSatisfy({ self.lines[$0] != nil }) { purchased = self.lines }
        let receipt = CheckoutReceipt(store: store, storeName: storeName, checkoutID: checkout.id,
                                      orderID: checkout.order?.id, orderLabel: checkout.order?.label,
                                      orderURL: checkout.order.flatMap { URL(string: $0.permalinkURL) },
                                      lines: lines, completedAt: .now)
        return (receipt, purchased)
    }

    /// `gid://shopify/ProductVariant/123` or `123` → 123.
    nonisolated static func numericID(_ id: String) -> Int64? {
        Int64(id) ?? id.split(separator: "/").last.flatMap { Int64($0.split(separator: "?").first ?? "") }
    }
}

/// Shipping details pre-filled into a legacy cart permalink (`checkout[shipping_address][…]`).
/// Debug builds only, for checking shipping to a test address; never the user's own address.
nonisolated struct CheckoutPrefill: Sendable {
    /// A reserved, undeliverable test address (RFC 2606), so the store can calculate shipping.
    var email: String?
    var fields: [(String, String)]

    var queryItems: [URLQueryItem] {
        (email.map { [URLQueryItem(name: "checkout[email]", value: $0)] } ?? [])
            + fields.map { URLQueryItem(name: "checkout[shipping_address][\($0.0)]", value: $0.1) }
    }

    /// FM_DEBUG_CHECKOUT_PREFILL=montreal: Montréal City Hall, a public address.
    static var debugDefault: CheckoutPrefill? {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["FM_DEBUG_CHECKOUT_PREFILL"] == "montreal" else { return nil }
        return CheckoutPrefill(email: "fitmix-checkout-test@example.com", fields: [
            ("first_name", "Test"), ("last_name", "Shopper"), ("address1", "275 Rue Notre-Dame Est"),
            ("city", "Montréal"), ("province", "QC"), ("country", "CA"), ("zip", "H2Y 1C6"),
        ])
        #else
        return nil
        #endif
    }
}

/// Checkout logging. Debug builds also write every lifecycle snapshot as JSON to
/// `Documents/checkout-events/`, so a run can be checked afterwards (line items, shipping options,
/// order confirmation). Buyer details are redacted by Shopify before FitMix receives them.
enum CheckoutLog {
    static let logger = Logger(subsystem: "app.fitmix", category: "checkout")

    static func configure() {
        ShopifyCheckout.configure { config in
            config.appearance = .app(.light())
            config.title = "Checkout"
            #if DEBUG
            config.logLevel = .debug
            #endif
        }
    }

    static func record(_ kind: String, store: String, checkout: Checkout? = nil, note: String? = nil) {
        var summary = "[checkout] \(kind) store=\(store)"
        if let checkout {
            summary += " id=\(checkout.id) status=\(checkout.status.rawValue) currency=\(checkout.currency)"
            summary += " lines=" + checkout.lineItems.map { "\($0.item.id)×\($0.quantity) \($0.item.title)" }.joined(separator: "; ")
            if let order = checkout.order { summary += " order=\(order.id) label=\(order.label ?? "-")" }
        }
        if let note { summary += " \(note)" }
        logger.info("\(summary, privacy: .public)")
        #if DEBUG
        print(summary)
        guard let checkout, let data = try? JSONEncoder().encode(checkout),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let folder = documents.appendingPathComponent("checkout-events", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(kind)-\(store).json"
        try? data.write(to: folder.appendingPathComponent(name))
        #endif
    }
}
