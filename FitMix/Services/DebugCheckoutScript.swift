import Foundation

/// Debug builds only: drives cart and checkout from launch arguments, because the simulator can't be
/// tapped from a script. Every step goes through the same code a tap would.
///
/// - `FM_DEBUG_CHECKOUT_PICKS=tshirt=Size:M*1;pants=Size:32X32*2`: for each piece, in order, Shop This
///   Look opens the variant picker, applies those options and quantity, and adds it to the cart.
/// - `FM_DEBUG_CART_SEED=multistore|twostores`: replaces the cart with `DemoCheckoutFixtures` (four stores in
///   two currencies with one piece without a price, or Kotn and Uniqlo) without going through Studio.
/// - `FM_DEBUG_CHECKOUT_PLACE=1`: once the cart is open, taps Checkout, Continue to Payment, then Simulate
///   Payment three times in a row (only one order may be saved).
/// - `FM_DEBUG_ORDER_SAVE_FAIL=1`: the first demo-order save fails (the cart must stay intact).
/// - `FM_DEBUG_OPEN_ORDER=latest`: opens the newest saved demo order's summary at launch.
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
    var seed: String?
    var placeOrder: Bool

    static let current: DebugCheckoutScript? = {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        let seed = env["FM_DEBUG_CART_SEED"]
        let placeOrder = env["FM_DEBUG_CHECKOUT_PLACE"] == "1"
        guard env["FM_DEBUG_CHECKOUT_PICKS"] != nil || seed != nil || placeOrder else { return nil }
        var picks: [GarmentCategory: Pick] = [:]
        var order: [GarmentCategory] = []
        for entry in (env["FM_DEBUG_CHECKOUT_PICKS"] ?? "").split(separator: ";") {
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
        return DebugCheckoutScript(picks: picks, order: order, seed: seed, placeOrder: placeOrder)
        #else
        return nil
        #endif
    }()
}
