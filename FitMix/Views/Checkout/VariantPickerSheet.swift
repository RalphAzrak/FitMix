import SwiftUI

/// Choose the exact store variant (size, colour) and quantity of a Shopify listing before adding it
/// to the cart. Options and stock come from the store's public product data, loaded when this opens.
/// A listing whose link only looks like a Shopify product page (many retailers use `/products/`), or a
/// store whose data can't be loaded, can still be added without a store variant: the demo checkout
/// takes any cart line.
struct VariantPickerSheet: View {
    let product: CatalogProduct
    let link: ShopifyProductLink
    /// Debug: a preset pick to apply as soon as the product loads (see `DebugCheckoutScript`).
    var autoPick: DebugCheckoutScript.Pick?

    @Environment(CartStore.self) private var cart
    @Environment(ProfileStore.self) private var profile
    @Environment(\.dismiss) private var dismiss

    @State private var resolved: ShopifyProduct?
    @State private var loadError: String?
    @State private var selection: [Int: String] = [:]
    @State private var quantity = 1
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let resolved {
                    form(resolved)
                } else if let loadError {
                    ScrollView {
                        ProfileEmptyState(icon: "exclamationmark.triangle", title: "Couldn't load sizes", message: loadError) {
                            VStack(spacing: 10) {
                                Button("Try Again") { Task { await load() } }.buttonStyle(FMFilledButtonStyle())
                                Button("Add Without a Store Variant", action: addWithoutVariant)
                                    .buttonStyle(FMOutlineButtonStyle())
                                    .accessibilityIdentifier("variantAddWithoutVariant")
                                Text("Adds this piece as listed, without a size from \(link.host). It can still go through FitMix's demo checkout, but not through the store's own checkout.")
                                    .font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(16)
                    }
                } else {
                    ProgressView("Loading sizes from \(link.host)…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.fmBackground.ignoresSafeArea())
            .navigationTitle("Choose Size")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .preferredColorScheme(.light)
        .task { await load() }
        .alert("Couldn't add to cart", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure ?? "") }
    }

    private func load() async {
        loadError = nil
        do {
            let product = try await ShopifyProducts.load(link)
            selection = product.initialSelection(preferredSize: profile.sizing.preferredSize(among: product.options.first(where: \.isSize)?.values ?? [], for: self.product.category))
            resolved = product
            if let autoPick { apply(autoPick, to: product) }
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// The store's product data couldn't be read: add the listing as it is, like any other retailer's.
    private func addWithoutVariant() {
        do {
            try cart.add(product, size: nil)
            CheckoutLog.record("added-without-variant", store: link.host, note: "product=\(product.id)")
            dismiss()
        } catch { failure = error.localizedDescription }
    }

    // MARK: Form

    private func form(_ resolved: ShopifyProduct) -> some View {
        let variant = resolved.variant(for: selection)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    GarmentTile(source: resolved.imageURL.map { .remote($0) } ?? .none, category: product.category)
                        .frame(width: 76, height: 88)
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: product.retailer ?? resolved.vendor ?? link.host)
                        Text(resolved.title).font(.fmDisplay(20)).foregroundStyle(Color.fmInk)
                        Text(link.host).font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
                    }
                }

                ForEach(resolved.choices, id: \.self) { index in
                    optionPicker(resolved, index: index)
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(resolved.fixed.filter { name, _ in !resolved.choices.contains(where: { resolved.options[$0].name == name }) }, id: \.name) { item in
                        detailRow(item.name, item.value)
                    }
                    if resolved.colourIsFixedByListing {
                        detailRow("Colour", "As pictured. This store sells each colour as its own product, so this listing sets it.")
                    }
                }

                FMSectionHeader(title: "Quantity")
                Stepper(value: $quantity, in: 1...CartStore.maxQuantity) {
                    Text("\(quantity)").font(.system(size: 17, weight: .semibold).monospacedDigit())
                }
                .accessibilityIdentifier("variantQuantity")

                VStack(alignment: .leading, spacing: 4) {
                    if let variant {
                        NoticeRow(tone: variant.available ? .good : .caution,
                                  text: variant.available ? "\(variant.title) is in stock at \(link.host)." : "\(variant.title) is sold out.")
                        Text("Variant " + String(variant.id)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.fmSecondary)
                    } else {
                        NoticeRow(tone: .info, text: "Choose " + resolved.choices.filter { selection[$0] == nil }
                            .map { resolved.options[$0].name.lowercased() }.joined(separator: " and ") + ".")
                    }
                }

                Button {
                    guard let variant else { return }
                    do {
                        try cart.add(product, resolved: resolved, variant: variant, quantity: quantity)
                        dismiss()
                    } catch { failure = error.localizedDescription }
                } label: {
                    Label("Add to Cart", systemImage: "bag.badge.plus")
                }
                .buttonStyle(FMFilledButtonStyle())
                .disabled(variant?.available != true)
                .accessibilityIdentifier("variantAdd")
            }
            .padding(16)
        }
    }

    private func optionPicker(_ resolved: ShopifyProduct, index: Int) -> some View {
        let option = resolved.options[index]
        let values = resolved.values(for: index, given: selection)
        return VStack(alignment: .leading, spacing: 8) {
            FMSectionHeader(title: option.name) {
                if let picked = selection[index] { Text(picked).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.fmCobalt) }
            }
            FlowLayout(spacing: 8) {
                ForEach(values, id: \.value) { entry in
                    let isOn = selection[index] == entry.value
                    Button {
                        select(entry.value, at: index, in: resolved)
                    } label: {
                        Text(entry.value)
                            .font(.system(size: 15, weight: .semibold))
                            .strikethrough(!entry.available)
                            .foregroundStyle(isOn ? Color.white : (entry.available ? Color.fmInk : Color.fmOutline))
                            .padding(.horizontal, 16)
                            .frame(minWidth: 52, minHeight: 44)
                            .background(Capsule().fill(isOn ? Color.fmCobalt : Color.fmFill))
                            .overlay(Capsule().strokeBorder(isOn ? Color.fmCobalt : Color.fmHairline))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option.name) \(entry.value)\(entry.available ? "" : ", sold out")")
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityIdentifier("variantOption-\(option.name)-\(entry.value)")
                }
            }
        }
    }

    private func detailRow(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(Color.fmSecondary)
                .frame(width: 64, alignment: .leading)
            Text(value).font(.system(size: 14)).foregroundStyle(Color.fmInk)
        }
    }

    private func select(_ value: String, at index: Int, in resolved: ShopifyProduct) {
        selection[index] = value
        // Drop picks that no longer have a real variant, and fill in an option left with one value.
        for other in resolved.choices where other != index {
            let remaining = resolved.values(for: other, given: selection)
            if let current = selection[other], !remaining.contains(where: { $0.value == current }) { selection[other] = nil }
            if remaining.count == 1 { selection[other] = remaining[0].value }
        }
    }

    private func apply(_ pick: DebugCheckoutScript.Pick, to resolved: ShopifyProduct) {
        for (name, value) in pick.options {
            if let index = resolved.options.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                select(value, at: index, in: resolved)
            }
        }
        quantity = pick.quantity
        guard let variant = resolved.variant(for: selection), variant.available else {
            CheckoutLog.record("debug-pick-failed", store: link.host, note: "selection=\(selection)")
            return
        }
        do {
            try cart.add(product, resolved: resolved, variant: variant, quantity: quantity)
            CheckoutLog.record("added", store: link.host, note: "variant=\(variant.id) title=\(variant.title) qty=\(quantity)")
            dismiss()
        } catch { failure = error.localizedDescription }
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
