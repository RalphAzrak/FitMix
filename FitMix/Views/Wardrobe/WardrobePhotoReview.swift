import SwiftUI

struct WardrobePhotoReview: View {
    let store: WardrobeStore
    var replacing: WardrobeItem?
    var initialCategory: WardrobeCategory = .tshirt
    var onSaved: (WardrobeItem) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var newID = UUID()
    @State private var attempt: UUID?
    @State private var request: PhotoSourceKind?
    @State private var showSources = false
    @State private var picked: UIImage?
    @State private var photoID = UUID()
    @State private var processed: WardrobePhotoProcessor.Preview?
    @State private var processedKey: Preparation?
    @State private var preferCleaned = true
    @State private var category: WardrobeCategory = .tshirt
    @State private var name = ""
    @State private var saving = false
    @State private var saveError: String?

    private struct Preparation: Equatable {
        let photoID: UUID
        let shoes: Bool
    }

    private var preparation: Preparation { Preparation(photoID: photoID, shoes: category == .shoes) }
    private var preview: WardrobePhotoProcessor.Preview? { processedKey == preparation ? processed : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if picked != nil {
                    comparison
                    WardrobeFields(name: $name, category: $category)
                        .disabled(saving || attempt != nil)
                    Button("Retake or Choose Another Photo", systemImage: "camera") { showSources = true }
                        .font(.subheadline.weight(.semibold))
                        .disabled(saving || attempt != nil)
                    if let saveError {
                        WardrobeRetry(message: saveError, title: "Retry Save") { await save() }
                    } else {
                        Button { Task { await save() } } label: {
                            if saving { ProgressView().tint(.white).accessibilityLabel("Uploading photos") }
                            else { Text(replacing == nil ? "Save to Wardrobe" : "Save Replacement") }
                        }
                        .buttonStyle(FMFilledButtonStyle())
                        .disabled(preview == nil || saving)
                    }
                } else {
                    WardrobeMessage(icon: "camera", title: replacing == nil ? "Photograph your clothing" : "Choose a replacement photo",
                                    message: "Lay the item flat with space around it. For shoes, fit both in one photo.")
                    Button("Take Photo", systemImage: "camera") { request = .camera }
                        .buttonStyle(FMFilledButtonStyle())
                    Button("Choose from Photos", systemImage: "photo.on.rectangle") { request = .library }
                        .buttonStyle(FMOutlineButtonStyle())
                }
            }
            .padding(20)
        }
        .background(Color.wardrobeBackground)
        .navigationTitle(replacing == nil ? "Add Clothing" : "Replace Photo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.disabled(saving)
            }
        }
        .interactiveDismissDisabled(saving)
        .photoPicker(request: $request, camera: .rear, onImage: usePhoto)
        .confirmationDialog("Choose a clothing photo", isPresented: $showSources, titleVisibility: .visible) {
            Button("Take Photo") { request = .camera }
            Button("Choose from Photos") { request = .library }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            if picked == nil {
                name = replacing?.name ?? ""
                category = replacing?.category ?? initialCategory
                preferCleaned = replacing?.prefersCleaned ?? true
            }
        }
        .task(id: preparation) {
            guard let picked else { return }
            let key = preparation
            let output = await WardrobePhotoProcessor.prepare(picked, category: category)
            guard !Task.isCancelled else { return }
            processed = output
            processedKey = key
        }
    }

    private var comparison: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                photo(label: "Original", image: preview?.original)
                photo(label: "Cleaned", image: preview?.cleaned)
            }
            if preview == nil {
                ProgressView("Cleaning photo on this iPhone…").font(.subheadline)
            } else if preview?.cleaned != nil {
                Picker("Wardrobe image", selection: $preferCleaned) {
                    Text("Use Cleaned").tag(true)
                    Text("Use Original").tag(false)
                }
                .pickerStyle(.segmented)
                .disabled(saving || attempt != nil)
            } else {
                Text("Cleanup couldn’t isolate the garment. You can save the original or try another photo.")
                    .font(.subheadline)
                    .foregroundStyle(Color.fmSecondary)
            }
        }
    }

    private func photo(label: String, image: UIImage?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.semibold))
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("\(label) garment photo")
                } else {
                    Image(systemName: "photo").foregroundStyle(Color.fmSecondary).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 172)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity)
    }

    private func usePhoto(_ image: UIImage) {
        processed = nil
        saveError = nil
        preferCleaned = replacing?.prefersCleaned ?? true
        picked = image
        photoID = UUID()
    }

    private func save() async {
        guard !saving, let preview else { return }
        saving = true
        saveError = nil
        defer { saving = false }
        do {
            let item = try await persist(preview)
            await store.apply(item)
            onSaved(item)
            dismiss()
            await store.cleanUp()
        } catch {
            saveError = (error as? WardrobeError)?.errorDescription
                ?? "Couldn’t save your clothing. Check your connection and try again."
        }
    }

    private func persist(_ preview: WardrobePhotoProcessor.Preview) async throws -> WardrobeItem {
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
    @Binding var category: WardrobeCategory

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
                    ForEach(WardrobeCategory.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
    }
}
