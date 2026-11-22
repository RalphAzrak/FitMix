import EmbeddedCheckoutProtocol
import Foundation
import ShopifyCheckoutKit

// MARK: - Shopify stores: a prefilled cart and Checkout Kit
//
// One way FitMix can fill a store's cart. For lines resolved to exact Shopify variants (see
// ShopifyProducts.swift), FitMix builds the store's cart permalink from the store's domain and the
// numeric variant IDs and quantities (`https://<store>/cart/<variant>:<qty>,<variant>:<qty>`), and
// Shopify Checkout Kit opens it in a sheet inside the app. No Storefront API token is needed. The
// store's own checkout prices the order, takes payment and creates the order; FitMix only receives
// the lifecycle events, and only a completion event counts as a purchase. Stores that aren't Shopify
// never reach this file. See Docs/Checkout.md.

extension PrefilledCart {
    /// The store's cart permalink for the lines in `items` that are exact Shopify variants, or nil
    /// when there are none.
    static func shopify(store: String, storeName: String, items: [CartItem], prefill: CheckoutPrefill? = nil) -> PrefilledCart? {
        let variantItems = items.filter { $0.shopify != nil }
        guard let domain = variantItems.first?.shopify?.storeDomain else { return nil }
        var lines: [Int64: Int] = [:]
        var order: [Int64] = []
        for item in variantItems {
            guard let variant = item.shopify?.variantID, item.quantity > 0 else { return nil }
            if lines[variant] == nil { order.append(variant) }
            lines[variant, default: 0] += item.quantity
        }
        guard let url = shopifyPermalink(domain: domain, lines: order.map { ($0, lines[$0] ?? 1) }, prefill: prefill) else { return nil }
        return PrefilledCart(kind: .shopifyCartPermalink, store: store, storeName: storeName, url: url, lines: lines,
                             itemIDs: variantItems.map(\.id))
    }

    /// `https://<domain>/cart/<variant>:<qty>,…` (Shopify's cart permalink, numeric variant IDs).
    nonisolated static func shopifyPermalink(domain: String, lines: [(variant: Int64, quantity: Int)], prefill: CheckoutPrefill? = nil) -> URL? {
        guard !lines.isEmpty, lines.allSatisfy({ $0.quantity > 0 }) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = domain
        components.path = "/cart/" + lines.map { "\($0.variant):\($0.quantity)" }.joined(separator: ",")
        if let prefill { components.queryItems = prefill.queryItems }
        return components.url
    }

    /// Turns a Checkout Kit completion event into a receipt and the variant → quantity that was bought.
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

/// Checkout Kit setup and its lifecycle snapshots. Debug builds also write every snapshot as JSON to
/// `Documents/checkout-events/`, so a run can be checked afterwards (line items, shipping options,
/// order confirmation). Buyer details are redacted by Shopify before FitMix receives them.
enum ShopifyCheckoutSetup {
    static func configure() {
        ShopifyCheckout.configure { config in
            config.appearance = .app(.light())
            config.title = "Checkout"
            #if DEBUG
            config.logLevel = .debug
            #endif
        }
    }

    static func record(_ kind: String, store: String, checkout: Checkout) {
        var note = "id=\(checkout.id) status=\(checkout.status.rawValue) currency=\(checkout.currency)"
        note += " lines=" + checkout.lineItems.map { "\($0.item.id)×\($0.quantity) \($0.item.title)" }.joined(separator: "; ")
        if let order = checkout.order { note += " order=\(order.id) label=\(order.label ?? "-")" }
        CheckoutLog.record(kind, store: store, note: note)
        #if DEBUG
        guard let data = try? JSONEncoder().encode(checkout),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let folder = documents.appendingPathComponent("checkout-events", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(kind)-\(store).json"
        try? data.write(to: folder.appendingPathComponent(name))
        #endif
    }
}
