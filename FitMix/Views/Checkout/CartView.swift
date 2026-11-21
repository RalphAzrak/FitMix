import EmbeddedCheckoutProtocol
import ShopifyCheckoutKit
import SwiftUI

/// The cart: pieces the user added from Shop This Look, with size and quantity, grouped by retailer.
/// Each Shopify store has its own checkout, opened inside FitMix with Shopify Checkout Kit. Closing a
/// checkout keeps the cart; completing one removes only what that store sold.
struct CartView: View {
    @Environment(CartStore.self) private var cart
    @Environment(\.dismiss) private var dismiss
    /// False when pushed inside another screen's navigation (Shop This Look), where Back is enough.
    var showsDone = true

    @State private var retailer: URL?
    @State private var failure: String?
    @State private var confirmClear = false
    /// The store checkout that's open.
    @State private var checkout: RetailerCheckout?
    /// Set by the completion event, so closing the sheet afterwards isn't reported as cancelled.
    @State private var completed: CheckoutReceipt?
    @State private var notice: (tone: NoticeRow.Tone, text: String)?

    var body: some View {
        Group {
            if let loadError = cart.loadError {
                unreadable(loadError)
            } else if cart.isEmpty {
                ScrollView {
                    ProfileEmptyState(icon: "bag", title: "Your cart is empty",
                                      message: "Scan an outfit, then add pieces from Shop This Look.")
                        .padding(16)
                }
            } else {
                list
            }
        }
        .background(AuthPalette.surface.ignoresSafeArea())
        .navigationTitle("Cart")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            if !cart.isEmpty && cart.loadError == nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) { confirmClear = true }
                        .accessibilityIdentifier("cartClear")
                }
            }
        }
        .sheet(item: $retailer) { SafariView(url: $0).ignoresSafeArea() }
        .sheet(item: $checkout, onDismiss: checkoutClosed) { checkout in
            ShopifyCheckout(checkout: checkout.url)
                .onStart { CheckoutLog.record("start", store: checkout.store, checkout: $0.checkout) }
                .onUpdate { CheckoutLog.record("update", store: checkout.store, checkout: $0.checkout) }
                .onComplete { complete(checkout, $0) }
                .onFail { event in
                    CheckoutLog.record("fail", store: checkout.store, note: "code=\(event.error.code.rawValue) \(event.error.message)")
                    notice = (.caution, "\(checkout.storeName) checkout couldn't continue: \(event.error.localizedDescription) Your cart is unchanged.")
                }
                // Links checkout hands outside the sheet (policies in Safari View, wallet or bank app deep
                // links through iOS). Default handling; logged so hand-offs out of FitMix are visible.
                .onLinkClick { link in
                    CheckoutLog.record("link", store: checkout.store, note: "url=\(link.url.absoluteString)")
                    return .default
                }
                .onDismiss { self.checkout = nil }
                .ignoresSafeArea()
                .task { await runDebugClose(checkout) }
        }
        .task { await runDebugOpen() }
        .confirmationDialog("Remove everything from your cart?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Cart", role: .destructive) { perform { try cart.removeAll() } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't update your cart", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    // MARK: States

    private func unreadable(_ message: String) -> some View {
        ScrollView {
            ProfileEmptyState(icon: "exclamationmark.triangle", title: "Couldn't load your cart", message: message) {
                Button("Clear Cart", role: .destructive) { perform { try cart.removeAll() } }
                    .buttonStyle(AuthPrimaryButtonStyle())
            }
            .padding(16)
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let notice { NoticeRow(tone: notice.tone, text: notice.text).accessibilityIdentifier("cartNotice") }
                ForEach(cart.receipts.prefix(3)) { receiptCard($0) }
                ForEach(cart.groups) { group in
                    FMSectionHeader(title: group.name) {
                        Text(group.count == 1 ? "1 item" : "\(group.count) items")
                            .font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
                    }
                    ForEach(group.items) { row($0) }
                    groupCheckout(group)
                }
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) { summary }
    }

    // MARK: Checkout

    @ViewBuilder
    private func groupCheckout(_ group: CartStore.RetailerGroup) -> some View {
        if let checkout = RetailerCheckout(group: group) {
            Button {
                notice = nil
                completed = nil
                CheckoutLog.record("open", store: checkout.store, note: "url=\(checkout.url.absoluteString)")
                self.checkout = checkout
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

    private func complete(_ checkout: RetailerCheckout, _ event: CheckoutCompleteEvent) {
        CheckoutLog.record("complete", store: checkout.store, checkout: event.checkout)
        let (receipt, purchased) = checkout.receipt(from: event)
        completed = receipt
        do {
            try cart.completeCheckout(store: checkout.store, purchased: purchased, order: receipt)
            CheckoutLog.record("cart-cleared", store: checkout.store,
                               note: "purchased=\(purchased) remaining=\(cart.items.map { "\($0.retailerKey):\($0.shopify?.variantID ?? 0)×\($0.quantity)" })")
        } catch {
            failure = error.localizedDescription
        }
    }

    /// The checkout sheet closed, by the shopper or after an order.
    private func checkoutClosed() {
        if let completed {
            if completed.checkoutID.hasPrefix("simulated-") {
                notice = (.info, "Simulated checkout for \(completed.storeName): no order was created. Those pieces were removed from your cart.")
            } else if completed.orderID != nil {
                notice = (.good, "Order placed with \(completed.storeName). Those pieces were removed from your cart.")
            } else {
                notice = (.good, "\(completed.storeName) checkout finished without an order number. Check your email from the store. Those pieces were removed from your cart.")
            }
        } else if notice == nil {
            notice = (.info, "Checkout closed. Nothing was bought, and your cart is unchanged.")
            CheckoutLog.record("closed-without-order", store: "-", note: "cart=\(cart.items.map { "\($0.retailerKey):\($0.shopify?.variantID ?? 0)×\($0.quantity)" })")
        }
    }

    private func receiptCard(_ receipt: CheckoutReceipt) -> some View {
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
                Button("View order status") { retailer = url }.font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.fmCobalt)
            }
        }
        .fmCard(padding: 14)
        .accessibilityIdentifier("cartReceipt-\(receipt.store)")
    }

    // MARK: Rows

    private func row(_ item: CartItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                GarmentTile(source: tileSource(for: item), category: item.category)
                    .frame(width: 64, height: 72)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.category.title.uppercased())
                            .font(.system(size: 10, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(AuthPalette.secondary)
                        if item.isFixture { TagPill(text: "Test fixture") }
                    }
                    Text(item.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AuthPalette.onSurface)
                        .lineLimit(2)
                    if let detail = [item.brand, item.retailer].compactMap({ $0 }).first {
                        Text(detail).font(.system(size: 13)).foregroundStyle(AuthPalette.secondary)
                    }
                    if let line = item.shopify {
                        Text(line.displayOptions.joined(separator: " · ") + (line.colourFixedByListing ? " · Colour as pictured" : ""))
                            .font(.system(size: 13)).foregroundStyle(AuthPalette.secondary)
                        Text("Variant " + String(line.variantID)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.fmOutline)
                    } else {
                        Text(item.size.map { "Size \($0)" } ?? "Size not listed")
                            .font(.system(size: 13)).foregroundStyle(AuthPalette.secondary)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(item.lineTotal?.formatted ?? "Price unavailable")
                        .font(.system(size: 14, weight: item.lineTotal == nil ? .regular : .bold))
                        .foregroundStyle(item.lineTotal == nil ? AuthPalette.secondary : AuthPalette.onSurface)
                    if item.quantity > 1, let unit = item.unitPrice {
                        Text("\(unit.formatted) each").font(.system(size: 11)).foregroundStyle(AuthPalette.secondary)
                    }
                }
            }
            HStack(spacing: 12) {
                quantityControl(item)
                Button {
                    perform { try cart.remove(id: item.id) }
                } label: {
                    Image(systemName: "trash").frame(width: 44, height: 44)
                }
                .foregroundStyle(Color.fmError)
                .accessibilityLabel("Remove \(item.name)")
                Spacer()
                if let url = item.retailerURL {
                    Button("View at retailer") { retailer = url }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AuthPalette.primary)
                        .frame(minHeight: 44)
                }
            }
        }
        .padding(12)
        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AuthPalette.containerHigh))
        .accessibilityIdentifier("cartRow-\(item.productID)")
    }

    private func quantityControl(_ item: CartItem) -> some View {
        HStack(spacing: 0) {
            Button {
                perform { try cart.setQuantity(item.quantity - 1, for: item.id) }
            } label: {
                Image(systemName: "minus").frame(width: 36, height: 36)
            }
            .disabled(item.quantity <= 1)
            .accessibilityLabel("Decrease quantity")
            Text("\(item.quantity)")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .frame(minWidth: 24)
                .accessibilityHidden(true)
            Button {
                perform { try cart.setQuantity(item.quantity + 1, for: item.id) }
            } label: {
                Image(systemName: "plus").frame(width: 36, height: 36)
            }
            .disabled(item.quantity >= CartStore.maxQuantity)
            .accessibilityLabel("Increase quantity")
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(AuthPalette.onSurface)
        .background(AuthPalette.container, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quantity \(item.quantity)")
    }

    private func tileSource(for item: CartItem) -> GarmentTile.Source {
        if let image = cart.localImage(for: item) { return .image(image) }
        if let url = item.imageURL { return .remote(url) }
        return .none
    }

    // MARK: Summary

    private var summary: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(cart.count == 1 ? "1 item" : "\(cart.count) items")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                subtotalText
            }
            Text(cart.groups.count > 1
                 ? "Each store checks out separately. Shipping and tax are added by each store."
                 : "Shipping and tax will be added at checkout.")
                .font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(AuthPalette.surface)
        .overlay(alignment: .top) { Rectangle().fill(AuthPalette.containerHigh).frame(height: 1) }
    }

    @ViewBuilder
    private var subtotalText: some View {
        if cart.hasMixedCurrencies {
            Text("Prices in several currencies").font(.system(size: 13)).foregroundStyle(AuthPalette.secondary)
        } else if let subtotal = cart.subtotal {
            VStack(alignment: .trailing, spacing: 1) {
                Text(subtotal.price.formatted).font(.system(size: 17, weight: .bold)).foregroundStyle(AuthPalette.onSurface)
                if subtotal.pricedCount < cart.items.count {
                    Text("for \(subtotal.pricedCount) of \(cart.items.count) pieces")
                        .font(.system(size: 11)).foregroundStyle(AuthPalette.secondary)
                }
            }
        } else {
            Text("Prices unavailable").font(.system(size: 13)).foregroundStyle(AuthPalette.secondary)
        }
    }

    // MARK: Debug

    private func runDebugOpen() async {
        guard let script = DebugCheckoutScript.current, let store = script.openStore else { return }
        try? await Task.sleep(for: .seconds(1.5))
        guard let group = cart.groups.first(where: { $0.id == store }), let checkout = RetailerCheckout(group: group) else {
            CheckoutLog.record("debug-open-failed", store: store, note: "groups=\(cart.groups.map(\.id))")
            return
        }
        CheckoutLog.record("open", store: checkout.store, note: "url=\(checkout.url.absoluteString)")
        self.checkout = checkout
    }

    private func runDebugClose(_ open: RetailerCheckout) async {
        guard let script = DebugCheckoutScript.current else { return }
        // A sheet's task is cancelled when the sheet closes; never act after that.
        do { try await Task.sleep(for: .seconds(script.closeAfter ?? 6)) } catch { return }
        if script.simulateComplete {
            // SIMULATED: no order exists. Built from the lines FitMix sent, to check the cart logic only.
            let lines = open.lines.map { variant, quantity in
                LineItem(id: "simulated-\(variant)", item: Item(id: "gid://shopify/ProductVariant/\(variant)", price: 0, title: "Simulated line"),
                         quantity: quantity, totals: [])
            }
            let checkout = Checkout(id: "simulated-\(open.store)", status: .completed, currency: "CAD", lineItems: lines, totals: [])
            complete(open, CheckoutCompleteEvent(checkout: checkout))
            self.checkout = nil
        } else if script.closeAfter != nil {
            self.checkout = nil
        }
    }

    private func perform(_ change: () throws -> Void) {
        do { try change() } catch { failure = error.localizedDescription }
    }
}
