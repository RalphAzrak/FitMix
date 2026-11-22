import SwiftUI

/// FitMix's own checkout for the whole cart, every store at once. It is a demo: it runs entirely on the
/// iPhone, works offline, asks for no payment details, and sends nothing to any store or server.
/// **Place Demo Order** saves the order on the device first, then removes those lines from the cart,
/// and shows the confirmation.
struct CheckoutView: View {
    @Environment(CartStore.self) private var cart
    @Environment(DemoOrderStore.self) private var orders

    /// The order this screen just placed; the screen then shows its confirmation.
    @State private var placedID: UUID?
    @State private var placing = false
    @State private var failure: String?
    /// The order saved, but the cart couldn't be updated afterwards.
    @State private var cartWarning: String?

    var body: some View {
        Group {
            if let placedID, let order = orders.order(id: placedID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let cartWarning { NoticeRow(tone: .caution, text: cartWarning) }
                        DemoOrderSummary(order: order, headline: "Demo order placed")
                    }
                    .padding(16)
                }
            } else if cart.isEmpty {
                ScrollView {
                    ProfileEmptyState(icon: "bag", title: "Nothing to check out", message: "Your cart is empty.").padding(16)
                }
            } else {
                review
            }
        }
        .background(Color.fmBackground.ignoresSafeArea())
        .navigationTitle(placedID == nil ? "Checkout" : "Order")
        .navigationBarTitleDisplayMode(.inline)
        .task { await runDebugPlace() }
        .alert("Couldn't place the demo order", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure ?? "") }
    }

    // MARK: Review

    private var review: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                NoticeRow(tone: .info, text: "Demo checkout. Everything in your cart is ordered together, here in FitMix. No payment details are needed, nothing is charged, and no store receives this order.")
                    .accessibilityIdentifier("checkoutDemoNotice")
                ForEach(cart.groups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Eyebrow(text: group.name, color: .fmInk)
                            Spacer()
                            Text(group.count == 1 ? "1 item" : "\(group.count) items").font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
                        }
                        ForEach(group.items) { OrderLineRow(item: $0, image: cart.localImage(for: $0)) }
                    }
                    .fmCard(padding: 14)
                    .accessibilityIdentifier("checkoutStore-\(group.id)")
                }
                CurrencyTotalsCard(totals: cart.totals, unpriced: cart.unpricedPieces, pieces: cart.count, stores: cart.groups.count)
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button(action: place) {
                    if placing { ProgressView().tint(.white) } else { Label("Place Demo Order", systemImage: "checkmark.seal") }
                }
                .buttonStyle(FMFilledButtonStyle())
                .disabled(placing || cart.loadError != nil)
                .accessibilityIdentifier("checkoutPlaceDemoOrder")
                Text("Saved on this iPhone only. Prices are the listed prices; nothing is paid.")
                    .font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
            }
            .padding(16)
            .background(Color.fmBackground)
            .overlay(alignment: .top) { Rectangle().fill(Color.fmHairline).frame(height: 1) }
        }
    }

    /// Saves the order first; only once it's on disk are those exact lines removed from the cart.
    private func place() {
        guard !placing else { return }
        placing = true
        defer { placing = false }
        let items = cart.items
        let order: DemoOrder
        do {
            order = try orders.place(items)
        } catch {
            CheckoutLog.record("demo-order-failed", store: "-", note: error.localizedDescription)
            failure = error.localizedDescription
            return
        }
        CheckoutLog.record("demo-order-saved", store: "-", note: "number=\(order.number) lines=\(order.items.count) pieces=\(order.items.reduce(0) { $0 + $1.quantity }) stores=\(Set(order.items.map(\.retailerKey)).count) totals=\(CartItem.totals(of: order.items).map(\.price.formatted)) file=\(orders.fileURL.path)")
        do {
            try cart.remove(ids: Set(items.map(\.id)))
        } catch {
            cartWarning = "Your demo order was saved, but FitMix couldn't remove those pieces from your cart: \(error.localizedDescription)"
        }
        CheckoutLog.record("cart-after-order", store: "-", note: "items=\(cart.items.count)")
        placedID = order.id
    }

    /// Debug: `FM_DEBUG_CHECKOUT_PLACE=1` taps Place Demo Order once the screen is up.
    private func runDebugPlace() async {
        guard DebugCheckoutScript.current?.placeOrder == true, placedID == nil, !cart.isEmpty else { return }
        try? await Task.sleep(for: .seconds(2))
        place()
    }
}

// MARK: - Shared pieces

/// One line as it's ordered: photo, title, store, variant, quantity, listed price.
struct OrderLineRow: View {
    var item: CartItem
    var image: UIImage? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            GarmentTile(source: image.map { .image($0) } ?? item.imageURL.map { .remote($0) } ?? .none, category: item.category)
                .frame(width: 44, height: 50)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.fmInk).lineLimit(2)
                    if item.isFixture { TagPill(text: "Test fixture") }
                }
                Text(item.retailer ?? "Store not listed").font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
                Text("\(variant) · Qty \(item.quantity)").font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text(item.lineTotal?.formatted ?? "No price").font(.system(size: 14, weight: item.lineTotal == nil ? .regular : .bold))
                    .foregroundStyle(item.lineTotal == nil ? Color.fmSecondary : Color.fmInk)
                if item.quantity > 1, let unit = item.unitPrice {
                    Text("\(unit.formatted) each").font(.system(size: 11)).foregroundStyle(Color.fmSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var variant: String {
        if let line = item.shopify {
            return (line.displayOptions + (line.colourFixedByListing ? ["Colour as pictured"] : [])).joined(separator: " · ")
        }
        return item.size.map { "Size \($0)" } ?? "Size not listed"
    }
}

/// Totals per currency, never converted or added across currencies.
struct CurrencyTotalsCard: View {
    var totals: [CurrencyTotal]
    var unpriced: Int
    var pieces: Int
    var stores: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow(text: totals.count > 1 ? "Totals by currency" : "Total", color: .fmInk)
                Spacer()
                Text("\(pieces == 1 ? "1 item" : "\(pieces) items") · \(stores == 1 ? "1 store" : "\(stores) stores")")
                    .font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
            }
            if totals.isEmpty {
                Text("No listed prices").font(.system(size: 15)).foregroundStyle(Color.fmSecondary)
            }
            ForEach(totals, id: \.price.currencyCode) { total in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(total.price.currencyCode) · \(total.pieces == 1 ? "1 item" : "\(total.pieces) items")")
                        .font(.system(size: 14)).foregroundStyle(Color.fmSecondary)
                    Spacer()
                    Text(total.price.formatted).font(.fmDisplay(22)).foregroundStyle(Color.fmInk)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("total-\(total.price.currencyCode)")
            }
            if unpriced > 0 {
                Text(unpriced == 1 ? "1 item has no listed price and isn't in a total." : "\(unpriced) items have no listed price and aren't in a total.")
                    .font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
            }
        }
        .fmCard(padding: 14)
    }
}

/// A placed demo order: number, date, every line, totals per currency.
struct DemoOrderSummary: View {
    var order: DemoOrder
    var headline: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 34)).foregroundStyle(Color.fmGreen)
                Text(headline).font(.fmDisplay(28)).foregroundStyle(Color.fmInk)
                    .accessibilityIdentifier("demoOrderHeadline")
                Text("Order \(order.number)").font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .accessibilityIdentifier("demoOrderNumber")
                Text(order.placedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
                Text("A demo order saved on this iPhone. Nothing was paid, and no store received it.")
                    .font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: "Items", color: .fmInk)
                ForEach(order.items) { OrderLineRow(item: $0) }
            }
            .fmCard(padding: 14)
            CurrencyTotalsCard(totals: CartItem.totals(of: order.items), unpriced: CartItem.unpricedPieces(in: order.items),
                               pieces: order.items.reduce(0) { $0 + $1.quantity },
                               stores: Set(order.items.map(\.retailerKey)).count)
        }
    }
}

/// A saved demo order, opened from the cart.
struct DemoOrderView: View {
    var order: DemoOrder

    var body: some View {
        ScrollView { DemoOrderSummary(order: order, headline: "Demo order placed").padding(16) }
            .background(Color.fmBackground.ignoresSafeArea())
            .navigationTitle("Order")
            .navigationBarTitleDisplayMode(.inline)
    }
}
