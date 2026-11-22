import SwiftUI
import SafariServices

/// Review of the current look's purchasable pieces, including confirmed swaps.
/// Each piece is added to the cart from FitMix's own size page (`SizePickerSheet`). Sizes never come from
/// the retailer, so the page opens for every store.
struct ShoppingReviewView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(CartStore.self) private var cart
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @State private var retailer: URL?
    /// The piece whose FitMix size page is open.
    @State private var sizing: CatalogProduct?

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
        }
        .sheet(item: $sizing) { SizePickerSheet(product: $0) }
        .preferredColorScheme(.light)
        .sheet(item: $retailer) { SafariView(url: $0).ignoresSafeArea() }
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
                    // Same flow as the bag icon: this sheet closes and the cart opens full screen.
                    Button { router.openCart() } label: {
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

    private func row(piece: WorkingLook.Piece, product: CatalogProduct) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
                addButton(product: product)
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
    /// Opens FitMix's size page for one piece. The size and quantity are chosen there, then it is added.
    fileprivate func addButton(product: CatalogProduct) -> some View {
        Button {
            sizing = product
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
