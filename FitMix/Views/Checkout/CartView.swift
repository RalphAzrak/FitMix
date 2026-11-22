import SwiftUI

/// The cart: pieces the user added from Shop This Look, from any number of stores, grouped by store,
/// with size, colour, variant and quantity. Prices are estimates per currency. **Checkout** opens
/// `CheckoutView`, where each store is checked out on its own site.
struct CartView: View {
    @Environment(CartStore.self) private var cart
    @Environment(\.dismiss) private var dismiss
    /// False when pushed inside another screen's navigation (Shop This Look), where Back is enough.
    var showsDone = true

    @State private var retailer: URL?
    @State private var failure: String?
    @State private var confirmClear = false
    @State private var showCheckout = false

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
        .navigationDestination(isPresented: $showCheckout) { CheckoutView() }
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
                ForEach(cart.groups) { group in
                    FMSectionHeader(title: group.name) {
                        Text((group.count == 1 ? "1 item" : "\(group.count) items")
                             + (group.subtotals.isEmpty ? "" : " · est. " + group.subtotals.map(\.price.formatted).joined(separator: " · ")))
                            .font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
                    }
                    .accessibilityIdentifier("cartStore-\(group.id)")
                    ForEach(group.items) { row($0) }
                }
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
                    Text(storeLine(item)).font(.system(size: 13)).foregroundStyle(AuthPalette.secondary)
                    Text(item.variantDetails.isEmpty ? "Size not listed · choose it at the store" : item.variantDetails.joined(separator: " · "))
                        .font(.system(size: 13)).foregroundStyle(AuthPalette.secondary)
                    if let variant = item.variantID {
                        Text("Variant " + variant).font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.fmOutline)
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
                switch RetailerLink.check(item.retailerURL) {
                case .success(let url):
                    Button("View at \(item.storeName)") { retailer = url }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AuthPalette.primary)
                        .frame(minHeight: 44)
                case .failure(let problem):
                    Text(problem == .missing ? "No link" : "Link unusable")
                        .font(.system(size: 12)).foregroundStyle(Color.fmAmber)
                        .accessibilityHint(problem.explanation)
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

    /// "Uniqlo", or "Uniqlo · Brand" / "eBay · seller" when there's more to say than the store name.
    private func storeLine(_ item: CartItem) -> String {
        var parts = [item.retailer ?? item.storeName]
        if let brand = item.brand, !(item.retailer ?? "").localizedCaseInsensitiveContains(brand) { parts.append(brand) }
        return parts.joined(separator: " · ")
    }

    private func tileSource(for item: CartItem) -> GarmentTile.Source {
        if let image = cart.localImage(for: item) { return .image(image) }
        if let url = item.imageURL { return .remote(url) }
        return .none
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cart.count == 1 ? "1 item" : "\(cart.count) items")
                        .font(.system(size: 15, weight: .semibold))
                    Text(cart.groups.count == 1 ? "from 1 store" : "from \(cart.groups.count) stores")
                        .font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(cart.subtotals, id: \.price.currencyCode) { subtotal in
                        Text(subtotal.price.formatted).font(.system(size: 17, weight: .bold)).foregroundStyle(AuthPalette.onSurface)
                    }
                    if cart.subtotals.isEmpty {
                        Text("Prices unavailable").font(.system(size: 13)).foregroundStyle(AuthPalette.secondary)
                    } else {
                        Text(cart.subtotals.count > 1 ? "Estimated, by currency" : "Estimated subtotal")
                            .font(.system(size: 11)).foregroundStyle(AuthPalette.secondary)
                    }
                    if cart.unpricedCount > 0 && !cart.subtotals.isEmpty {
                        Text("\(cart.unpricedCount) without a price").font(.system(size: 11)).foregroundStyle(AuthPalette.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("cartSubtotals")
            }
            Text("Each retailer confirms the final price, availability, shipping and taxes on its own checkout.")
                .font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
            Button {
                showCheckout = true
            } label: {
                Label(cart.groups.count > 1 ? "Checkout · \(cart.groups.count) stores" : "Checkout", systemImage: "lock")
            }
            .buttonStyle(FMFilledButtonStyle())
            .accessibilityIdentifier("cartCheckout")
        }
        .padding(16)
        .background(AuthPalette.surface)
        .overlay(alignment: .top) { Rectangle().fill(AuthPalette.containerHigh).frame(height: 1) }
    }

    // MARK: Debug

    /// Debug: `FM_DEBUG_CHECKOUT_OPEN` goes straight on to Checkout, which opens the listed stores.
    private func runDebugOpen() async {
        guard let script = DebugCheckoutScript.current, !script.openStores.isEmpty else { return }
        try? await Task.sleep(for: .seconds(1.5))
        CheckoutLog.record("cart", store: "-", note: "groups=\(cart.groups.map { "\($0.id)(\($0.name))" }) subtotals=\(cart.subtotals.map(\.price.formatted)) unpriced=\(cart.unpricedCount) items=\(cart.items.map { "\($0.name) | \($0.storeName) | \($0.unitPrice?.formatted ?? "no price") | \($0.variantDetails) | variant=\($0.variantID ?? "-") | img=\($0.imageURL?.absoluteString ?? "-") | url=\($0.retailerURL?.absoluteString ?? "-") ×\($0.quantity)" })")
        showCheckout = true
    }

    private func perform(_ change: () throws -> Void) {
        do { try change() } catch { failure = error.localizedDescription }
    }
}
