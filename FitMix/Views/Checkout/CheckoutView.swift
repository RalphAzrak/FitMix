import SwiftUI

/// Checkout for a cart that can span several stores. Each store gets one card:
///
/// - **Prefilled cart**: when FitMix has a verified way to fill the store's cart with the exact variants
///   and quantities (a Shopify cart permalink), one button opens the store's own secure checkout.
/// - **Open each item**: otherwise, each piece opens at the store's product page, and the shopper adds
///   it there in the size and quantity shown before checking out on the store's site.
///
/// Stores open inside FitMix (Checkout Kit for prefilled Shopify carts, Safari View for pages); Done
/// comes back here to continue with the next store. A store that won't load inside FitMix can be handed
/// to Safari. Opening a store never changes the cart. Only a verified order confirmation (Checkout
/// Kit's completion event) removes pieces, and then only what that store sold. FitMix never sees or
/// stores payment details.
struct CheckoutView: View {
    @Environment(CartStore.self) private var cart

    /// A store page open in Safari View.
    struct BrowserVisit: Identifiable {
        var url: URL
        var store: String
        var storeName: String
        var id: String { url.absoluteString }
    }

    @State private var browsing: BrowserVisit?
    /// A store page that didn't load in Safari View, offered to Safari instead.
    @State private var failedLoad: BrowserVisit?
    @State private var shopifyCart: PrefilledCart?
    /// Stores whose prefilled cart couldn't continue in FitMix; their cart can be opened in Safari.
    @State private var embeddedFailed: Set<String> = []
    /// Set by a verified completion event, so closing the sheet afterwards isn't reported as cancelled.
    @State private var completed: CheckoutReceipt?
    @State private var notice: (tone: NoticeRow.Tone, text: String)?
    @State private var failure: String?

    private var plans: [StoreCheckoutPlan] { cart.groups.map { StoreCheckoutPlan(group: $0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let notice { NoticeRow(tone: notice.tone, text: notice.text).accessibilityIdentifier("checkoutNotice") }
                if let failedLoad { handoffOffer(failedLoad) }
                ForEach(cart.receipts.prefix(3)) { receiptCard($0) }
                if plans.isEmpty {
                    ProfileEmptyState(icon: "bag", title: "Nothing left to check out", message: "Your cart is empty.")
                } else {
                    NoticeRow(tone: .info, text: plans.count > 1
                        ? "Each store checks out on its own secure site. Finish one, tap Done to come back, then continue with the next."
                        : "This store checks out on its own secure site. Tap Done to come back to FitMix.")
                    ForEach(plans) { storeCard($0) }
                }
                Text("Prices here are estimates from the listings. Each retailer confirms the final price, availability, shipping and taxes. FitMix doesn't take payment or store payment details.")
                    .font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
                    .padding(.top, 4)
            }
            .padding(16)
        }
        .background(Color.fmBackground.ignoresSafeArea())
        .navigationTitle("Checkout")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $browsing, onDismiss: browserClosed) { visit in
            RetailerBrowser(url: visit.url, onInitialLoad: { loaded in
                CheckoutLog.record("page-loaded", store: visit.store, note: "ok=\(loaded) url=\(visit.url.absoluteString)")
                if !loaded { failedLoad = visit }
            }, onDone: { browsing = nil })
            .ignoresSafeArea()
            .task { await debugCloseBrowser() }
        }
        .sheet(item: $shopifyCart, onDismiss: shopifyClosed) { prefilled in
            ShopifyCheckoutSheet(cart: prefilled, onComplete: { receipt, purchased in
                complete(prefilled, receipt: receipt, purchased: purchased)
            }, onFail: { message in
                embeddedFailed.insert(prefilled.store)
                notice = (.caution, "\(prefilled.storeName) checkout couldn't continue in FitMix: \(message) You can open the same cart in Safari. Your FitMix cart is unchanged.")
            }, onClose: { shopifyCart = nil })
        }
        .task { await runDebugSequence() }
        .alert("Couldn't update your cart", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure ?? "") }
    }

    // MARK: Store cards

    private func storeCard(_ plan: StoreCheckoutPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: plan.storeName, color: .fmInk)
                Spacer()
                let count = plan.items.reduce(0) { $0 + $1.quantity }
                Text(count == 1 ? "1 item" : "\(count) items").font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
            }
            EstimatedSubtotals(subtotals: CartStore.subtotals(of: plan.items), size: 20)

            if let prefilled = plan.prefilledCart {
                prefilledSection(prefilled, plan: plan)
            }
            if !plan.itemActions.isEmpty {
                Text(plan.prefilledCart == nil
                     ? "FitMix can't fill \(plan.storeName)'s cart for you. Open each piece, add it on \(plan.storeName)'s site in the size and quantity shown, then check out there."
                     : "These pieces couldn't go into the cart automatically. Open each one and add it on \(plan.storeName)'s site.")
                    .font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
                ForEach(plan.itemActions) { itemRow($0, plan: plan) }
            }
            if let visited = cart.visits[plan.id] {
                NoticeRow(tone: .info, text: "Opened at \(visited.formatted(date: .omitted, time: .shortened)). FitMix hasn't received an order confirmation from \(plan.storeName), so these pieces stay in your cart. Remove them once you've bought them.")
                    .font(.system(size: 13))
                    .accessibilityIdentifier("checkoutVisited-\(plan.id)")
            }
        }
        .fmCard(padding: 14)
        .accessibilityIdentifier("checkoutStore-\(plan.id)")
    }

    @ViewBuilder
    private func prefilledSection(_ prefilled: PrefilledCart, plan: StoreCheckoutPlan) -> some View {
        Text("Opens \(plan.storeName)'s cart with these sizes and quantities already added. You pay on \(plan.storeName)'s secure checkout.")
            .font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
        ForEach(plan.items.filter { prefilled.itemIDs.contains($0.id) }) { item in
            HStack(spacing: 10) {
                GarmentTile(source: tileSource(for: item), category: item.category).frame(width: 40, height: 46)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(lineDetail(item)).font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
                }
                Spacer(minLength: 0)
            }
        }
        Button {
            open(prefilled)
        } label: {
            Label("Checkout at \(plan.storeName)", systemImage: "lock")
        }
        .buttonStyle(FMFilledButtonStyle())
        .accessibilityIdentifier("checkoutCart-\(plan.id)")
        if embeddedFailed.contains(plan.id) {
            Button {
                cart.noteVisit(plan.id)
                BrowserHandoff.open(prefilled.url, store: plan.id)
            } label: {
                Label("Open cart in Safari", systemImage: "safari")
            }
            .buttonStyle(FMOutlineButtonStyle())
            .accessibilityIdentifier("checkoutCartSafari-\(plan.id)")
        }
    }

    private func itemRow(_ action: StoreCheckoutPlan.ItemAction, plan: StoreCheckoutPlan) -> some View {
        let item = action.item
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                GarmentTile(source: tileSource(for: item), category: item.category).frame(width: 40, height: 46)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(item.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        if item.isFixture { TagPill(text: "Test fixture") }
                    }
                    Text(lineDetail(item)).font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
                }
                Spacer(minLength: 0)
            }
            if let url = action.url {
                Button {
                    notice = nil
                    failedLoad = nil
                    cart.noteVisit(plan.id)
                    cart.noteVisit(item.id.uuidString)
                    CheckoutLog.record("open-page", store: plan.id, note: "item=\(item.productID) url=\(url.absoluteString)")
                    browsing = BrowserVisit(url: url, store: plan.id, storeName: plan.storeName)
                } label: {
                    Label(cart.visits[item.id.uuidString] == nil ? "Open at \(plan.storeName)" : "Open at \(plan.storeName) again",
                          systemImage: "arrow.up.right.square")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 40)
                        .background(Color.fmFill, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.fmHairline))
                }
                .foregroundStyle(Color.fmInk)
                .frame(minHeight: 44)
                .accessibilityIdentifier("checkoutOpen-\(item.productID)")
            } else if let problem = action.problem {
                Label("Open at \(plan.storeName)", systemImage: "arrow.up.right.square")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    .background(Color.fmFill, in: Capsule())
                    .foregroundStyle(Color.fmOutline)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityRemoveTraits(.isStaticText)
                    .accessibilityHint("Unavailable. \(problem.explanation)")
                    .accessibilityIdentifier("checkoutOpenDisabled-\(item.productID)")
                NoticeRow(tone: .caution, text: problem.explanation).font(.system(size: 13))
            }
        }
        .padding(.vertical, 4)
    }

    /// "Size M · Qty 2", or where the size will be chosen.
    private func lineDetail(_ item: CartItem) -> String {
        let variant = item.variantDetails.isEmpty ? "Choose size and colour on the store's site" : item.variantDetails.joined(separator: " · ")
        let price = item.unitPrice.map { " · \($0.formatted) each" } ?? ""
        return "\(variant) · Qty \(item.quantity)\(price)"
    }

    private func tileSource(for item: CartItem) -> GarmentTile.Source {
        if let image = cart.localImage(for: item) { return .image(image) }
        if let url = item.imageURL { return .remote(url) }
        return .none
    }

    private func handoffOffer(_ visit: BrowserVisit) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NoticeRow(tone: .caution, text: "\(visit.storeName)'s page didn't load inside FitMix. Open it in Safari instead; your cart stays here.")
            Button {
                failedLoad = nil
                BrowserHandoff.open(visit.url, store: visit.store)
            } label: {
                Label("Open in Safari", systemImage: "safari")
            }
            .buttonStyle(FMOutlineButtonStyle())
            .accessibilityIdentifier("checkoutHandoff")
        }
    }

    // MARK: Opening and coming back

    private func open(_ prefilled: PrefilledCart) {
        notice = nil
        completed = nil
        cart.noteVisit(prefilled.store)
        CheckoutLog.record("open-cart", store: prefilled.store, note: "kind=\(prefilled.kind) url=\(prefilled.url.absoluteString)")
        switch prefilled.kind {
        case .shopifyCartPermalink: shopifyCart = prefilled
        }
    }

    private func browserClosed() {
        notice = (.info, "Back in FitMix. Opening a store doesn't confirm a purchase, so your cart is unchanged.")
        CheckoutLog.record("returned", store: "-", note: "cart=\(CheckoutLog.describe(cart.items))")
    }

    private func complete(_ prefilled: PrefilledCart, receipt: CheckoutReceipt, purchased: [Int64: Int]) {
        completed = receipt
        do {
            try cart.completeCheckout(store: prefilled.store, purchased: purchased, order: receipt)
            CheckoutLog.record("cart-cleared", store: prefilled.store, note: "purchased=\(purchased) remaining=\(CheckoutLog.describe(cart.items))")
        } catch {
            failure = error.localizedDescription
        }
    }

    private func shopifyClosed() {
        if let completed {
            if completed.isSimulated {
                notice = (.info, "Simulated checkout for \(completed.storeName): no order was created. Those pieces were removed from your cart.")
            } else if completed.orderID != nil {
                notice = (.good, "\(completed.storeName) confirmed your order. Those pieces were removed from your cart.")
            } else {
                notice = (.good, "\(completed.storeName) checkout finished without an order number. Check your email from the store. Those pieces were removed from your cart.")
            }
        } else if notice == nil {
            notice = (.info, "Checkout closed. Nothing was bought, and your cart is unchanged.")
            CheckoutLog.record("closed-without-order", store: "-", note: "cart=\(CheckoutLog.describe(cart.items))")
        }
    }

    private func receiptCard(_ receipt: CheckoutReceipt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Eyebrow(text: receipt.isSimulated ? "Simulated · no order" : "Order confirmed", color: .fmGreen)
                Spacer()
                Text(receipt.storeName).font(.system(size: 13, weight: .semibold))
            }
            Text(receipt.orderLabel.map { "Order \($0)" } ?? (receipt.isSimulated ? "No order was created (debug simulation)" : "Order confirmed"))
                .font(.fmDisplay(18))
            ForEach(Array(receipt.lines.enumerated()), id: \.offset) { _, line in
                Text("\(line.quantity) × \(line.title)").font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
            }
            if let url = receipt.orderURL {
                Button("View order status") { browsing = BrowserVisit(url: url, store: receipt.store, storeName: receipt.storeName) }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.fmCobalt)
            }
        }
        .fmCard(padding: 14)
        .accessibilityIdentifier("checkoutReceipt-\(receipt.store)")
    }

    // MARK: Debug

    /// `FM_DEBUG_CHECKOUT_OPEN`: opens each listed store in turn, waiting for it to close in between.
    private func runDebugSequence() async {
        guard let script = DebugCheckoutScript.current, !script.openStores.isEmpty else { return }
        try? await Task.sleep(for: .seconds(1.5))
        for plan in plans {
            let actions = plan.itemActions.map { "\($0.item.productID)=\($0.url?.absoluteString ?? "disabled:\(String(describing: $0.problem!))")" }
            CheckoutLog.record("plan", store: plan.id, note: "name=\(plan.storeName) prefilled=\(plan.prefilledCart?.url.absoluteString ?? "none") items=\(actions) estimate=\(CartStore.subtotals(of: plan.items).map(\.price.formatted))")
        }
        for store in script.openStores {
            guard let plan = plans.first(where: { $0.id == store }) else {
                CheckoutLog.record("debug-open-missing", store: store, note: "stores=\(plans.map(\.id))")
                continue
            }
            if let prefilled = plan.prefilledCart {
                open(prefilled)
            } else if let action = plan.itemActions.first(where: { $0.url != nil }), let url = action.url {
                cart.noteVisit(plan.id)
                cart.noteVisit(action.item.id.uuidString)
                CheckoutLog.record("open-page", store: plan.id, note: "item=\(action.item.productID) url=\(url.absoluteString)")
                browsing = BrowserVisit(url: url, store: plan.id, storeName: plan.storeName)
            } else {
                CheckoutLog.record("debug-nothing-to-open", store: store)
                continue
            }
            for _ in 0..<480 where shopifyCart != nil || browsing != nil { try? await Task.sleep(for: .milliseconds(250)) }
            try? await Task.sleep(for: .seconds(1.5))
        }
        CheckoutLog.record("debug-sequence-done", store: "-", note: "cart=\(CheckoutLog.describe(cart.items))")
    }

    private func debugCloseBrowser() async {
        guard let seconds = DebugCheckoutScript.current?.closeAfter else { return }
        do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
        browsing = nil
    }
}

/// "Estimated CA$129.75 · US$24.90": one subtotal per currency, never converted or added together.
struct EstimatedSubtotals: View {
    var subtotals: [CartStore.CurrencySubtotal]
    var size: CGFloat = 17

    var body: some View {
        if subtotals.isEmpty {
            Text("Prices unavailable").font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text("ESTIMATED").font(.fmEyebrow).tracking(1.2).foregroundStyle(Color.fmSecondary)
                Text(subtotals.map(\.price.formatted).joined(separator: "  ·  "))
                    .font(.fmDisplay(size)).foregroundStyle(Color.fmInk)
                    .accessibilityLabel("Estimated " + subtotals.map(\.price.formatted).joined(separator: " and "))
            }
        }
    }
}
