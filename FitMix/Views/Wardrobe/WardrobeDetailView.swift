import SwiftUI

struct WardrobeDetailView: View {
    @State var item: WardrobeItem
    let store: WardrobeStore
    var openOutfit: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthSession.self) private var auth
    @Environment(AppRouter.self) private var router
    @Environment(StudioStore.self) private var studio
    @Environment(AvatarOutfitSelection.self) private var outfit
    @Environment(AvatarStore.self) private var avatar

    @State private var name = ""
    @State private var category: WardrobeCategory = .tshirt
    @State private var showCleaned = false
    @State private var replace = false
    @State private var confirmDelete = false
    @State private var activity: Action?
    @State private var failure: Failure?
    @State private var fieldsInitialized = false

    private enum Action: Equatable {
        case save, delete, tryOn

        var progress: String {
            switch self {
            case .save: "Saving changes…"
            case .delete: "Removing item…"
            case .tryOn: "Opening garment in Studio…"
            }
        }
    }

    private struct Failure {
        let action: Action
        let message: String
    }

    private var edited: Bool {
        details.name != item.name || category != item.category
    }

    private var details: WardrobeDetails { WardrobeDetails(name: name, category: category) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WardrobeRemotePhoto(path: (showCleaned ? item.cleanedPath : nil) ?? item.originalPath,
                                    repository: store.repository, height: 260)
                if item.cleanedPath != nil {
                    Picker("Photo version", selection: $showCleaned) {
                        Text("Original").tag(false)
                        Text("Cleaned").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                WardrobeFields(name: $name, category: $category)
                if let activity { ProgressView(activity.progress).frame(maxWidth: .infinity) }
                if let failure {
                    WardrobeRetry(message: failure.message) { await perform(failure.action) }
                }
                if edited {
                    Button("Save Changes") { Task { await perform(.save) } }.buttonStyle(FMFilledButtonStyle())
                }
                Button(item.category == .accessory ? "Try On in Studio" : "Add to Outfit", systemImage: "tshirt") {
                    Task { await perform(.tryOn) }
                }
                    .buttonStyle(FMFilledButtonStyle())
                    .disabled(edited)
                Button("Replace Photo", systemImage: "camera") { replace = true }
                    .buttonStyle(FMOutlineButtonStyle())
                    .disabled(edited)
                Button("Delete Item", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(20)
            .disabled(activity != nil)
        }
        .background(Color.wardrobeBackground)
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !fieldsInitialized { resetFields() } }
        .interactiveDismissDisabled(activity != nil)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }.disabled(activity != nil)
            }
        }
        .sheet(isPresented: $replace) {
            NavigationStack {
                WardrobePhotoReview(store: store, replacing: item) { saved in
                    item = saved
                    resetFields()
                }
            }
        }
        .confirmationDialog("Remove \(item.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Item", role: .destructive) { Task { await perform(.delete) } }
        } message: {
            Text("This removes the item and its saved photos from your wardrobe.")
        }
    }

    private func resetFields() {
        fieldsInitialized = true
        name = item.name ?? ""
        category = item.category
        showCleaned = item.prefersCleaned
        failure = nil
    }

    private func perform(_ action: Action) async {
        guard activity == nil else { return }
        activity = action
        failure = nil
        defer { activity = nil }
        do {
            switch action {
            case .save:
                item = try await store.repository.update(item, details: details)
                await store.apply(item)
                resetFields()
            case .delete:
                try await store.remove(item)
                dismiss()
                await store.cleanUp()
            case .tryOn:
                if AvatarOutfitSlot(rawValue: item.category.rawValue) != nil {
                    guard auth.user?.id == item.ownerID else { throw WardrobeError.sessionChanged }
                    outfit.choose(item)
                    openOutfit()
                    dismiss()
                    return
                }
                let data = try await store.repository.photo(at: item.tryOnPath)
                guard auth.user?.id == item.ownerID else { throw WardrobeError.sessionChanged }
                guard let photo = UIImage(data: data) else { throw WardrobeError.invalidPhoto }
                studio.openWardrobeItem(item, garment: photo, person: avatar.avatarImage ?? avatar.bodyPhoto)
                dismiss()
                router.tab = .studio
            }
        } catch {
            let message: String
            switch action {
            case .save: message = "Couldn’t save your changes. Check your connection and try again."
            case .delete: message = "Couldn’t remove this item. Check your connection and try again."
            case .tryOn: message = "Couldn’t load this garment for Studio. Check your connection and try again."
            }
            failure = Failure(action: action, message: (error as? WardrobeError)?.errorDescription ?? message)
        }
    }
}
