import SwiftUI
import SafariServices

/// Review of the current look's purchasable pieces, including confirmed swaps.
/// FitMix has no cart or checkout yet, so this stops at review: sizes and retailer pages.
struct ShoppingReviewView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(\.dismiss) private var dismiss
    @Environment(ProfileStore.self) private var profile
    /// Sizes the user picked here. Without a pick, a saved Profile size is used when the product lists it.
    @State private var sizes: [UUID: String] = [:]
    @State private var retailer: URL?

    var body: some View {
        NavigationStack {
            Group {
                if let look = studio.look {
                    content(look)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "bag").font(.system(size: 36)).foregroundStyle(AuthPalette.secondary)
                        Text("Your bag is empty").font(.system(size: 22, weight: .medium, design: .serif))
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
                        .font(.system(size: 11, weight: .semibold)).tracking(0.9)
                        .foregroundStyle(AuthPalette.secondary)
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
                        .background(AuthPalette.containerLow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                Button {} label: { Label("Add to Cart", systemImage: "cart") }
                    .buttonStyle(AuthPrimaryButtonStyle())
                    .disabled(true)
                    .opacity(0.5)
                    .accessibilityHint("Not available yet")
                Text(purchasable.contains { $0.product?.retailerURL != nil }
                     ? "Checkout isn't connected yet. Use View at retailer to buy a piece."
                     : "Checkout isn't connected yet.")
                    .font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                    .multilineTextAlignment(.center)
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
                if product.sizes.isEmpty {
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
                if let url = product.retailerURL {
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
        .accessibilityIdentifier("shopRow-\(piece.detected.category.rawValue)")
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
