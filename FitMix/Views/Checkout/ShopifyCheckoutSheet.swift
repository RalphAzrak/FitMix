import EmbeddedCheckoutProtocol
import ShopifyCheckoutKit
import SwiftUI

/// A Shopify store's own checkout, opened from its prefilled cart permalink with Shopify Checkout Kit.
/// Used only for a `PrefilledCart` of kind `.shopifyCartPermalink`; every other store opens its pages
/// in `RetailerBrowser`. The store takes payment; FitMix only hears the lifecycle events.
struct ShopifyCheckoutSheet: View {
    let cart: PrefilledCart
    /// A verified order: Checkout Kit's completion event, as a receipt and variant → quantity bought.
    var onComplete: (CheckoutReceipt, [Int64: Int]) -> Void
    /// Checkout couldn't continue inside FitMix. The message is for the shopper.
    var onFail: (String) -> Void
    var onClose: () -> Void

    var body: some View {
        ShopifyCheckout(checkout: cart.url)
            .onStart { ShopifyCheckoutSetup.record("start", store: cart.store, checkout: $0.checkout) }
            .onUpdate { ShopifyCheckoutSetup.record("update", store: cart.store, checkout: $0.checkout) }
            .onComplete { complete($0) }
            .onFail { event in
                CheckoutLog.record("fail", store: cart.store, note: "code=\(event.error.code.rawValue) \(event.error.message)")
                onFail(event.error.localizedDescription)
            }
            // Links checkout hands outside the sheet (policies in Safari View, wallet or bank app deep
            // links through iOS). Default handling; logged so hand-offs out of FitMix are visible.
            .onLinkClick { link in
                CheckoutLog.record("link", store: cart.store, note: "url=\(link.url.absoluteString)")
                return .default
            }
            .onDismiss { onClose() }
            .ignoresSafeArea()
            .task { await runDebugClose() }
    }

    private func complete(_ event: CheckoutCompleteEvent) {
        ShopifyCheckoutSetup.record("complete", store: cart.store, checkout: event.checkout)
        let (receipt, purchased) = cart.receipt(from: event)
        onComplete(receipt, purchased)
    }

    /// Debug: `FM_DEBUG_CHECKOUT_CLOSE_AFTER` closes the sheet like the shopper would;
    /// `FM_DEBUG_CHECKOUT_SIMULATE_COMPLETE=1` instead feeds a **simulated** completion event.
    private func runDebugClose() async {
        guard let script = DebugCheckoutScript.current, script.closeAfter != nil || script.simulateComplete else { return }
        // A sheet's task is cancelled when the sheet closes; never act after that.
        do { try await Task.sleep(for: .seconds(script.closeAfter ?? 6)) } catch { return }
        if script.simulateComplete {
            // SIMULATED: no order exists. Built from the lines FitMix sent, to check the cart logic only.
            let lines = cart.lines.map { variant, quantity in
                LineItem(id: "simulated-\(variant)", item: Item(id: "gid://shopify/ProductVariant/\(variant)", price: 0, title: "Simulated line"),
                         quantity: quantity, totals: [])
            }
            complete(CheckoutCompleteEvent(checkout: Checkout(id: "simulated-\(cart.store)", status: .completed, currency: "CAD",
                                                              lineItems: lines, totals: [])))
        }
        onClose()
    }
}
