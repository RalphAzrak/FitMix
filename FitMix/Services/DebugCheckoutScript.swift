import Foundation

/// Debug builds only: drives the checkout proof of concept from launch arguments, because the
/// simulator can't be tapped from a script. Every step goes through the same code a tap would.
///
/// - `FM_DEBUG_CHECKOUT_PICKS=tshirt=Size:M*1;pants=Size:32X32*2`: for each piece, in order, Shop This
///   Look opens the variant picker, applies those options and quantity, and adds it to the cart.
/// - `FM_DEBUG_CHECKOUT_OPEN=<store domain>`: the cart then opens that store's checkout.
/// - `FM_DEBUG_CHECKOUT_CLOSE_AFTER=<seconds>`: closes that checkout after a delay, like the shopper
///   closing it (checks the cart is kept).
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
    var openStore: String?
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
            let body = parts[1].split(separator: "*", maxSplits: 1).map(String.init)
            let options = body[0].split(separator: ",").compactMap { pair -> (String, String)? in
                let kv = pair.split(separator: ":", maxSplits: 1).map(String.init)
                return kv.count == 2 ? (kv[0], kv[1]) : nil
            }
            picks[category] = Pick(options: options, quantity: body.count > 1 ? Int(body[1]) ?? 1 : 1)
            order.append(category)
        }
        return DebugCheckoutScript(picks: picks, order: order, openStore: env["FM_DEBUG_CHECKOUT_OPEN"],
                                   closeAfter: env["FM_DEBUG_CHECKOUT_CLOSE_AFTER"].flatMap(Double.init),
                                   simulateComplete: env["FM_DEBUG_CHECKOUT_SIMULATE_COMPLETE"] == "1")
        #else
        return nil
        #endif
    }()
}
