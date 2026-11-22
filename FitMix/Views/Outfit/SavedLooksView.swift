import SwiftUI

struct SavedLooksView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AuthSession.self) private var auth
    @Environment(SavedLookStore.self) private var library
    @Environment(AvatarOutfitSelection.self) private var outfit
    @Environment(CartStore.self) private var cart
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selected: SavedLook?
    @State private var openBuilder = false

    /// How many looks are kept, and where: "3 looks · Saved on this iPhone".
    private var summary: String {
        if library.looks.isEmpty { return "Outfits you want to come back to" }
        return "\(library.looks.count == 1 ? "1 look" : "\(library.looks.count) looks") · Saved on this iPhone"
    }

    var body: some View {
        VStack(spacing: 0) {
        // The same top bar as Home and Studio, so every tab opens the same way.
        FMTopBar { FMBagButton(count: cart.count) { router.openCart() } }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                FMPageHeading(title: "Saved Looks", detail: summary)
                if let error = library.error {
                    WardrobeRetry(message: error) { library.reload() }
                } else if case .restoring = auth.state {
                    ProgressView("Opening saved looks…").frame(maxWidth: .infinity, minHeight: 140)
                } else if library.looks.isEmpty {
                    WardrobeMessage(icon: "bookmark", title: "Keep a look you love",
                                    message: "Save a preview from the outfit builder or Studio to find it here.")
                    Button(auth.user == nil ? "Sign In" : "Build a Look") {
                        if auth.user == nil { router.openAccount() } else { router.showOutfit = true }
                    }
                    .buttonStyle(FMFilledButtonStyle())
                    // Looks are also saved from a scan, so that way in is offered too.
                    Button("Scan an Outfit", systemImage: "camera.viewfinder", action: router.openCamera)
                        .buttonStyle(FMOutlineButtonStyle())
                        .accessibilityIdentifier("saved-scan")
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                             count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                        ForEach(library.looks) { look in
                            Button { selected = look } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    SavedLookPhoto(url: library.imageURL(for: look, thumbnail: true))
                                        .frame(height: 205)
                                    Text(look.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.fmInk)
                                    Text("\(look.itemCount) · \(look.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption).foregroundStyle(Color.fmSecondary)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("saved-look-\(look.id.uuidString)")
                        }
                    }
                }
            }
            .padding(18)
        }
        }
        .background(Color.fmCanvas)
        .sheet(item: $selected, onDismiss: {
            if openBuilder {
                openBuilder = false
                router.showOutfit = true
            }
        }) { look in
            SavedLookDetail(look: look) {
                outfit.restore(look.pieces)
                openBuilder = true
                selected = nil
            }
        }
        .onChange(of: auth.user?.id) {
            selected = nil
            openBuilder = false
        }
    }
}

private struct SavedLookDetail: View {
    @Environment(SavedLookStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let look: SavedLook
    let reuse: () -> Void
    @State private var confirmRemove = false
    @State private var removeFailed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FMPageHeading(title: look.title, detail: look.createdAt.formatted(date: .long, time: .omitted))
                    SavedLookPhoto(url: library.imageURL(for: look)).frame(height: 380)
                    if !look.pieces.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("In this look").font(.headline)
                            ForEach(Array(look.pieces.enumerated()), id: \.offset) { _, piece in
                                Label(piece.name, systemImage: piece.slot?.category.garment.symbol ?? "hanger")
                            }
                        }
                        .fmCard()
                    }
                    if removeFailed { NoticeRow(tone: .caution, text: "Couldn't remove this saved look. Try again.") }
                }
                .padding(18)
            }
            .background(Color.fmCanvas)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if look.canReuse {
                    FMActionShelf {
                        Button("Use This Outfit", systemImage: "hanger", action: reuse).buttonStyle(FMFilledButtonStyle())
                    }
                }
            }
            .navigationTitle("Saved Look")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Remove Saved Look", systemImage: "trash", role: .destructive) { confirmRemove = true }
                }
            }
            .confirmationDialog("Remove this saved look?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove Look", role: .destructive) {
                    do {
                        try library.remove(look)
                        dismiss()
                    } catch {
                        removeFailed = true
                    }
                }
            }
        }
    }
}

private struct SavedLookPhoto: View {
    let url: URL?
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.fmStudio
            if let image {
                Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Saved outfit preview")
            } else if failed {
                Image(systemName: "photo").foregroundStyle(Color.fmSecondary).accessibilityLabel("Preview unavailable")
            } else {
                ProgressView()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: url) {
            failed = false
            image = nil
            let loaded = await Task.detached(priority: .utility) {
                url.flatMap { UIImage(contentsOfFile: $0.path(percentEncoded: false)) }
            }.value
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
    }
}
