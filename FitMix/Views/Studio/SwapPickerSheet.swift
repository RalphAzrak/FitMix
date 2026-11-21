import SwiftUI

/// Pick a replacement for one garment, from the catalog matches the scan returned for it.
struct SwapPickerSheet: View {
    var piece: WorkingLook.Piece
    @Environment(StudioStore.self) private var studio
    @Environment(\.dismiss) private var dismiss
    /// nil = keep what the photo shows.
    @State private var choice: String?
    @State private var loaded = false

    private var category: String { piece.detected.category.title.lowercased() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    option(id: nil, title: piece.detected.label ?? "As photographed",
                           subtitle: "What the person in the photo is wearing",
                           source: originalSource, tag: nil, price: nil)

                    if piece.alternatives.isEmpty {
                        NoticeRow(tone: .info, text: "No catalog alternatives for this \(category) yet. When the Camera's matching finds some, they'll show here.")
                            .padding(.top, 8)
                    } else {
                        Text("ALTERNATIVES")
                            .font(.system(size: 11, weight: .semibold)).tracking(0.9)
                            .foregroundStyle(AuthPalette.secondary)
                            .padding(.top, 12)
                        ForEach(piece.alternatives) { product in
                            option(id: product.id, title: product.name,
                                   subtitle: product.brand,
                                   source: product.image.tileSource,
                                   tag: product.matchLabel,
                                   price: product.price)
                        }
                    }
                }
                .padding(16)
            }
            .background(AuthPalette.surface)
            .safeAreaInset(edge: .bottom) {
                Button(choice == piece.replacement?.id ? "Done" : "Swap in this piece") {
                    let product = piece.alternatives.first { $0.id == choice }
                    if choice != piece.replacement?.id { studio.swap(pieceID: piece.id, to: product) }
                    dismiss()
                }
                .buttonStyle(AuthPrimaryButtonStyle())
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(AuthPalette.surface)
            }
            .navigationTitle("Swap \(category)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .preferredColorScheme(.light)
        .onAppear {
            guard !loaded else { return }
            choice = piece.replacement?.id
            loaded = true
        }
    }

    private var originalSource: GarmentTile.Source {
        if let cutout = piece.detected.cutout { return .image(cutout) }
        if let crop = piece.detected.crop { return .image(crop) }
        return .none
    }

    private func option(id: String?, title: String, subtitle: String?, source: GarmentTile.Source,
                        tag: String?, price: Price?) -> some View {
        let selected = choice == id
        return Button { choice = id } label: {
            HStack(spacing: 12) {
                GarmentTile(source: source, category: piece.detected.category)
                    .frame(width: 60, height: 66)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(AuthPalette.onSurface)
                            .lineLimit(2)
                        if let tag {
                            Text(tag).font(.system(size: 10, weight: .bold))
                                .foregroundStyle(tag == "Similar" ? AuthPalette.secondary : AuthPalette.primary)
                        }
                    }
                    if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(AuthPalette.secondary) }
                    if id != nil {
                        Text(price?.formatted ?? "Price unavailable")
                            .font(.system(size: 13, weight: price == nil ? .regular : .semibold))
                            .foregroundStyle(price == nil ? AuthPalette.secondary : AuthPalette.onSurface)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? AuthPalette.primaryContainer : AuthPalette.outline)
            }
            .padding(10)
            .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? AuthPalette.primaryContainer : AuthPalette.containerHigh, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
