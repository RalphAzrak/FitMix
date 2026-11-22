import OSLog
import SwiftUI

struct WardrobePhotoReview: View {
    let store: WardrobeStore
    var replacing: WardrobeItem?
    var initialCategory: WardrobeCategory?
    var fromOutfit = false
    var onSaved: (WardrobeItem) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var newID = UUID()
    @State private var attempt: UUID?
    @State private var request: PhotoSourceKind?
    @State private var showSources = false
    @State private var showCrop = false
    @State private var picked: UIImage?
    @State private var crop = WardrobePhotoProcessor.fullPhoto
    @State private var photoID = UUID()
    @State private var processed: WardrobePhotoProcessor.Preview?
    @State private var processedKey: Preparation?
    @State private var preferCleaned = true
    @State private var viewingOriginal = false
    @State private var category: WardrobeCategory?
    @State private var categoryWasEdited = false
    @State private var catalogRetry = UUID()
    @State private var completedCatalog: CatalogRequest?
    @State private var catalogImage: UIImage?
    @State private var suggestedCategory: WardrobeCategory?
    @State private var catalogMessage: String?
    @State private var name = ""
    @State private var saving = false
    @State private var saveError: String?

    private static let log = Logger(subsystem: "app.fitmix", category: "ImagePreviews")

    private struct Preparation: Equatable {
        let photoID: UUID
        let shoes: Bool
    }

    private struct CatalogRequest: Equatable {
        let photoID: UUID
        let retry: UUID
    }

    private var preparation: Preparation { Preparation(photoID: photoID, shoes: category == .shoes) }
    private var catalogRequest: CatalogRequest? {
        picked.map { _ in CatalogRequest(photoID: photoID, retry: catalogRetry) }
    }
    private var polishing: Bool { catalogRequest != nil && catalogRequest != completedCatalog }
    private var locked: Bool { saving || attempt != nil }

    private var preview: WardrobePhotoProcessor.Preview? {
        guard processedKey == preparation, let processed else { return nil }
        return WardrobePhotoProcessor.Preview(original: processed.original, cleaned: catalogImage ?? processed.cleaned)
    }

    private var canSave: Bool { preview != nil && category != nil && (!polishing || !preferCleaned) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let picked {
                    comparison(picked)
                    if let suggestedCategory, category == suggestedCategory {
                        Label("Suggested category · \(suggestedCategory.title)", systemImage: "tag")
                            .font(.subheadline)
                            .foregroundStyle(Color.fmSecondary)
                    }
                    WardrobeFields(name: $name, category: Binding(
                        get: { category },
                        set: {
                            category = $0
                            categoryWasEdited = true
                        }
                    ))
                    .disabled(locked)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { editingActions }
                        VStack(alignment: .leading, spacing: 0) { editingActions }
                    }
                    .font(.subheadline.weight(.semibold))
                    .disabled(locked)
                    if let saveError {
                        WardrobeRetry(message: saveError, title: "Retry Save") { await save() }
                    }
                } else {
                    WardrobeMessage(icon: "camera", title: replacing == nil ? "Photograph your clothing" : "Choose a replacement photo",
                                        message: "Fill the frame with one garment or a pair of shoes.")
                    Text("FitMix sends the photo you choose to OpenAI to polish it and suggest a category.")
                        .font(.footnote)
                        .foregroundStyle(Color.fmSecondary)
                    Button("Take Photo", systemImage: "camera") { request = .camera }
                        .buttonStyle(FMFilledButtonStyle())
                    Button("Choose from Photos", systemImage: "photo.on.rectangle") { request = .library }
                        .buttonStyle(FMOutlineButtonStyle())
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if picked != nil {
                FMActionShelf {
                    Button { Task { await save() } } label: {
                        if saving { ProgressView().tint(.white).accessibilityLabel("Saving photos") }
                        else { Text(replacing == nil ? "Save to Wardrobe" : "Save Replacement") }
                    }
                    .buttonStyle(FMFilledButtonStyle())
                    .disabled(!canSave || saving)
                    .accessibilityIdentifier("wardrobe-save-photo")
                }
            }
        }
        .background(Color.wardrobeBackground)
        .navigationTitle(replacing == nil ? (fromOutfit ? "Add Outfit" : "Add Clothing") : "Replace Photo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.disabled(saving)
            }
        }
        .interactiveDismissDisabled(saving)
        .photoPicker(request: $request, camera: .rear, onImage: usePhoto)
        .sheet(isPresented: $showCrop) {
            if let picked {
                WardrobeCropView(image: picked, initialCrop: crop) { adjusted in
                    guard adjusted != crop else { return }
                    crop = adjusted
                    beginSelection()
                }
            }
        }
        .confirmationDialog("Choose a clothing photo", isPresented: $showSources, titleVisibility: .visible) {
            Button("Take Photo") { request = .camera }
            Button("Choose from Photos") { request = .library }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("FitMix sends the selected photo to its server and OpenAI for polishing.")
        }
        .onAppear {
            if picked == nil {
                name = replacing?.name ?? ""
                category = replacing?.category ?? initialCategory
            }
        }
        .task(id: preparation) {
            guard let picked else { return }
            let key = preparation
            let output = await WardrobePhotoProcessor.prepare(picked, category: category ?? .tshirt, crop: crop)
            guard !Task.isCancelled, preparation == key else { return }
            processed = output
            processedKey = key
        }
        .task(id: catalogRequest) {
            guard let request = catalogRequest, request != completedCatalog, let picked else { return }
            await polish(picked, crop: crop, request: request)
        }
    }

    @ViewBuilder
    private var editingActions: some View {
        Button("Adjust Crop", systemImage: "crop") { showCrop = true }.frame(minHeight: 44)
        Button("Change Photo", systemImage: "camera") { showSources = true }.frame(minHeight: 44)
    }

    private func comparison(_ source: UIImage) -> some View {
        let polished = (polishing ? catalogImage : preview?.cleaned)
        let showingPolished = !viewingOriginal && polished != nil
        return VStack(alignment: .leading, spacing: 10) {
            Text(showingPolished ? "Polished Photo" : "Original Photo")
                .font(.headline).accessibilityAddTraits(.isHeader)
            Image(uiImage: viewingOriginal ? source : (polished ?? source))
                .resizable().scaledToFit()
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical) { height, _ in min(350, max(225, height * 0.48)) }
                .background(.white, in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel(showingPolished ? "Polished garment photo" : "Original garment photo")
            if polishing {
                ProgressView("Polishing your photo…").font(.subheadline)
            }
            if let catalogMessage, !polishing {
                WardrobeRetry(message: catalogMessage) { catalogRetry = UUID() }
                    .disabled(locked)
            }
            if polished != nil || polishing || (catalogMessage != nil && preferCleaned) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { photoActions(canShowPolished: polished != nil) }
                    VStack(alignment: .leading, spacing: 8) { photoActions(canShowPolished: polished != nil) }
                }
                .font(.subheadline.weight(.semibold))
                .disabled(locked)
            }
        }
    }

    @ViewBuilder
    private func photoActions(canShowPolished: Bool) -> some View {
        if canShowPolished {
            Button(viewingOriginal ? "View Polished" : "View Original") { viewingOriginal.toggle() }
                .frame(minHeight: 44)
        }
        if preferCleaned || canShowPolished {
            Button(preferCleaned ? "Use Original" : "Use Polished") {
                preferCleaned.toggle()
                viewingOriginal = !preferCleaned
            }
            .frame(minHeight: 44)
        }
    }

    private func usePhoto(_ image: UIImage) {
        picked = image
        crop = WardrobePhotoProcessor.fullPhoto
        beginSelection()
    }

    private func beginSelection() {
        photoID = UUID()
        processed = nil
        catalogImage = nil
        suggestedCategory = nil
        catalogMessage = nil
        saveError = nil
        if !categoryWasEdited { category = replacing?.category ?? initialCategory }
        preferCleaned = true
        viewingOriginal = false
    }

    private func polish(_ image: UIImage, crop: CGRect, request: CatalogRequest) async {
        let start = ContinuousClock.now
        defer {
            if !Task.isCancelled, request == catalogRequest { completedCatalog = request }
        }
        do {
            let backend = BackendAvatarGenerator(config: .current, ownerID: store.repository.ownerID)
            guard backend.config != nil else {
                throw AvatarGenerationError.service("Photo polishing isn’t available right now. You can save the original.")
            }
            guard let jpeg = await WardrobePhotoProcessor.catalogJPEG(image, crop: crop) else { throw WardrobeError.invalidPhoto }
            try Task.checkCancellation()
            Self.log.info("Wardrobe preparation \(start.duration(to: .now).description, privacy: .public), \(jpeg.count) bytes")
            let result = try await backend.catalogPhoto(jpeg)
            guard !Task.isCancelled, request == catalogRequest else { return }
            suggestedCategory = result.category
            if let suggestedCategory, !categoryWasEdited { category = suggestedCategory }
            if let data = result.image {
                guard let photo = UIImage(data: data) else { throw AvatarGenerationError.invalidResponse }
                catalogImage = photo
                Self.log.info("Wardrobe preview ready in \(start.duration(to: .now).description, privacy: .public)")
            }
            catalogMessage = result.message
        } catch {
            guard !Task.isCancelled, request == catalogRequest else { return }
            catalogMessage = error.localizedDescription
        }
    }

    private func save() async {
        guard !saving, canSave, let preview, let category else { return }
        saving = true
        saveError = nil
        defer { saving = false }
        do {
            let item = try await persist(preview, category: category)
            await store.apply(item)
            onSaved(item)
            dismiss()
            await store.cleanUp()
        } catch {
            saveError = (error as? WardrobeError)?.errorDescription
                ?? "Couldn’t save your clothing. Check your connection and try again."
        }
    }

    private func persist(_ preview: WardrobePhotoProcessor.Preview, category: WardrobeCategory) async throws -> WardrobeItem {
        let id = replacing?.id ?? newID
        if let attempt, let saved = try await store.repository.recoverPhoto(id: id, revision: attempt) { return saved }
        let photos = try await WardrobePhotoProcessor.files(from: preview, preferCleaned: preferCleaned)
        let revision = UUID()
        attempt = revision
        return try await store.repository.savePhoto(id: id, replacing: replacing, revision: revision,
                                                     details: WardrobeDetails(name: name, category: category), photos: photos)
    }
}

struct WardrobeFields: View {
    @Binding var name: String
    @Binding var category: WardrobeCategory?

    init(name: Binding<String>, category: Binding<WardrobeCategory?>) {
        _name = name
        _category = category
    }

    init(name: Binding<String>, category: Binding<WardrobeCategory>) {
        self.init(name: name, category: Binding<WardrobeCategory?>(
            get: { category.wrappedValue },
            set: { if let value = $0 { category.wrappedValue = value } }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name (optional)", text: $name)
                .textContentType(.none)
                .onChange(of: name) { _, value in
                    if value.unicodeScalars.count > 100 {
                        name = String(String.UnicodeScalarView(value.unicodeScalars.prefix(100)))
                    }
                }
            Divider()
            HStack {
                Text("Category")
                Spacer()
                Picker("Category", selection: $category) {
                    if category == nil { Text("Choose a category").tag(nil as WardrobeCategory?) }
                    ForEach(WardrobeCategory.allCases) { Text($0.title).tag(Optional($0)) }
                }
            }
        }
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
    }
}
