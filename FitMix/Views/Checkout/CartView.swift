import SwiftUI

/// The cart, the first page of the demo checkout flow (`CheckoutFlowView`): pieces the user added from
/// Shop This Look, with size and quantity, grouped by store. One **Checkout** button pushes the demo
/// checkout for the whole cart, every store together. Recent demo orders are listed here too and open
/// their Order Summary.
struct CartView: View {
    @Environment(CartStore.self) private var cart
    @Environment(DemoOrderStore.self) private var orders
    @Environment(CheckoutNavigator.self) private var navigator

    @State private var failure: String?
    @State private var confirmClear = false

    var body: some View {
        Group {
            if let loadError = cart.loadError {
                unreadable(loadError)
            } else if cart.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ProfileEmptyState(icon: "bag", title: "Your cart is empty",
                                          message: "Scan an outfit, then add pieces from Shop This Look.")
                        recentOrders
                    }
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
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { navigator.close() }.accessibilityIdentifier("cartDone")
            }
            if !cart.isEmpty && cart.loadError == nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) { confirmClear = true }
                        .accessibilityIdentifier("cartClear")
                }
            }
        }
        .task { await runDebugCheckout() }
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
                ForEach(cart.groups) { group in
                    FMSectionHeader(title: group.name) {
                        Text(group.count == 1 ? "1 item" : "\(group.count) items")
                            .font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
                    }
                    ForEach(group.items) { row($0) }
                }
                recentOrders
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) { summary }
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
                    // The store, then the brand when it says something more.
                    let detail = [item.retailer, item.brand.flatMap { $0 == item.retailer ? nil : $0 }].compactMap { $0 }
                    if !detail.isEmpty {
                        Text(detail.joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(AuthPalette.secondary)
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
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cart.count == 1 ? "1 item" : "\(cart.count) items").font(.system(size: 15, weight: .semibold))
                    Text(cart.groups.count == 1 ? "from 1 store" : "from \(cart.groups.count) stores")
                        .font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    if cart.totals.isEmpty {
                        Text("Prices unavailable").font(.system(size: 13)).foregroundStyle(AuthPalette.secondary)
                    }
                    ForEach(cart.totals, id: \.price.currencyCode) { total in
                        Text(total.price.formatted).font(.system(size: 17, weight: .bold)).foregroundStyle(AuthPalette.onSurface)
                    }
                    if cart.totals.count > 1 {
                        Text("Currencies kept separate").font(.system(size: 11)).foregroundStyle(AuthPalette.secondary)
                    }
                    if cart.unpricedPieces > 0 && !cart.totals.isEmpty {
                        Text("\(cart.unpricedPieces) without a price").font(.system(size: 11)).foregroundStyle(AuthPalette.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("cartTotals")
            }
            Button {
                navigator.path.append(.checkout)
            } label: {
                Label("Checkout", systemImage: "bag")
            }
            .buttonStyle(FMFilledButtonStyle())
            .accessibilityIdentifier("cartCheckout")
        }
        .padding(16)
        .background(AuthPalette.surface)
        .overlay(alignment: .top) { Rectangle().fill(AuthPalette.containerHigh).frame(height: 1) }
    }

    /// Demo orders placed on this iPhone, newest first. Saved on disk, so they're here after a restart.
    @ViewBuilder
    private var recentOrders: some View {
        if let error = orders.loadError {
            NoticeRow(tone: .caution, text: error)
        } else if !orders.orders.isEmpty {
            FMSectionHeader(title: "Demo orders")
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("demoOrdersSection")
                .accessibilityValue("\(orders.orders.count)")
            ForEach(orders.orders.prefix(5)) { order in
                NavigationLink(value: CheckoutRoute.summary(order.id, justPlaced: false)) {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.fmGreen)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Demo order placed · \(order.number)").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.fmInk)
                            Text("\(order.pieces) items · \(order.savedTotals.map(\.price.formatted).joined(separator: " · ")) · \(order.placedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.fmOutline)
                    }
                    .fmCard(padding: 12)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("demoOrder-\(order.number)")
            }
        }
    }

    /// Debug: `FM_DEBUG_CHECKOUT_PLACE=1` taps Checkout, then Checkout and Payment carry on.
    private func runDebugCheckout() async {
        guard DebugCheckoutScript.current?.placeOrder == true, !cart.isEmpty, navigator.path.isEmpty else { return }
        do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
        CheckoutLog.record("debug-cart-checkout", store: "-", note: "items=\(cart.items.count) stores=\(cart.groups.count)")
        navigator.path.append(.checkout)
    }

    private func perform(_ change: () throws -> Void) {
        do { try change() } catch { failure = error.localizedDescription }
    }
}
