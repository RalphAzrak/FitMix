import SwiftUI

extension Color {
    static let wardrobeBackground = Color(hex: 0xFAF8F4)
}

struct WardrobeView: View {
    @Environment(AuthSession.self) private var auth
    @Environment(AppRouter.self) private var router
    @Environment(CartStore.self) private var cart

    var body: some View {
        VStack(spacing: 0) {
            FMTopBar { FMBagButton(count: cart.count) { router.showCart = true } }
            if let user = auth.user {
                WardrobeCollection(store: WardrobeStore(client: auth.client, ownerID: user.id))
                    .id(user.id)
            } else if case .restoring = auth.state {
                ProgressView("Opening Wardrobe…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        FMTitleLine(title: "Wardrobe", caption: "Your clothes")
                        WardrobeMessage(icon: "tshirt", title: "Sign in to your wardrobe",
                                        message: "Save your clothes and find them again when you return.")
                        Button("Sign In") { router.openAccount() }.buttonStyle(FMFilledButtonStyle())
                    }
                    .padding(20)
                }
            }
        }
        .background(Color.wardrobeBackground)
    }
}

private struct WardrobeCollection: View {
    @Environment(AppRouter.self) private var router
    @State var store: WardrobeStore
    @State private var filter: WardrobeCategory?
    @State private var add = false
    @State private var selected: WardrobeItem?
    @State private var openOutfitAfterDetails = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var visibleItems: [WardrobeItem] {
        guard let filter else { return store.items }
        return store.items.filter { $0.category == filter }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FMTitleLine(title: "Wardrobe", caption: "Your clothes")
                Button { add = true } label: {
                    Label("Add Clothing", systemImage: "plus")
                }
                .buttonStyle(FMFilledButtonStyle())
                .accessibilityIdentifier("wardrobe-add")
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        filterChip(nil, title: "All")
                        ForEach(WardrobeCategory.allCases) { filterChip($0, title: $0.title) }
                    }
                }
                .scrollIndicators(.hidden)
                if let loadError = store.loadError {
                    WardrobeRetry(message: loadError) { await store.load() }
                }
                if store.cleanupPending, store.loadError == nil {
                    WardrobeRetry(message: "Some old photos are still queued for removal.") { await store.cleanUp() }
                }
                if store.loading && store.items.isEmpty {
                    ProgressView("Loading clothes…").frame(maxWidth: .infinity, minHeight: 140)
                } else if visibleItems.isEmpty {
                    if store.loadError == nil {
                        WardrobeMessage(icon: filter?.garment.symbol ?? "tshirt",
                                        title: filter == nil ? "Your wardrobe is empty" : "Nothing in this category",
                                        message: filter == nil ? "Take a photo of something you own or pick one from your library." : nil)
                    }
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(visibleItems) { item in
                            Button { selected = item } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    WardrobeRemotePhoto(path: item.thumbnailPath, repository: store.repository,
                                                        height: 145)
                                        .accessibilityHidden(true)
                                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(item.category.title).font(.caption).foregroundStyle(Color.fmSecondary)
                                }
                                .padding(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.fmHairline))
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .task { await store.load() }
        .refreshable { await store.load() }
        .sheet(isPresented: $add, onDismiss: refresh) {
            NavigationStack { WardrobePhotoReview(store: store) }
        }
        .sheet(item: $selected, onDismiss: detailClosed) { item in
            NavigationStack {
                WardrobeDetailView(item: item, store: store) { openOutfitAfterDetails = true }
            }
        }
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
        .background(.white, in: RoundedRectangle(cornerRadius: 20))
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
