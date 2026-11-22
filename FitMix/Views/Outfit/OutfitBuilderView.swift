import OSLog
import SwiftUI

struct OutfitBuilderView: View {
    @Environment(AuthSession.self) private var auth
    @Environment(AvatarStore.self) private var avatar
    @Environment(\.dismiss) private var dismiss

    @State private var signIn = false
    @State private var setup: SetupStep?
    @State private var editMetrics = false

    var body: some View {
        NavigationStack {
            Group {
                if let user = auth.user {
                    OutfitBuilderContent(
                        wardrobe: WardrobeStore(client: auth.client, ownerID: user.id),
                        changeAvatar: { setup = $0 },
                        editMetrics: { editMetrics = true }
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
        .sheet(isPresented: $editMetrics) { MetricsEditorSheet() }
    }
}

private struct OutfitBuilderContent: View {
    @Environment(AvatarStore.self) private var avatar
    @Environment(AuthSession.self) private var auth
    @Environment(AvatarOutfitSelection.self) private var selection
    @Environment(SavedLookStore.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize

    @State var wardrobe: WardrobeStore
    var changeAvatar: (SetupStep) -> Void
    var editMetrics: () -> Void

    @State private var picking: AvatarOutfitSlot?
    @State private var consent = false
    @State private var attempt: UUID?
    @State private var rendered: (key: String, image: UIImage)?
    @State private var regenerate = false
    @State private var failure: String?
    @State private var show3D = false
    @State private var outfitSnapshot: [WardrobeItem] = []
    private static let log = Logger(subsystem: "app.fitmix", category: "ImagePreviews")

    @State private var saving = false
    @State private var savedImage: UIImage?
    @State private var saveError = false

    private var chosen: [(AvatarOutfitSlot, WardrobeItem)] {
        AvatarOutfitSlot.allCases.compactMap { slot in
            selection.item(in: slot, from: wardrobe.items).map { (slot, $0) }
        }
    }

    private var previewKey: String? {
        guard let portrait = avatar.profile.avatar?.createdAt, !chosen.isEmpty else { return nil }
        let pieces = chosen.map { "\($0.0.rawValue):\($0.1.id):\($0.1.photoRevision)" }
        return "\(portrait.timeIntervalSinceReferenceDate)|" + pieces.joined(separator: "|")
    }

    private var isCurrent: Bool { rendered != nil && rendered?.key == previewKey }
    private var title: String { auth.user?.firstName.map { "Dress \($0)" } ?? "Build a Look" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FMPageHeading(title: title)
                avatarPreview
                Text("Your Pieces").font(.headline).accessibilityAddTraits(.isHeader)
                if let error = wardrobe.loadError {
                    WardrobeRetry(message: error) { await wardrobe.load() }
                } else if wardrobe.loading && wardrobe.items.isEmpty {
                    ProgressView("Loading your wardrobe…")
                } else if selection.itemIDs.count > chosen.count {
                    Text("Some selected clothes are no longer in this wardrobe. Add a replacement below.")
                        .font(.footnote).foregroundStyle(Color.fmSecondary)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                         count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                    ForEach(AvatarOutfitSlot.allCases) { slot in
                        slotCard(slot, item: selection.item(in: slot, from: wardrobe.items))
                    }
                }

            }
            .padding(18)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FMActionShelf {
                VStack(spacing: 8) {
                    if let failure {
                        NoticeRow(tone: .caution, text: failure)
                            .accessibilityIdentifier("outfit-preview-error")
                    }
                    if saveError {
                        NoticeRow(tone: .caution, text: "Couldn't save this look. Try again.")
                    }
                    outfitActions
                }
            }
        }
        .task { await wardrobe.load() }
        .refreshable { await wardrobe.load() }
        .sheet(item: $picking) { slot in
            OutfitSlotPicker(slot: slot, wardrobe: wardrobe)
        }
        .confirmationDialog("Send photos for this preview?", isPresented: $consent, titleVisibility: .visible) {
            Button(isCurrent ? "Regenerate" : "Preview Outfit") {
                regenerate = isCurrent
                attempt = UUID()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your accepted avatar portrait and selected clothing photos will be sent to the FitMix backend and OpenAI to create this preview.")
        }
        .task(id: attempt) {
            guard let id = attempt else { return }
            await generate(id: id)
        }
        .onChange(of: previewKey, initial: true) { restorePreview() }
        .onChange(of: avatar.avatarImage) {
            rendered = nil
            restorePreview()
        }
        .navigationDestination(isPresented: $show3D) {
            AvatarProfileView(changeAvatar: changeAvatar, editMetrics: editMetrics, openAccount: {},
                              outfitSelection: outfitSnapshot)
        }
    }

    @ViewBuilder
    private var outfitActions: some View {
        if avatar.avatarImage == nil {
            Button("Create My Avatar") { changeAvatar(avatar.resumeStep) }.buttonStyle(FMFilledButtonStyle())
        } else if isCurrent, attempt == nil {
            let saved = savedImage != nil && savedImage === rendered?.image
            HStack(spacing: 12) {
                Button {
                    Task { await saveLook() }
                } label: {
                    if saving {
                        ProgressView().tint(.white).accessibilityLabel("Saving look")
                    } else {
                        Label(saved ? "Saved to Looks" : "Save Look", systemImage: saved ? "checkmark" : "bookmark")
                    }
                }
                .buttonStyle(FMFilledButtonStyle())
                .disabled(saving || saved)
                .accessibilityIdentifier("outfit-save")
                FMRoundIconButton(systemName: "arrow.clockwise", label: "Regenerate") { consent = true }
                    .disabled(saving)
            }
        } else {
            Button {
                consent = true
            } label: {
                if attempt != nil {
                    HStack {
                        ProgressView().tint(.white)
                        Text("Putting your look together…")
                    }
                } else {
                    Label(failure == nil ? "Preview Outfit" : "Retry Preview", systemImage: "sparkles")
                }
            }
            .buttonStyle(FMFilledButtonStyle())
            .disabled(chosen.isEmpty || attempt != nil || saving)
            .accessibilityIdentifier("outfit-generate")
        }
    }

    private func saveLook() async {
        guard isCurrent, !saving, let image = rendered?.image, savedImage !== image else { return }
        saving = true
        saveError = false
        defer { saving = false }
        let pieces = chosen.map { SavedLook.Piece(slot: $0.0, itemID: $0.1.id, name: $0.1.title) }
        do {
            _ = try await library.save(image: image, pieces: pieces, ownerID: auth.user?.id)
            savedImage = image
        } catch {
            saveError = true
        }
    }

    private var avatarPreview: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18).fill(Color.fmStudio)
            if let image = rendered?.image ?? avatar.avatarImage {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(rendered == nil ? "Your avatar portrait" : (isCurrent ? "Your outfit preview" : "Previous outfit preview"))
                Text(rendered == nil ? "Your Avatar" : (isCurrent ? "Your Outfit Preview" : "Previous Preview"))
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
        .containerRelativeFrame(.vertical) { height, _ in
            if rendered != nil { return min(440, max(290, height * 0.62)) }
            return min(340, max(230, height * 0.51))
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(alignment: .topTrailing) {
            Button {
                outfitSnapshot = chosen.map { $0.1 }
                show3D = true
            } label: {
                VStack(alignment: .trailing, spacing: 4) {
                    Image(systemName: "cube")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(.white, in: Circle())
                    Text("See on 3D Avatar")
                        .font(.caption2.weight(.semibold))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 94, alignment: .trailing)
                        .padding(5)
                        .background(.white, in: RoundedRectangle(cornerRadius: 5))
                }
                .foregroundStyle(Color.fmCobaltDeep)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("See on 3D Avatar")
            .accessibilityHint("Opens the avatar and lists your selected clothes separately")
            .accessibilityIdentifier("outfit-open-3d")
            .padding(10)
        }
    }

    private func slotCard(_ slot: AvatarOutfitSlot, item: WardrobeItem?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
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
                    if let item { Text(item.title).font(.subheadline).foregroundStyle(Color.fmSecondary).lineLimit(2) }
                    Label(item == nil ? "Add" : "Swap", systemImage: item == nil ? "plus" : "arrow.left.arrow.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.fmCobalt)
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
                    .frame(minHeight: 44)
                    .padding(.horizontal, 10)
                    .accessibilityLabel("Remove \(slot.title)")
            }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.fmHairline).allowsHitTesting(false))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func restorePreview() {
        attempt = nil
        failure = nil
        saveError = false
        if let key = previewKey, let cached = selection.preview(for: key) { rendered = (key, cached) }
    }

    private func generate(id: UUID) async {
        let garments = chosen
        guard let portrait = avatar.avatarImage, let ownerID = auth.user?.id, let key = previewKey else {
            if attempt == id { attempt = nil }
            return
        }
        let start = ContinuousClock.now
        let fresh = regenerate
        failure = nil
        defer { if attempt == id { attempt = nil } }
        do {
            if !fresh, let cached = selection.preview(for: key) {
                rendered = (key, cached)
                return
            }
            let generator = BackendAvatarGenerator(config: .current, ownerID: ownerID)
            guard generator.config != nil else {
                throw AvatarGenerationError.service("Outfit previews aren’t set up in this build of FitMix.")
            }
            async let avatarJPEG = portrait.uploadJPEG(maxDimension: 1280, quality: 0.85)
            let repository = wardrobe.repository
            let references = try await withThrowingTaskGroup(of: (AvatarOutfitSlot, Data).self) { group in
                for (slot, item) in garments {
                    group.addTask {
                        let data = try await repository.photo(at: item.tryOnPath)
                        guard let photo = UIImage(data: data),
                              let jpeg = await photo.uploadJPEG(maxDimension: 1024, quality: 0.82) else {
                            throw WardrobeError.invalidPhoto
                        }
                        return (slot, jpeg)
                    }
                }
                var files: [AvatarOutfitSlot: Data] = [:]
                for try await (slot, data) in group { files[slot] = data }
                return AvatarOutfitSlot.allCases.compactMap { slot in files[slot].map { (slot, $0) } }
            }
            guard let portraitData = await avatarJPEG else { throw WardrobeError.invalidPhoto }
            try Task.checkCancellation()
            guard attempt == id, previewKey == key, auth.user?.id == ownerID, avatar.avatarImage === portrait else { return }
            let bytes = portraitData.count + references.reduce(0) { $0 + $1.1.count }
            Self.log.info("Outfit preparation \(start.duration(to: .now).description, privacy: .public), \(bytes) bytes")
            let data = try await generator.style(portrait: portraitData, garments: references, regenerate: fresh)
            guard !Task.isCancelled, attempt == id, previewKey == key, auth.user?.id == ownerID,
                  avatar.avatarImage === portrait else { return }
            guard let result = UIImage(data: data) else { throw AvatarGenerationError.invalidResponse }
            selection.rememberPreview(result, key: key)
            rendered = (key, result)
            Self.log.info("Outfit preview ready in \(start.duration(to: .now).description, privacy: .public)")
        } catch {
            guard !Task.isCancelled, attempt == id, previewKey == key else { return }
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
    @State private var addedCurrentSlot = false

    var body: some View {
        NavigationStack {
            List {
                Button("Add Outfit", systemImage: "plus") { add = true }
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
            .sheet(isPresented: $add, onDismiss: { if addedCurrentSlot { dismiss() } }) {
                NavigationStack {
                    WardrobePhotoReview(store: wardrobe, initialCategory: slot.category, fromOutfit: true) { item in
                        selection.choose(item)
                        addedCurrentSlot = item.category == slot.category
                    }
                }
            }
        }
    }
}
