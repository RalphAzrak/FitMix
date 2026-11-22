import SwiftUI

/// FitMix's own sizes for one kind of garment. They never come from a store, so the size page always opens,
/// whatever retailer the piece is from.
enum FitMixSizes {
    /// The sizes to offer for `category`, and the one to preselect from the user's saved sizes, if any.
    static func options(for category: GarmentCategory, saved: SizingPreferences) -> (sizes: [String], preferred: String?) {
        switch category {
        case .jacket, .tshirt, .top, .dress:
            return (LetterSize.allCases.map(\.rawValue), saved.top?.rawValue)
        case .pants, .skirt, .shorts, .bottoms:
            // Waist sizes, unless the user saved their bottoms in another system (letters, US or EU numbers).
            if let bottom = saved.bottom, bottom.system != .waist {
                return (bottom.system.values.map { BottomSize(system: bottom.system, value: $0).display }, bottom.display)
            }
            return (BottomSize.System.waist.values.map { "W\($0)" }, saved.bottom.map { "W\($0.value)" })
        case .shoes:
            let system = saved.shoe?.system ?? .usMen
            return (system.values.map { ShoeSize(system: system, value: $0).display }, saved.shoe?.display)
        case .bag, .hat, .accessory, .other:
            return (["One Size"], "One Size")
        }
    }
}

/// Choose a size and quantity for one piece, then add it to the cart. The sizes are FitMix's own
/// (`FitMixSizes`), with the user's saved size preselected: nothing is loaded from the retailer.
struct SizePickerSheet: View {
    let product: CatalogProduct

    @Environment(CartStore.self) private var cart
    @Environment(ProfileStore.self) private var profile
    @Environment(\.dismiss) private var dismiss

    @State private var size: String?
    @State private var quantity = 1
    @State private var failure: String?

    private var options: (sizes: [String], preferred: String?) {
        FitMixSizes.options(for: product.category, saved: profile.sizing)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        GarmentTile(source: product.image.tileSource, category: product.category)
                            .frame(width: 76, height: 88)
                        VStack(alignment: .leading, spacing: 4) {
                            if let retailer = product.retailer { Eyebrow(text: retailer) }
                            Text(product.name).font(.fmDisplay(20)).foregroundStyle(Color.fmInk).lineLimit(3)
                            Text(product.price?.formatted ?? "Price unavailable")
                                .font(.system(size: 14, weight: product.price == nil ? .regular : .bold))
                                .foregroundStyle(product.price == nil ? Color.fmSecondary : Color.fmInk)
                        }
                    }

                    FMSectionHeader(title: "Size")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(options.sizes, id: \.self) { option in
                            Button { size = option } label: {
                                Text(option)
                                    .font(.system(size: 15, weight: .semibold))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .foregroundStyle(size == option ? .white : Color.fmInk)
                                    .background(size == option ? Color.fmCobalt : AuthPalette.container,
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(size == option ? .isSelected : [])
                            .accessibilityIdentifier("sizeOption-\(option)")
                        }
                    }
                    if let preferred = options.preferred, options.sizes.contains(preferred) {
                        Text("Your saved size is \(preferred).")
                            .font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
                    }

                    FMSectionHeader(title: "Quantity")
                    Stepper(value: $quantity, in: 1...CartStore.maxQuantity) {
                        Text("\(quantity)").font(.system(size: 17, weight: .semibold).monospacedDigit())
                    }
                    .accessibilityIdentifier("sizeQuantity")

                    Text("These are FitMix sizes. Check the retailer's own size chart before you buy.")
                        .font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            .background(Color.fmBackground.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                Button(action: add) {
                    Label(size == nil ? "Choose a size" : "Add to Cart", systemImage: "bag.badge.plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(FMFilledButtonStyle())
                .disabled(size == nil)
                .opacity(size == nil ? 0.55 : 1)
                .padding(16)
                .background(Color.fmBackground)
                .accessibilityIdentifier("sizeAdd")
            }
            .navigationTitle("Choose Size")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .preferredColorScheme(.light)
        .onAppear {
            if size == nil, let preferred = options.preferred, options.sizes.contains(preferred) { size = preferred }
        }
        .alert("Couldn't add to cart", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure ?? "") }
        .accessibilityIdentifier("sizePicker")
    }

    private func add() {
        guard let size else { return }
        do {
            // The same product in the same size is one cart line, so each add raises its quantity.
            for _ in 0..<quantity { try cart.add(product, size: size) }
            dismiss()
        } catch { failure = error.localizedDescription }
    }
}
