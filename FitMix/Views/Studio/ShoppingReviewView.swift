import SwiftUI
import SafariServices

/// Review of the current look's purchasable pieces, including confirmed swaps.
/// Each piece is added as the listing it currently shows: a confirmed swap, else the listing chosen
/// in Studio, else the best match (`WorkingLook.Piece.product`). A listing that looks like a Shopify
/// product opens `VariantPickerSheet` to choose the store's exact variant; any other is added in its
/// chosen size. The cart then sends each store's pieces to that store's own checkout.
struct ShoppingReviewView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(CartStore.self) private var cart
    @Environment(\.dismiss) private var dismiss
    @Environment(ProfileStore.self) private var profile
    /// Sizes the user picked here. Without a pick, a saved Profile size is used when the product lists it.
    @State private var sizes: [UUID: String] = [:]
    @State private var retailer: URL?
    @State private var cartFailure: String?
    /// The Shopify listing whose variant picker is open.
    @State private var picking: VariantPick?
    @State private var showCart = false

    struct VariantPick: Identifiable {
        var product: CatalogProduct
        var link: ShopifyProductLink
        var autoPick: DebugCheckoutScript.Pick?
        var id: String { product.id }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let look = studio.look {
                    content(look)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "bag").font(.system(size: 36)).foregroundStyle(AuthPalette.secondary)
                        Text("Your bag is empty").font(.fmDisplay(22))
                        Text("Scan an outfit, then shop it from Studio.")
                            .font(.system(size: 14)).foregroundStyle(AuthPalette.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(AuthPalette.surface)
            .navigationTitle("Shop This Look")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(isPresented: $showCart) { CartView(showsDone: false) }
        }
        // `.id`: a new piece gets a fresh picker. Without it, a sheet still on screen when the piece changes
        // keeps the previous product's loaded variants and could add the wrong one.
        .sheet(item: $picking) { VariantPickerSheet(product: $0.product, link: $0.link, autoPick: $0.autoPick).id($0.id) }
        .task { await runDebugScript() }
        .preferredColorScheme(.light)
        .sheet(item: $retailer) { SafariView(url: $0).ignoresSafeArea() }
        .alert("Couldn't add to cart", isPresented: Binding(get: { cartFailure != nil }, set: { if !$0 { cartFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cartFailure ?? "")
        }
    }

    private func content(_ look: WorkingLook) -> some View {
        let purchasable = look.pieces.filter { $0.product != nil }
        let unmatched = look.pieces.filter { $0.product == nil }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if purchasable.isEmpty {
                    NoticeRow(tone: .info, text: "None of these pieces have a catalog match yet, so there's nothing to shop.")
                }
                ForEach(purchasable) { piece in
                    if let product = piece.product { row(piece: piece, product: product) }
                }
                if !unmatched.isEmpty {
                    Text("NOT MATCHED YET")
                        .font(.system(size: 13, weight: .bold)).tracking(0.7)
                        .foregroundStyle(Color.fmInk)
                        .padding(.top, 8)
                    ForEach(unmatched) { piece in
                        HStack(spacing: 12) {
                            GarmentTile(source: piece.tileSource, category: piece.detected.category)
                                .frame(width: 56, height: 62)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(piece.detected.category.title).font(.system(size: 15, weight: .semibold))
                                Text("No product match for this piece yet.")
                                    .font(.system(size: 13)).foregroundStyle(AuthPalette.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(AuthPalette.containerLow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(purchasable.count == 1 ? "1 item" : "\(purchasable.count) items")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    PriceSummary(look: look)
                }
                if cart.isEmpty {
                    Text(purchasable.isEmpty ? "Nothing here can be added to your cart yet."
                                             : "Add pieces to your cart, then review them together.")
                        .font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    NavigationLink {
                        CartView(showsDone: false)
                    } label: {
                        Label(cart.count == 1 ? "View Cart (1 item)" : "View Cart (\(cart.count) items)", systemImage: "bag")
                    }
                    .buttonStyle(AuthPrimaryButtonStyle())
                    .accessibilityIdentifier("shopViewCart")
                }
            }
            .padding(16)
            .background(AuthPalette.surface)
            .overlay(alignment: .top) { Rectangle().fill(AuthPalette.containerHigh).frame(height: 1) }
        }
    }

    /// The user's pick, else their saved size for this kind of piece if the product lists it exactly.
    private func size(for piece: WorkingLook.Piece, _ product: CatalogProduct) -> (value: String, fromProfile: Bool)? {
        if let picked = sizes[piece.id] { return (picked, false) }
        return profile.sizing.preferredSize(among: product.sizes, for: product.category).map { ($0, true) }
    }

    private func row(piece: WorkingLook.Piece, product: CatalogProduct) -> some View {
        let chosen = size(for: piece, product)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                GarmentTile(source: piece.isSwapped ? product.image.tileSource : (product.image.tileSource.isNone ? piece.tileSource : product.image.tileSource),
                            category: piece.detected.category)
                    .frame(width: 64, height: 72)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(piece.detected.category.title.uppercased())
                            .font(.system(size: 10, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(AuthPalette.secondary)
                        if piece.isSwapped { TagPill(text: "Swapped") }
                        if product.match == .similar { TagPill(text: "Similar").opacity(0.75) }
                    }
                    Text(product.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(AuthPalette.onSurface)
                    if let brand = product.brand { Text(brand).font(.system(size: 13)).foregroundStyle(AuthPalette.secondary) }
                    Text(product.price?.formatted ?? "Price unavailable")
                        .font(.system(size: 14, weight: product.price == nil ? .regular : .bold))
                        .foregroundStyle(product.price == nil ? AuthPalette.secondary : AuthPalette.onSurface)
                }
                Spacer(minLength: 0)
            }
            HStack {
                if let link = Self.shopifyLink(for: product) {
                    Text("Sizes and colours from \(link.host)").font(.system(size: 13)).foregroundStyle(AuthPalette.secondary)
                } else if product.sizes.isEmpty {
                    Text("Sizes unavailable").font(.system(size: 13)).foregroundStyle(AuthPalette.secondary)
                } else {
                    Menu {
                        ForEach(product.sizes, id: \.self) { size in
                            Button(size) { sizes[piece.id] = size }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(chosen.map { "Size \($0.value)" } ?? "Choose size")
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AuthPalette.onSurface)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(AuthPalette.container, in: Capsule())
                    }
                    .accessibilityLabel("Size for \(product.name)")
                    .accessibilityValue(chosen.map { $0.fromProfile ? "\($0.value), your saved size" : $0.value } ?? "Not chosen")
                    if chosen?.fromProfile == true {
                        Text("Your saved size")
                            .font(.system(size: 12))
                            .foregroundStyle(AuthPalette.secondary)
                            .accessibilityHidden(true)
                    }
                }
                Spacer()
            }
            HStack {
                addButton(product: product, size: chosen?.value)
                Spacer()
                if let url = product.retailerURL {
                    Button("View at retailer") { retailer = url }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AuthPalette.primary)
                        .frame(minHeight: 44)
                }
            }
        }
        .padding(12)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(AuthPalette.containerHigh))
        .accessibilityIdentifier("shopRow-\(piece.detected.category.rawValue)")
    }
}

extension ShoppingReviewView {
    /// Add to Cart for one piece. A product that lists sizes needs one chosen first; one that lists
    /// none (most live retailer matches) is added without a size.
    @ViewBuilder
    fileprivate func addButton(product: CatalogProduct, size: String?) -> some View {
        if let link = Self.shopifyLink(for: product) {
            Button {
                picking = VariantPick(product: product, link: link)
            } label: {
                Label(cart.containsProduct(product.id) ? "Add Another" : "Choose Size & Add",
                      systemImage: cart.containsProduct(product.id) ? "checkmark" : "bag.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(AuthPalette.container, in: Capsule())
            }
            .foregroundStyle(cart.containsProduct(product.id) ? Color.fmGreen : AuthPalette.onSurface)
            .frame(minHeight: 44)
            .accessibilityIdentifier("shopAdd-\(product.category.rawValue)")
        } else {
            plainAddButton(product: product, size: size)
        }
    }

    @ViewBuilder
    fileprivate func plainAddButton(product: CatalogProduct, size: String?) -> some View {
        let needsSize = !product.sizes.isEmpty && size == nil
        if !needsSize && cart.contains(productID: product.id, size: size) {
            Label("In Cart", systemImage: "checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.fmGreen)
                .frame(minHeight: 44)
                .accessibilityIdentifier("shopInCart-\(product.category.rawValue)")
        } else {
            Button {
                do { try cart.add(product, size: size) } catch { cartFailure = error.localizedDescription }
            } label: {
                Label(needsSize ? "Choose a size to add" : "Add to Cart", systemImage: "bag.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(AuthPalette.container, in: Capsule())
            }
            .foregroundStyle(AuthPalette.onSurface)
            .disabled(needsSize)
            .opacity(needsSize ? 0.55 : 1)
            .frame(minHeight: 44)
            .accessibilityIdentifier("shopAdd-\(product.category.rawValue)")
        }
    }
}

extension ShoppingReviewView {
    /// Debug: `FM_DEBUG_CHECKOUT_PICKS` adds each scripted piece (through its variant picker when the listing
    /// looks like Shopify, else with plain Add to Cart), then opens the cart.
    fileprivate func runDebugScript() async {
        guard let script = DebugCheckoutScript.current, studio.look != nil else { return }
        try? await Task.sleep(for: .seconds(1))
        for category in script.order {
            guard let pick = script.picks[category],
                  let product = studio.look?.pieces.first(where: { $0.detected.category == category })?.product else {
                CheckoutLog.record("debug-no-listing", store: "-", note: "category=\(category.rawValue)")
                continue
            }
            guard let link = Self.shopifyLink(for: product) else {
                let size = pick.options.first { $0.0.caseInsensitiveCompare("size") == .orderedSame }?.1
                do {
                    try cart.add(product, size: size, quantity: pick.quantity)
                    CheckoutLog.record("added", store: product.retailer ?? "-", note: "product=\(product.id) size=\(size ?? "-") qty=\(pick.quantity)")
                } catch { CheckoutLog.record("debug-add-failed", store: "-", note: error.localizedDescription) }
                continue
            }
            picking = VariantPick(product: product, link: link, autoPick: pick)
            for _ in 0..<80 where picking != nil { try? await Task.sleep(for: .milliseconds(250)) }
            try? await Task.sleep(for: .milliseconds(700))
        }
        showCart = true
    }
}

extension ShoppingReviewView {
    /// The listing as a possible Shopify product, only when it's a link FitMix would open for checkout.
    static func shopifyLink(for product: CatalogProduct) -> ShopifyProductLink? {
        guard case .success(let url) = RetailerLink.check(product.retailerURL) else { return nil }
        return ShopifyProductLink(url: url)
    }
}

extension GarmentTile.Source {
    var isNone: Bool { if case .none = self { true } else { false } }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Retailer pages open inside FitMix.
struct SafariView: UIViewControllerRepresentable {
    var url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
