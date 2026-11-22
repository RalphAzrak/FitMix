import EmbeddedCheckoutProtocol
import ShopifyCheckoutKit
import SwiftUI

// MARK: - Shopify store checkout (outside demo mode)
//
// With `CheckoutMode.shopify`, the cart has no single Checkout button: each Shopify store gets its own
// checkout inside FitMix with Shopify Checkout Kit. Closing a checkout keeps the cart; completing one
// removes only what that store sold. Stores whose lines aren't exact Shopify variants can't be checked
// out this way. The demo checkout (`CheckoutFlowView`) is the build's default in Debug.

/// The state behind the per-store checkouts: the open sheet, the last result, receipts.
@Observable
final class ShopifyStoreCheckoutState {
    /// The store checkout that's open.
    var checkout: RetailerCheckout?
    /// Set by the completion event, so closing the sheet afterwards isn't reported as cancelled.
    var completed: CheckoutReceipt?
    var notice: (tone: NoticeRow.Tone, text: String)?
    var failure: String?
    var orderStatus: URL?
}

/// "Checkout at <store>" under a store's lines, or why that store can't be checked out in FitMix.
struct ShopifyGroupCheckoutButton: View {
    var group: CartStore.RetailerGroup
    @Bindable var state: ShopifyStoreCheckoutState

    var body: some View {
        if let checkout = RetailerCheckout(group: group) {
            Button {
                state.notice = nil
                state.completed = nil
                CheckoutLog.record("open", store: checkout.store, note: "url=\(checkout.url.absoluteString)")
                state.checkout = checkout
            } label: {
                Label("Checkout at \(group.name)", systemImage: "lock")
            }
            .buttonStyle(FMFilledButtonStyle())
            .accessibilityIdentifier("cartCheckout-\(group.id)")
            .padding(.bottom, 8)
        } else {
            Text("\(group.name) can't be checked out in FitMix yet. Use View at retailer to buy these pieces.")
                .font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                .padding(.bottom, 8)
        }
    }
}

/// Notices and receipts from store checkouts, shown above the cart's lines.
struct ShopifyCheckoutReceipts: View {
    @Environment(CartStore.self) private var cart
    @Bindable var state: ShopifyStoreCheckoutState

    var body: some View {
        if let notice = state.notice { NoticeRow(tone: notice.tone, text: notice.text).accessibilityIdentifier("cartNotice") }
        ForEach(cart.receipts.prefix(3)) { receipt in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Eyebrow(text: receipt.orderID == nil ? "Checkout complete · simulated" : "Order placed", color: .fmGreen)
                    Spacer()
                    Text(receipt.storeName).font(.system(size: 13, weight: .semibold))
                }
                Text(receipt.orderLabel.map { "Order \($0)" } ?? (receipt.orderID == nil ? "No order was created (debug simulation)" : "Order confirmed"))
                    .font(.fmDisplay(18))
                ForEach(Array(receipt.lines.enumerated()), id: \.offset) { _, line in
                    Text("\(line.quantity) × \(line.title)\(line.variantID.map { " · variant " + String($0) } ?? "")")
                        .font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
                }
                if let url = receipt.orderURL {
                    Button("View order status") { state.orderStatus = url }
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.fmCobalt)
                }
            }
            .fmCard(padding: 14)
            .accessibilityIdentifier("cartReceipt-\(receipt.store)")
        }
    }
}

extension View {
    /// Presents the open store checkout (Shopify Checkout Kit) and applies its result to the cart.
    func shopifyStoreCheckout(_ state: ShopifyStoreCheckoutState, cart: CartStore) -> some View {
        modifier(ShopifyStoreCheckoutSheet(state: state, cart: cart))
    }
}

private struct ShopifyStoreCheckoutSheet: ViewModifier {
    @Bindable var state: ShopifyStoreCheckoutState
    var cart: CartStore

    func body(content: Content) -> some View {
        content
            .sheet(item: $state.orderStatus) { SafariView(url: $0).ignoresSafeArea() }
            .sheet(item: $state.checkout, onDismiss: closed) { checkout in
                ShopifyCheckout(checkout: checkout.url)
                    .onStart { CheckoutLog.record("start", store: checkout.store, checkout: $0.checkout) }
                    .onUpdate { CheckoutLog.record("update", store: checkout.store, checkout: $0.checkout) }
                    .onComplete { complete(checkout, $0) }
                    .onFail { event in
                        CheckoutLog.record("fail", store: checkout.store, note: "code=\(event.error.code.rawValue) \(event.error.message)")
                        state.notice = (.caution, "\(checkout.storeName) checkout couldn't continue: \(event.error.localizedDescription) Your cart is unchanged.")
                    }
                    // Links checkout hands outside the sheet: default handling, logged so hand-offs are visible.
                    .onLinkClick { link in
                        CheckoutLog.record("link", store: checkout.store, note: "url=\(link.url.absoluteString)")
                        return .default
                    }
                    .onDismiss { state.checkout = nil }
                    .ignoresSafeArea()
            }
            .alert("Couldn't update your cart", isPresented: Binding(get: { state.failure != nil }, set: { if !$0 { state.failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(state.failure ?? "")
            }
    }

    private func complete(_ checkout: RetailerCheckout, _ event: CheckoutCompleteEvent) {
        CheckoutLog.record("complete", store: checkout.store, checkout: event.checkout)
        let (receipt, purchased) = checkout.receipt(from: event)
        state.completed = receipt
        do {
            try cart.completeCheckout(store: checkout.store, purchased: purchased, order: receipt)
        } catch {
            state.failure = error.localizedDescription
        }
    }

    /// The checkout sheet closed, by the shopper or after an order.
    private func closed() {
        if let completed = state.completed {
            if completed.checkoutID.hasPrefix("simulated-") {
                state.notice = (.info, "Simulated checkout for \(completed.storeName): no order was created. Those pieces were removed from your cart.")
            } else if completed.orderID != nil {
                state.notice = (.good, "Order placed with \(completed.storeName). Those pieces were removed from your cart.")
            } else {
                state.notice = (.good, "\(completed.storeName) checkout finished without an order number. Check your email from the store. Those pieces were removed from your cart.")
            }
        } else if state.notice == nil {
            state.notice = (.info, "Checkout closed. Nothing was bought, and your cart is unchanged.")
        }
    }
}
