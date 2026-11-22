import SwiftUI

extension Color {
    static let wardrobeBackground = Color.fmCanvas
}

struct WardrobeView: View {
    @Environment(AuthSession.self) private var auth
    @Environment(AppRouter.self) private var router
    @Environment(CartStore.self) private var cart

    var body: some View {
        VStack(spacing: 0) {
            // The same top bar as Home and Studio, so every tab opens the same way.
            FMTopBar { FMBagButton(count: cart.count) { router.openCart() } }
            if let user = auth.user {
                WardrobeCollection(store: WardrobeStore(client: auth.client, ownerID: user.id))
                    .id(user.id)
            } else if case .restoring = auth.state {
                ProgressView("Opening Wardrobe…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        FMPageHeading(title: "Wardrobe")
                        WardrobeMessage(icon: "tshirt", title: "Sign in to your wardrobe",
                                        message: "Save your clothes and find them again when you return.")
                        Button("Sign In") { router.openAccount() }.buttonStyle(FMFilledButtonStyle())
                    }
                    .padding(20)
                }
            }
        }
        .background(Color.wardrobeBackground)
        .onChange(of: router.addClothing, initial: true) { openSignInForAdd() }
        .onChange(of: auth.state) { openSignInForAdd() }
    }

    private func openSignInForAdd() {
        if router.addClothing, case .signedOut = auth.state {
            router.addClothing = false
            router.openAccount()
        }
    }
}

private struct WardrobeCollection: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var typeSize
    @State var store: WardrobeStore
    @State private var filter: WardrobeCategory?
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var add = false
    @State private var selected: WardrobeItem?
    @State private var openOutfitAfterDetails = false

    private var visibleItems: [WardrobeItem] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.items.filter { item in
            (filter == nil || item.category == filter)
                && (search.isEmpty || item.title.localizedStandardContains(search)
                    || item.category.title.localizedStandardContains(search))
        }
    }

    /// What the wardrobe holds, under the title: "12 pieces", or what the page is for while it is empty.
    private var summary: String {
        if store.items.isEmpty { return store.loading ? "Loading your clothes…" : "Your own clothes, ready to try on" }
        return store.items.count == 1 ? "1 piece" : "\(store.items.count) pieces"
    }

    var body: some View {
        VStack(spacing: 0) {
            FMPageHeading(title: "Wardrobe", detail: summary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
            collection
            FMActionShelf {
                Button("Add Clothing", systemImage: "plus") { add = true }
                    .buttonStyle(FMFilledButtonStyle())
                    .accessibilityIdentifier("wardrobe-add")
            }
        }
        .onChange(of: router.addClothing, initial: true) {
            guard router.addClothing else { return }
            router.addClothing = false
            add = true
        }
        .task { await store.load() }
        .sheet(isPresented: $add, onDismiss: refresh) {
            NavigationStack {
                WardrobePhotoReview(store: store) { item in
                    query = ""
                    if filter != nil { filter = item.category }
                }
            }
        }
        .sheet(item: $selected, onDismiss: detailClosed) { item in
            NavigationStack {
                WardrobeDetailView(item: item, store: store) { openOutfitAfterDetails = true }
            }
        }
    }

    private var collection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !store.items.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").accessibilityHidden(true)
                        TextField("Find clothing", text: $query)
                            .foregroundStyle(Color.fmInk)
                            .focused($searchFocused)
                            .submitLabel(.search)
                            .onSubmit { searchFocused = false }
                        if !query.isEmpty {
                            Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                                .labelStyle(.iconOnly).frame(width: 44, height: 44)
                        }
                    }
                    .padding(.leading, 13).frame(minHeight: 46)
                    .foregroundStyle(Color.fmSecondary)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
                    ScrollView(.horizontal) {
                        HStack(spacing: 7) {
                            filterChip(nil, title: "All")
                            ForEach(WardrobeCategory.allCases) { filterChip($0, title: $0.title) }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                if let loadError = store.loadError {
                    WardrobeRetry(message: loadError) { await store.load() }
                }
                if store.cleanupPending, store.loadError == nil {
                    WardrobeRetry(message: "Some old photos are still queued for removal.") { await store.cleanUp() }
                }
                if store.loading && store.items.isEmpty {
                    ProgressView("Loading clothes…").frame(maxWidth: .infinity, minHeight: 140)
                } else if visibleItems.isEmpty {
                    if !store.items.isEmpty {
                        WardrobeMessage(icon: "magnifyingglass", title: "No matching clothes",
                                        message: "Try a different search or category.")
                        Button("Clear Filters") {
                            query = ""
                            filter = nil
                        }
                        .buttonStyle(FMOutlineButtonStyle())
                    } else if store.loadError == nil {
                        WardrobeMessage(icon: filter?.garment.symbol ?? "tshirt",
                                        title: filter == nil ? "Your wardrobe is empty" : "Nothing in this category",
                                        message: filter == nil ? "Take a photo of something you own or pick one from your library." : nil)
                        if filter == nil { WardrobePhotoTips() }
                    }
                } else {
                    Text(visibleItems.count == 1 ? "1 item" : "\(visibleItems.count) items")
                        .font(.caption.weight(.medium)).foregroundStyle(Color.fmSecondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                             count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                        ForEach(visibleItems) { item in
                            Button { selected = item } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    WardrobeRemotePhoto(path: item.thumbnailPath, repository: store.repository,
                                                        height: 160)
                                        .accessibilityHidden(true)
                                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    Text(item.category.title).font(.caption).foregroundStyle(Color.fmSecondary)
                                }
                                .padding(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.fmHairline))
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("wardrobe-item-\(item.id.uuidString)")
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await store.load() }
    }

    private func detailClosed() {
        refresh()
        if openOutfitAfterDetails {
            openOutfitAfterDetails = false
            router.showOutfit = true
        }
    }

    private func refresh() {
        Task { await store.load() }
    }

    private func filterChip(_ category: WardrobeCategory?, title: String) -> some View {
        let selected = filter == category
        return Button { filter = category } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Color.white : Color.fmInk)
                .padding(.horizontal, 8)
                .frame(minWidth: 44, minHeight: 44)
                .background(selected ? Color.fmCobalt : .white, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.clear : Color.fmHairline))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct WardrobeRemotePhoto: View {
    let path: String
    let repository: WardrobeRepository
    let height: CGFloat

    @State private var image: UIImage?
    @State private var failed = false
    @State private var retry = 0

    var body: some View {
        VStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Text("Photo unavailable").font(.caption2)
                }
                .foregroundStyle(Color.fmSecondary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: path + String(retry)) {
            image = nil
            failed = false
            do {
                let data = try await repository.photo(at: path)
                try Task.checkCancellation()
                guard let decoded = UIImage(data: data) else { throw WardrobeError.invalidPhoto }
                image = decoded
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
        .contextMenu {
            if failed { Button("Retry Photo", systemImage: "arrow.clockwise") { retry += 1 } }
        }
        .accessibilityLabel(failed ? "Photo unavailable" : "Garment photo")
    }
}

/// Shown with an empty wardrobe: what makes a clothing photo work, before the first one is taken.
struct WardrobePhotoTips: View {
    private let tips = [("square.dashed", "One piece per photo"),
                        ("rectangle.portrait", "Laid flat or on a hanger"),
                        ("sun.max", "Plain background, even light")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FOR A GOOD PHOTO").font(.fmEyebrow).tracking(1.1).foregroundStyle(Color.fmCobaltDeep)
            ForEach(tips, id: \.1) { icon, text in
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.fmCobaltDeep)
                        .frame(width: 30, height: 30)
                        .background(Color.fmCobalt.opacity(0.10), in: Circle())
                        .accessibilityHidden(true)
                    Text(text).font(.subheadline).foregroundStyle(Color.fmInk)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.fmHairline))
        .accessibilityElement(children: .combine)
    }
}

struct WardrobeMessage: View {
    let icon: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(Color.fmCobalt)
                .frame(width: 64, height: 64)
                .background(Color.fmCobalt.opacity(0.08), in: Circle())
                .accessibilityHidden(true)
            Text(title).font(.fmDisplay(22, relativeTo: .title2))
            if let message {
                Text(message).font(.subheadline).foregroundStyle(Color.fmSecondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.fmHairline))
    }
}

struct WardrobeRetry: View {
    let message: String
    var title = "Retry"
    var action: () async -> Void
    @State private var retrying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Button {
                retrying = true
                Task {
                    await action()
                    retrying = false
                }
            } label: {
                if retrying { ProgressView() } else { Text(title).fontWeight(.semibold) }
            }
            .disabled(retrying)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fmCobalt.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}
