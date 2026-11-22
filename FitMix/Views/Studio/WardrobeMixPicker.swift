import SwiftUI

/// Which slot the wardrobe picker opens on (nil: every wearable category).
struct WardrobeMixRequest: Identifiable {
    var slot: AvatarOutfitSlot?
    var id: String { slot?.rawValue ?? "all" }
}

/// "Mix with your wardrobe": pick something you own to wear on the avatar with the scanned piece.
/// Shows the wardrobe's shirts, pants, shoes and jackets (accessories can't be worn on the avatar).
struct WardrobeMixPicker: View {
    var request: WardrobeMixRequest
    /// The slot the scanned piece fills, so the picker can say a choice there replaces it.
    var scannedSlot: AvatarOutfitSlot?
    var choose: (WardrobeItem, UIImage) -> Void

    @Environment(AuthSession.self) private var auth
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let user = auth.user {
                    WardrobeMixGrid(store: WardrobeStore(client: auth.client, ownerID: user.id),
                                    slot: request.slot, scannedSlot: scannedSlot) { item, image in
                        choose(item, image)
                        dismiss()
                    }
                    .id(user.id)
                } else {
                    VStack(spacing: 18) {
                        WardrobeMessage(icon: "hanger", title: "Sign in to use your wardrobe",
                                        message: "Your saved clothes can go on your avatar next to the scanned piece.")
                        Button("Sign In") {
                            dismiss()
                            router.openAccount()
                        }
                        .buttonStyle(FMFilledButtonStyle())
                    }
                    .padding(20)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .background(Color.fmCanvas.ignoresSafeArea())
            .navigationTitle("From Your Wardrobe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .accessibilityIdentifier("wardrobeMixPicker")
    }
}

private struct WardrobeMixGrid: View {
    @State var store: WardrobeStore
    @State var slot: AvatarOutfitSlot?
    var scannedSlot: AvatarOutfitSlot?
    var choose: (WardrobeItem, UIImage) -> Void

    @Environment(AuthSession.self) private var auth
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var loadingID: UUID?
    @State private var failure: String?

    private var wearable: [WardrobeItem] {
        store.items.filter { item in
            guard let itemSlot = AvatarOutfitSlot(rawValue: item.category.rawValue) else { return false }
            return slot == nil || itemSlot == slot
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        filterChip(nil)
                        ForEach(AvatarOutfitSlot.bodyOrder) { filterChip($0) }
                    }
                }
                .scrollIndicators(.hidden)

                if let slot, slot == scannedSlot {
                    NoticeRow(tone: .info, text: "Choosing \(slot.family.badgeTitle.lowercased()) here replaces the scanned one on your avatar.")
                        .font(.system(size: 13))
                }
                if let failure { NoticeRow(tone: .caution, text: failure) }
                if let loadError = store.loadError {
                    WardrobeRetry(message: loadError) { await store.load() }
                }

                if store.loading && store.items.isEmpty {
                    ProgressView("Loading your clothes…").frame(maxWidth: .infinity, minHeight: 160)
                } else if wearable.isEmpty {
                    WardrobeMessage(icon: slot.map { _ in "hanger" } ?? "tshirt",
                                    title: slot == nil ? "No clothes to try yet" : "No \(slot!.family.badgeTitle.lowercased()) in your wardrobe",
                                    message: "Add clothes in the Wardrobe tab, then mix them with your scans here.")
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                             count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                        ForEach(wearable) { item in tile(item) }
                    }
                }
            }
            .padding(16)
        }
        .task { await store.load() }
    }

    private func tile(_ item: WardrobeItem) -> some View {
        let family = item.category.garment.family
        return Button { Task { await pick(item) } } label: {
            VStack(alignment: .leading, spacing: 6) {
                WardrobeRemotePhoto(path: item.thumbnailPath, repository: store.repository, height: 150)
                    .overlay(alignment: .topLeading) { GarmentCategoryBadge(item.category.garment).padding(6) }
                    .overlay {
                        if loadingID == item.id {
                            ZStack { Color.white.opacity(0.6); ProgressView() }
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .accessibilityHidden(true)
                Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.fmInk).lineLimit(2)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(family.tint.opacity(0.35), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(loadingID != nil)
        .accessibilityLabel("\(item.title), \(family.badgeTitle)")
        .accessibilityHint("Puts it on your avatar")
        .accessibilityIdentifier("mix-item-\(item.id.uuidString)")
    }

    private func pick(_ item: WardrobeItem) async {
        guard loadingID == nil else { return }
        loadingID = item.id
        failure = nil
        defer { loadingID = nil }
        do {
            let data = try await store.repository.photo(at: item.tryOnPath)
            guard auth.user?.id == item.ownerID else { throw WardrobeError.sessionChanged }
            guard let image = UIImage(data: data) else { throw WardrobeError.invalidPhoto }
            choose(item, image)
        } catch {
            failure = (error as? WardrobeError)?.errorDescription
                ?? "Couldn’t load this piece. Check your connection and try again."
        }
    }

    private func filterChip(_ value: AvatarOutfitSlot?) -> some View {
        let selected = slot == value
        let tint = value?.family.tint ?? Color.fmInk
        return Button { slot = value } label: {
            HStack(spacing: 6) {
                if let value { GarmentGlyph(family: value.family, size: 12) }
                Text(value?.family.badgeTitle ?? "All").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(selected ? .white : tint)
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(selected ? tint : .white, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? .clear : tint.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
