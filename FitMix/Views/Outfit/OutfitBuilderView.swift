import SwiftUI

struct OutfitBuilderView: View {
    @Environment(AuthSession.self) private var auth
    @Environment(AvatarStore.self) private var avatar
    @Environment(\.dismiss) private var dismiss

    @State private var signIn = false
    @State private var setup: SetupStep?

    var body: some View {
        NavigationStack {
            Group {
                if let user = auth.user {
                    OutfitBuilderContent(
                        wardrobe: WardrobeStore(client: auth.client, ownerID: user.id),
                        openAvatar: { setup = avatar.resumeStep }
                    )
                    .id(user.id)
                } else if case .restoring = auth.state {
                    ProgressView("Opening Outfit…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            WardrobeMessage(icon: "tshirt", title: "Style your avatar",
                                            message: "Sign in to build an outfit with clothes from your Wardrobe.")
                            Button("Sign In") { signIn = true }.buttonStyle(FMFilledButtonStyle())
                        }
                        .padding(18)
                    }
                }
            }
            .background(Color.wardrobeBackground)
            .navigationTitle("Outfit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .fullScreenCover(isPresented: $signIn) {
            AccountFlowView { _ in signIn = false }
        }
        .fullScreenCover(item: $setup) { SetupFlowView(startAt: $0) }
    }
}

private struct OutfitBuilderContent: View {
    @Environment(AvatarStore.self) private var avatar
    @Environment(AuthSession.self) private var auth
    @Environment(AvatarOutfitSelection.self) private var selection

    @State var wardrobe: WardrobeStore
    var openAvatar: () -> Void

    @State private var picking: AvatarOutfitSlot?
    @State private var consent = false
    @State private var attempt: UUID?
    @State private var rendered: UIImage?
    @State private var failure: String?

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    private var chosen: [(AvatarOutfitSlot, WardrobeItem)] {
        AvatarOutfitSlot.allCases.compactMap { slot in
            selection.item(in: slot, from: wardrobe.items).map { (slot, $0) }
        }
    }

    private var revisions: [UUID] { chosen.map { $0.1.photoRevision } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FMTitleLine(title: "Style Your Avatar", caption: "Outfit builder")
                avatarPreview

                if let error = wardrobe.loadError {
                    WardrobeRetry(message: error) { await wardrobe.load() }
                } else if wardrobe.loading && wardrobe.items.isEmpty {
                    ProgressView("Loading your wardrobe…")
                }

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(AvatarOutfitSlot.allCases) { slot in
                        slotCard(slot, item: selection.item(in: slot, from: wardrobe.items))
                    }
                }

                if let failure {
                    Text(failure).font(.subheadline).foregroundStyle(Color.fmError)
                        .accessibilityIdentifier("outfit-preview-error")
                }
                if avatar.avatarImage == nil {
                    Button("Create My Avatar", action: openAvatar).buttonStyle(FMFilledButtonStyle())
                } else {
                    Button {
                        consent = true
                    } label: {
                        if attempt != nil {
                            HStack { ProgressView().tint(.white); Text("Generating Preview…") }
                        } else {
                            Label(failure == nil ? "Generate AI Preview" : "Retry AI Preview", systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(FMFilledButtonStyle())
                    .disabled(chosen.isEmpty || attempt != nil)
                    .accessibilityIdentifier("outfit-generate")
                }
            }
            .padding(18)
        }
        .task { await wardrobe.load() }
        .refreshable { await wardrobe.load() }
        .sheet(item: $picking) { slot in
            OutfitSlotPicker(slot: slot, wardrobe: wardrobe)
        }
        .confirmationDialog("Send photos for this preview?", isPresented: $consent, titleVisibility: .visible) {
            Button("Generate Preview") { attempt = UUID() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your accepted avatar portrait and selected clothing photos will be sent to the FitMix backend and OpenAI to create this preview.")
        }
        .task(id: attempt) {
            guard let id = attempt else { return }
            await generate(id: id)
        }
        .onChange(of: revisions) { clearResult() }
        .onChange(of: avatar.avatarImage) { clearResult() }
    }

    private var avatarPreview: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18).fill(Color.fmStudio)
            if let image = rendered ?? avatar.avatarImage {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(rendered == nil ? "Your accepted avatar" : "Your avatar in the selected outfit")
                Text(rendered == nil ? "Your Avatar" : "AI Outfit Preview")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white, in: Capsule())
                    .padding(10)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.rectangle").font(.system(size: 34))
                    Text("Create an avatar to preview outfits").font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(Color.fmSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            }
        }
        .frame(height: 282)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func slotCard(_ slot: AvatarOutfitSlot, item: WardrobeItem?) -> some View {
        VStack(spacing: 0) {
            Button { picking = slot } label: {
                VStack(alignment: .leading, spacing: 6) {
                    if let item {
                        WardrobeRemotePhoto(path: item.thumbnailPath, repository: wardrobe.repository, height: 80)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: slot == .outerwear ? "hanger" : slot.category.garment.symbol)
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(Color.fmCobalt)
                            .frame(maxWidth: .infinity).frame(height: 80)
                            .background(Color.fmCobalt.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityHidden(true)
                    }
                    Text(slot.title).font(.subheadline.weight(.semibold))
                    Text(item?.title ?? "Add from Wardrobe")
                        .font(.caption)
                        .foregroundStyle(item == nil ? Color.fmCobalt : Color.fmSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("outfit-slot-\(slot.rawValue)")
            if item != nil {
                Button("Remove", systemImage: "minus.circle") { selection.remove(slot) }
                    .font(.caption.weight(.medium))
                    .frame(minHeight: 36)
                    .accessibilityLabel("Remove \(slot.title)")
            }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.fmHairline).allowsHitTesting(false))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func clearResult() {
        attempt = nil
        rendered = nil
        failure = nil
    }

    private func generate(id: UUID) async {
        let garments = chosen
        guard let portrait = avatar.avatarImage, let ownerID = auth.user?.id, !garments.isEmpty else {
            if attempt == id { attempt = nil }
            return
        }
        rendered = nil
        failure = nil
        defer { if attempt == id { attempt = nil } }
        do {
            let generator = BackendAvatarGenerator(config: .current)
            guard generator.config != nil else {
                throw AvatarGenerationError.service("Outfit previews aren’t set up in this build of FitMix.")
            }
            guard let portraitData = await portrait.uploadJPEG(maxDimension: 1536) else {
                throw WardrobeError.invalidPhoto
            }
            var references: [(AvatarOutfitSlot, Data)] = []
            for (slot, item) in garments {
                let data = try await wardrobe.repository.photo(at: item.tryOnPath)
                guard let photo = UIImage(data: data), let jpeg = await photo.uploadJPEG(maxDimension: 1200) else {
                    throw WardrobeError.invalidPhoto
                }
                references.append((slot, jpeg))
            }
            try Task.checkCancellation()
            guard attempt == id, auth.user?.id == ownerID, avatar.avatarImage === portrait else { return }
            let data = try await generator.style(portrait: portraitData, garments: references)
            guard !Task.isCancelled, attempt == id, auth.user?.id == ownerID, avatar.avatarImage === portrait else { return }
            guard let result = UIImage(data: data) else { throw AvatarGenerationError.invalidResponse }
            rendered = result
        } catch {
            guard !Task.isCancelled, attempt == id else { return }
            failure = error.localizedDescription
        }
    }
}

private struct OutfitSlotPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AvatarOutfitSelection.self) private var selection
    let slot: AvatarOutfitSlot
    let wardrobe: WardrobeStore
    @State private var add = false

    var body: some View {
        NavigationStack {
            List {
                Button("Add Clothing", systemImage: "plus") { add = true }
                if let failure = wardrobe.loadError {
                    WardrobeRetry(message: failure) { await wardrobe.load() }
                }
                let items = wardrobe.items.filter { $0.category == slot.category }
                if items.isEmpty && !wardrobe.loading {
                    Text("No items in this category yet.").foregroundStyle(Color.fmSecondary)
                }
                ForEach(items) { item in
                    Button {
                        selection.choose(item)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            WardrobeRemotePhoto(path: item.thumbnailPath, repository: wardrobe.repository, height: 54)
                                .frame(width: 54)
                                .accessibilityHidden(true)
                            Text(item.title).foregroundStyle(Color.fmInk)
                            Spacer()
                            if selection.itemIDs[slot] == item.id {
                                Image(systemName: "checkmark").foregroundStyle(Color.fmCobalt)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(slot.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $add) {
                NavigationStack {
                    WardrobePhotoReview(store: wardrobe, initialCategory: slot.category) { item in
                        selection.choose(item)
                    }
                }
            }
        }
    }
}
