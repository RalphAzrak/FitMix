import Foundation

/// Debug builds only: drives the checkout proof of concept from launch arguments, because the
/// simulator can't be tapped from a script. Every step goes through the same code a tap would.
///
/// - `FM_DEBUG_CHECKOUT_FIXTURE=1`: Studio Fit's search returns `CheckoutFixtures` (two real stores,
///   one of them not Shopify, plus a listing with no link and one with an insecure link).
/// - `FM_DEBUG_CHECKOUT_CHOOSE=tshirt:<listing id>`: once that piece's results arrive, picks that listing
///   from its ranked list, exactly as tapping it in Studio's list does (`StudioStore.chooseListing`).
/// - `FM_DEBUG_CHECKOUT_PICKS=tshirt=Size:M*1;pants=Size:32X32*2;shoes=*1`: for each piece, in order, Shop
///   This Look adds it to the cart: through the variant picker for a Shopify listing (those options and
///   quantity), else with the plain Add to Cart button and that quantity.
/// - `FM_DEBUG_CHECKOUT_OPEN=frankandoak.com,uniqlo.com`: the cart then opens Checkout, and Checkout opens
///   each store in turn (its prefilled cart, else its first item that has a link).
/// - `FM_DEBUG_CHECKOUT_CLOSE_AFTER=<seconds>`: closes each store after a delay, like the shopper
///   tapping Done or closing checkout (checks the cart is kept).
/// - `FM_DEBUG_CHECKOUT_SIMULATE_COMPLETE=1`: instead of a real order, feeds a **simulated** completion
///   event, built from the lines FitMix sent, through the same completion handler. It proves only the
///   cart logic (which lines are cleared), never that Shopify created an order, and is labeled so.
/// - `FM_DEBUG_CHECKOUT_PREFILL=montreal`: pre-fills a public Montréal address in the permalink.
struct DebugCheckoutScript {
    struct Pick: Equatable {
        var options: [(String, String)]
        var quantity: Int
        static func == (a: Pick, b: Pick) -> Bool {
            a.quantity == b.quantity && a.options.map { "\($0.0)=\($0.1)" } == b.options.map { "\($0.0)=\($0.1)" }
        }
    }

    var picks: [GarmentCategory: Pick]
    var order: [GarmentCategory]
    var choices: [GarmentCategory: String]
    var openStores: [String]
    var closeAfter: Double?
    var simulateComplete: Bool

    static let current: DebugCheckoutScript? = {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["FM_DEBUG_CHECKOUT_PICKS"] else { return nil }
        var picks: [GarmentCategory: Pick] = [:]
        var order: [GarmentCategory] = []
        for entry in raw.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let category = GarmentCategory(rawValue: parts[0]) else { continue }
            let body = parts[1].split(separator: "*", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let options = body[0].split(separator: ",").compactMap { pair -> (String, String)? in
                let kv = pair.split(separator: ":", maxSplits: 1).map(String.init)
                return kv.count == 2 ? (kv[0], kv[1]) : nil
            }
            picks[category] = Pick(options: options, quantity: body.count > 1 ? Int(body[1]) ?? 1 : 1)
            order.append(category)
        }
        var choices: [GarmentCategory: String] = [:]
        for entry in (env["FM_DEBUG_CHECKOUT_CHOOSE"] ?? "").split(separator: ";") {
            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let category = GarmentCategory(rawValue: parts[0]) { choices[category] = parts[1] }
        }
        return DebugCheckoutScript(picks: picks, order: order, choices: choices,
                                   openStores: (env["FM_DEBUG_CHECKOUT_OPEN"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                                   closeAfter: env["FM_DEBUG_CHECKOUT_CLOSE_AFTER"].flatMap(Double.init),
                                   simulateComplete: env["FM_DEBUG_CHECKOUT_SIMULATE_COMPLETE"] == "1")
        #else
        return nil
        #endif
    }()
}
