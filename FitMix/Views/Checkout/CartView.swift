import SwiftUI

/// The cart: pieces the user added from Shop This Look, with size and quantity.
/// There's no checkout yet, so this ends at the subtotal and each piece's retailer page.
struct CartView: View {
    @Environment(CartStore.self) private var cart
    @Environment(\.dismiss) private var dismiss
    /// False when pushed inside another screen's navigation (Shop This Look), where Back is enough.
    var showsDone = true

    @State private var retailer: URL?
    @State private var failure: String?
    @State private var confirmClear = false

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
            VStack(spacing: 12) {
                ForEach(cart.items) { row($0) }
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
                    if let detail = [item.brand, item.retailer].compactMap({ $0 }).first {
                        Text(detail).font(.system(size: 13)).foregroundStyle(AuthPalette.secondary)
                    }
                    Text(item.size.map { "Size \($0)" } ?? "Size not listed")
                        .font(.system(size: 13)).foregroundStyle(AuthPalette.secondary)
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
            Text("Shipping and tax will be added at checkout.")
                .font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {} label: { Label("Checkout", systemImage: "lock") }
                .buttonStyle(AuthPrimaryButtonStyle())
                .disabled(true)
                .opacity(0.5)
                .accessibilityHint("Not available yet")
            Text(cart.items.contains { $0.retailerURL != nil }
                 ? "Checkout isn't connected yet. Use View at retailer to buy a piece."
                 : "Checkout isn't connected yet.")
                .font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                .multilineTextAlignment(.center)
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

    private func perform(_ change: () throws -> Void) {
        do { try change() } catch { failure = error.localizedDescription }
    }
}

/// Small count badge for cart buttons. Hidden when the cart is empty.
struct CartBadge: View {
    var count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(Color.fmCobalt, in: Capsule())
                .accessibilityHidden(true)
        }
    }
}
