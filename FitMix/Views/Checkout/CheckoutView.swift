import SwiftUI

// MARK: - The demo checkout flow
//
// Cart → Order Review → Demo Payment → Order Summary, as full-screen pushes in one navigation stack
// (`CheckoutFlowView`). The bag icon and Shop This Look's "View Cart" both open this same flow. The
// cart's Checkout button starts it in demo mode (`CheckoutMode.demo`).
//
// It is a demo: it runs entirely on the iPhone, works offline, never asks for card details, charges
// nothing, contacts no payment provider, Shopify or store, and places no retailer order. It works for
// any cart line: no Shopify variant, supported store, retailer checkout URL or fresh search is needed.
// "Pay Demo Order" approves locally, saves one `DemoOrder`, and only then removes those lines from the
// cart. See Docs/Checkout.md.

/// A step pushed on top of the cart.
enum CheckoutRoute: Hashable {
    case checkout
    case payment
    /// A saved demo order. `justPlaced`: Payment just placed it, so Back is hidden and Done closes the flow.
    case summary(UUID, justPlaced: Bool)
}

/// Drives the flow's navigation. Shared through the environment so each step can push the next.
@Observable
final class CheckoutNavigator {
    var path: [CheckoutRoute]
    @ObservationIgnored var close: () -> Void = {}

    init(path: [CheckoutRoute] = []) { self.path = path }
}

/// The whole flow, full screen. Cart is the root; the other steps are pushed.
struct CheckoutFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var navigator: CheckoutNavigator

    init(startingAt path: [CheckoutRoute] = []) {
        _navigator = State(initialValue: CheckoutNavigator(path: path))
    }

    var body: some View {
        @Bindable var navigator = navigator
        NavigationStack(path: $navigator.path) {
            CartView()
                .navigationDestination(for: CheckoutRoute.self) { route in
                    switch route {
                    case .checkout: CheckoutView()
                    case .payment: PaymentView()
                    case .summary(let id, let justPlaced): OrderSummaryView(orderID: id, justPlaced: justPlaced)
                    }
                }
        }
        .environment(navigator)
        .onAppear { navigator.close = { dismiss() } }
    }
}

// MARK: - Checkout

/// Order Review: every cart line, grouped by store, with totals per currency. Continue to Payment goes on.
struct CheckoutView: View {
    @Environment(CartStore.self) private var cart
    @Environment(CheckoutNavigator.self) private var navigator

    var body: some View {
        Group {
            if cart.isEmpty {
                ScrollView {
                    ProfileEmptyState(icon: "bag", title: "Nothing to check out", message: "Your cart is empty.").padding(16)
                }
            } else {
                review
            }
        }
        .background(Color.fmBackground.ignoresSafeArea())
        .navigationTitle("Order Review")
        .navigationBarTitleDisplayMode(.inline)
        .task { await runDebugStep() }
    }

    private var review: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                NoticeRow(tone: .info, text: "Demo checkout. Everything in your cart is ordered together, from every store, here in FitMix. Nothing is charged and no store receives this order.")
                    .accessibilityIdentifier("checkoutDemoNotice")
                StoreGroupsList(groups: cart.groups, image: cart.localImage(for:))
                CurrencyTotalsCard(totals: cart.totals, unpriced: cart.unpricedPieces, pieces: cart.count, stores: cart.groups.count)
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) {
            BottomBar {
                Button { navigator.path.append(.payment) } label: {
                    Label("Continue to Payment", systemImage: "arrow.right")
                }
                .buttonStyle(FMFilledButtonStyle())
                .disabled(cart.loadError != nil)
                .accessibilityIdentifier("checkoutContinueToPayment")
            }
        }
    }

    /// Debug: `FM_DEBUG_CHECKOUT_PLACE=1` continues to Payment once the screen is up.
    private func runDebugStep() async {
        guard DebugCheckoutScript.current?.placeOrder == true, !cart.isEmpty, navigator.path.last == .checkout else { return }
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        CheckoutLog.record("debug-continue-to-payment", store: "-")
        navigator.path.append(.payment)
    }
}

// MARK: - Payment

/// Demo Payment: a preset, labelled demo payment method, sample contact and delivery details, and one
/// Pay Demo Order button that approves locally. Never collects card details, never calls Shopify or a
/// payment provider, never places a retailer order.
struct PaymentView: View {
    @Environment(CartStore.self) private var cart
    @Environment(DemoOrderStore.self) private var orders
    @Environment(CheckoutNavigator.self) private var navigator

    /// This visit to Payment. Saving twice with the same ID returns the first order instead of a second.
    @State private var checkoutID = UUID()
    @State private var paying = false
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                demoModeBanner
                demoCard
                sampleDetails
                CurrencyTotalsCard(totals: cart.totals, unpriced: cart.unpricedPieces, pieces: cart.count, stores: cart.groups.count)
                Text("Pay Demo Order approves this order on your iPhone. No card details are collected, no money is charged, and no payment provider, Shopify or store is contacted.")
                    .font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .background(Color.fmBackground.ignoresSafeArea())
        .navigationTitle("Demo Payment")
        .navigationBarTitleDisplayMode(.inline)
        // While the order is saving, there's no going back to change the cart under it.
        .navigationBarBackButtonHidden(paying)
        .safeAreaInset(edge: .bottom) {
            BottomBar {
                Button(action: pay) {
                    if paying {
                        HStack(spacing: 8) { ProgressView().tint(.white); Text("Approving…") }
                    } else {
                        Label("Pay Demo Order", systemImage: "checkmark.shield")
                    }
                }
                .buttonStyle(FMFilledButtonStyle())
                .disabled(paying || cart.isEmpty || cart.loadError != nil)
                .accessibilityIdentifier("paymentPayDemoOrder")
            }
        }
        .task { await runDebugPay() }
        .alert("Couldn't place the demo order", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("Try Again") { pay() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(failure ?? "") }
    }

    private var demoModeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "testtube.2").font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Demo mode").font(.system(size: 15, weight: .bold))
                Text("This payment is simulated. Nothing is charged.").font(.system(size: 13))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.fmInk)
        .padding(12)
        .background(Color.fmLime.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.fmInk.opacity(0.15)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("paymentDemoMode")
    }

    /// The preset demo card. It's a label, not a form: there is nothing to type and nothing is stored.
    private var demoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Pay with", color: .fmInk)
            HStack(spacing: 12) {
                Image(systemName: "creditcard.fill").font(.system(size: 22)).foregroundStyle(Color.fmCobalt)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Demo card •••• 4242").font(.system(size: 16, weight: .semibold).monospacedDigit()).foregroundStyle(Color.fmInk)
                    Text("Preset for the demo. Not a real card.").font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.fmCobalt)
            }
        }
        .fmCard(padding: 14)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("paymentDemoCard")
    }

    /// Sample contact and delivery details, so the page reads like a checkout. Fixed text, not the
    /// account's: nothing here is typed, saved or sent.
    private var sampleDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow(text: "Contact & delivery", color: .fmInk)
                Spacer()
                TagPill(text: "Sample")
            }
            ForEach(DemoOrder.sampleDetails, id: \.self) { line in
                Text(line).font(.system(size: 14)).foregroundStyle(Color.fmInk)
            }
            Text("Sample details for the demo. Nothing ships.").font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
        }
        .fmCard(padding: 14)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("paymentSampleDetails")
    }

    /// Approves locally, saves the order, and only once it's saved removes those exact lines from the cart.
    private func pay() {
        guard !paying else {
            CheckoutLog.record("payment-tap-ignored", store: "-", note: "reason=already_saving")
            return
        }
        paying = true
        let items = cart.items
        let checkoutID = checkoutID
        CheckoutLog.record("payment-simulate", store: "-", note: "checkout=\(checkoutID.uuidString.prefix(8)) lines=\(items.count)")
        Task {
            // A short pause so "Approving…" is visible, like a real authorization. Nothing leaves the phone.
            try? await Task.sleep(for: .milliseconds(900))
            let order: DemoOrder
            do {
                order = try orders.place(items, checkoutID: checkoutID)
            } catch {
                CheckoutLog.record("demo-order-failed", store: "-", note: error.localizedDescription)
                failure = error.localizedDescription  // cart untouched; Try Again saves with the same checkout ID
                paying = false
                return
            }
            CheckoutLog.record("demo-order-saved", store: "-", note: "number=\(order.number) lines=\(order.items.count) pieces=\(order.pieces) stores=\(Set(order.items.map(\.retailerKey)).count) totals=\(order.savedTotals.map(\.price.formatted)) file=\(orders.fileURL.path)")
            var cartWarning: String?
            do {
                try cart.remove(ids: Set(items.map(\.id)))
            } catch {
                cartWarning = error.localizedDescription
            }
            CheckoutLog.record("cart-after-order", store: "-", note: "items=\(cart.items.count) orders=\(orders.orders.count)\(cartWarning.map { " warning=\($0)" } ?? "")")
            // Replaces the stack: Order Summary, with nothing payable behind it.
            navigator.path = [.summary(order.id, justPlaced: true)]
        }
    }

    /// Debug: `FM_DEBUG_CHECKOUT_PLACE=1` taps Pay Demo Order, then taps it again right away (and once more
    /// while saving), as an impatient shopper would. Only one order may be saved.
    private func runDebugPay() async {
        guard DebugCheckoutScript.current?.placeOrder == true, !cart.isEmpty else { return }
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        pay()
        pay()
        try? await Task.sleep(for: .milliseconds(300))
        pay()
    }
}

// MARK: - Order Summary

/// A saved demo order. Right after payment it replaces the whole flow: no Back to a payable screen, and
/// Done closes the flow. From "Demo orders" in the cart it opens like any other page.
struct OrderSummaryView: View {
    var orderID: UUID
    var justPlaced: Bool

    @Environment(DemoOrderStore.self) private var orders
    @Environment(CheckoutNavigator.self) private var navigator

    var body: some View {
        Group {
            if let order = orders.order(id: orderID) {
                ScrollView { DemoOrderSummary(order: order).padding(16) }
            } else {
                ScrollView {
                    ProfileEmptyState(icon: "questionmark.folder", title: "Order not found",
                                      message: "This demo order isn't saved on this iPhone for this account.").padding(16)
                }
            }
        }
        .background(Color.fmBackground.ignoresSafeArea())
        .navigationTitle("Order Summary")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(justPlaced)
        .safeAreaInset(edge: .bottom) {
            if justPlaced {
                BottomBar {
                    Button("Done") { navigator.close() }
                        .buttonStyle(FMFilledButtonStyle())
                        .accessibilityIdentifier("orderSummaryDoneButton")
                }
            }
        }
    }
}

// MARK: - Shared pieces

/// A label and its value on one line of the order summary.
struct SummaryRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.fmInk)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A bottom action bar above the safe area.
struct BottomBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 8) { content }
            .padding(16)
            .background(Color.fmBackground)
            .overlay(alignment: .top) { Rectangle().fill(Color.fmHairline).frame(height: 1) }
    }
}

/// Lines grouped by store, one card per store.
struct StoreGroupsList: View {
    var groups: [CartStore.RetailerGroup]
    var image: (CartItem) -> UIImage? = { _ in nil }

    var body: some View {
        ForEach(groups) { group in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Eyebrow(text: group.name, color: .fmInk)
                    Spacer()
                    Text(group.count == 1 ? "1 item" : "\(group.count) items").font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
                }
                ForEach(group.items) { OrderLineRow(item: $0, image: image($0)) }
            }
            .fmCard(padding: 14)
            .accessibilityIdentifier("store-\(group.id)")
        }
    }
}

/// One line as it's ordered: photo, title, size or variant, quantity, listed price.
struct OrderLineRow: View {
    var item: CartItem
    var image: UIImage? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            GarmentTile(source: image.map { .image($0) } ?? item.imageURL.map { .remote($0) } ?? .none, category: item.category)
                .frame(width: 52, height: 60)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.fmInk).lineLimit(2)
                    if item.isFixture { TagPill(text: "Test fixture") }
                }
                Text(variant).font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
                Text("Qty \(item.quantity)").font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text(item.lineTotal?.formatted ?? "Price unavailable")
                    .font(.system(size: 14, weight: item.lineTotal == nil ? .regular : .bold))
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

/// Totals per currency, never converted or added across currencies. Pieces without a price are named,
/// never counted as zero.
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
                Text("Prices unavailable").font(.system(size: 15)).foregroundStyle(Color.fmSecondary)
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
            if totals.count > 1 {
                Text("Each currency is totaled on its own. Nothing is converted.")
                    .font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
            }
            if unpriced > 0 {
                HStack(alignment: .firstTextBaseline) {
                    Text(unpriced == 1 ? "1 item · Price unavailable" : "\(unpriced) items · Price unavailable")
                        .font(.system(size: 14)).foregroundStyle(Color.fmSecondary)
                    Spacer()
                    Text("Not in any total").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.fmSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("total-unpriced")
            }
        }
        .fmCard(padding: 14)
    }
}

/// A placed demo order: headline, number, time, items by store, totals per currency.
struct DemoOrderSummary: View {
    var order: DemoOrder

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 34)).foregroundStyle(Color.fmGreen)
                Text("Demo order placed").font(.fmDisplay(28)).foregroundStyle(Color.fmInk)
                    .accessibilityIdentifier("demoOrderHeadline")
                Text("Order \(order.number)").font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .accessibilityIdentifier("demoOrderNumber")
                Text("Nothing was charged, and no store received this order.")
                    .font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                SummaryRow(label: "Order number", value: order.number)
                SummaryRow(label: "Date", value: order.placedAt.formatted(date: .abbreviated, time: .shortened))
                SummaryRow(label: "Payment", value: "Approved · Demo card •••• 4242 (demo, not charged)")
                    .accessibilityIdentifier("demoOrderPaymentStatus")
                SummaryRow(label: order.retailers.count == 1 ? "Retailer" : "Retailers", value: order.retailers.joined(separator: ", "))
                    .accessibilityIdentifier("demoOrderRetailers")
            }
            .fmCard(padding: 14)
            StoreGroupsList(groups: CartStore.groups(of: order.items))
            CurrencyTotalsCard(totals: order.savedTotals, unpriced: order.savedUnpricedPieces, pieces: order.pieces,
                               stores: Set(order.items.map(\.retailerKey)).count)
        }
    }
}
