import Foundation
import Supabase

nonisolated enum WardrobeError: LocalizedError {
    case sessionChanged, itemChanged, invalidPhoto

    var errorDescription: String? {
        switch self {
        case .sessionChanged: "Sign in again to access your wardrobe."
        case .itemChanged: "This item changed on another screen or device. Reopen it and try again."
        case .invalidPhoto: "This photo couldn’t be opened. Try a different photo."
        }
    }
}

/// Shares the app's authenticated client and keeps the cache in a separate folder for each account.
actor WardrobeRepository {
    private let client: SupabaseClient
    let ownerID: UUID
    private let cache: URL
    private var cleaning = false

    init(client: SupabaseClient, ownerID: UUID) {
        self.client = client
        self.ownerID = ownerID
        cache = URL.cachesDirectory.appending(path: "Wardrobe").appending(path: ownerID.uuidString.lowercased())
    }

    private var storage: StorageFileApi { client.storage.from("wardrobe-photos") }
    private var items: PostgrestQueryBuilder { client.from("wardrobe_items") }
    private var uploads: PostgrestQueryBuilder { client.from("wardrobe_photo_uploads") }

    func cachedItems() -> [WardrobeItem]? {
        let location = cache.appending(path: "items.json")
        guard let data = try? Data(contentsOf: location) else { return nil }
        return try? JSONDecoder().decode([WardrobeItem].self, from: data).filter { $0.ownerID == ownerID }
    }

    func fetchItems() async throws -> [WardrobeItem] {
        try await checkAccount()
        var result: [WardrobeItem] = []
        let pageSize = 100
        while true {
            let page: [WardrobeItem] = try await items.select()
                .eq("owner_id", value: ownerID).order("updated_at", ascending: false).order("id")
                .range(from: result.count, to: result.count + pageSize - 1).execute().value
            try Task.checkCancellation()
            result.append(contentsOf: page)
            if page.count < pageSize { break }
        }
        return result
    }

    func photo(at path: String) async throws -> Data {
        try Task.checkCancellation()
        guard client.auth.currentUser?.id == ownerID else { throw WardrobeError.sessionChanged }
        let parts = path.split(separator: "/")
        guard parts.count == 4, parts[0] == ownerID.uuidString.lowercased(),
              let itemID = UUID(uuidString: String(parts[1])),
              let revision = UUID(uuidString: String(parts[2])),
              ["original.jpg", "cleaned.jpg", "thumbnail.jpg"].contains(parts[3]) else { throw WardrobeError.invalidPhoto }
        let dest = photoDirectory(itemID: itemID, revision: revision).appending(path: String(parts[3]))
        if let data = try? Data(contentsOf: dest) { return data }
        try await checkAccount()
        let data = try await storage.download(path: path)
        try Task.checkCancellation()
        saveCache(data, at: dest)
        return data
    }

    /// Check the previous attempt before creating fresh paths for a retry. Abandoning serializes with commit.
    func recoverPhoto(id: UUID, revision: UUID) async throws -> WardrobeItem? {
        try await checkAccount()
        try await abandon(revision)
        let saved = try await fetchItem(id)
        return saved?.photoRevision == revision ? saved : nil
    }

    func savePhoto(id: UUID, replacing item: WardrobeItem?, revision: UUID,
                   details: WardrobeDetails, photos: WardrobePhotoFiles) async throws -> WardrobeItem {
        try await checkAccount()
        let upload = Upload(revision: revision, ownerID: ownerID, itemID: id, hasCleaned: photos.cleaned != nil)
        let fields = PhotoFields(upload: upload, details: details, prefersCleaned: photos.prefersCleaned)
        do {
            try await uploads.insert(upload, returning: .minimal).execute()
            // Use the account-scoped disk cache for reuse and require HTTP clients to revalidate.
            let options = FileOptions(cacheControl: "0", contentType: "image/jpeg")
            try await storage.upload(fields.originalPath, data: photos.original, options: options)
            if let cleaned = photos.cleaned, let path = fields.cleanedPath {
                try await storage.upload(path, data: cleaned, options: options)
            }
            try await storage.upload(fields.thumbnailPath, data: photos.thumbnail, options: options)
            try await checkAccount()

            let saved: WardrobeItem
            if let item {
                let matching: [WardrobeItem] = try await items.update(fields)
                    .eq("owner_id", value: ownerID).eq("id", value: id).eq("row_version", value: item.rowVersion)
                    .select().execute().value
                guard let first = matching.first else { throw WardrobeError.itemChanged }
                saved = first
            } else {
                saved = try await items.insert(NewItem(id: id, ownerID: ownerID, fields: fields)).select().single().execute().value
            }
            rememberPhotos(photos, for: saved)
            return saved
        } catch {
            // Abandon is a no-op if the commit already won. Retrying the same item never deletes its active photos.
            try? await abandon(revision)
            if let committed = try? await fetchItem(id), committed.photoRevision == revision {
                rememberPhotos(photos, for: committed)
                return committed
            }
            Task { await drainCleanup() }
            throw error
        }
    }

    func update(_ item: WardrobeItem, details: WardrobeDetails) async throws -> WardrobeItem {
        try await checkAccount()
        let matching: [WardrobeItem] = try await items.update(details)
            .eq("owner_id", value: ownerID).eq("id", value: item.id).eq("row_version", value: item.rowVersion)
            .select().execute().value
        guard let saved = matching.first else {
            if let saved = try await fetchItem(item.id), saved.name == details.name, saved.category == details.category {
                return saved
            }
            throw WardrobeError.itemChanged
        }
        return saved
    }

    func delete(_ item: WardrobeItem) async throws {
        try await checkAccount()
        let removed: [WardrobeItem] = try await items.delete()
            .eq("owner_id", value: ownerID).eq("id", value: item.id).eq("row_version", value: item.rowVersion)
            .select().execute().value
        if removed.isEmpty, try await fetchItem(item.id) != nil { throw WardrobeError.itemChanged }
    }

    /// The DB queues replaced, deleted, and abandoned revisions. The queue survives app restarts
    /// and is retried on refresh. An entry is cleared only after its files are absent.
    @discardableResult
    func drainCleanup() async -> Bool {
        guard !cleaning else { return true }
        cleaning = true
        defer { cleaning = false }
        do {
            try await checkAccount()
            try await client.rpc("wardrobe_expire_uploads").execute()
            var pending: [Upload] = []
            let pageSize = 100
            while true {
                let page: [Upload] = try await uploads.select()
                    .eq("owner_id", value: ownerID).eq("state", value: "cleanup").order("revision")
                    .range(from: pending.count, to: pending.count + pageSize - 1).execute().value
                pending.append(contentsOf: page)
                if page.count < pageSize { break }
            }
            var finished = true
            for upload in pending {
                do {
                    try await checkAccount()
                    try await storage.remove(paths: upload.paths)
                    let removed: Bool = try await client.rpc("wardrobe_finish_cleanup",
                        params: ["upload_revision": upload.revision]).execute().value
                    guard removed else {
                        finished = false
                        continue
                    }
                    try? FileManager.default.removeItem(at: photoDirectory(itemID: upload.itemID, revision: upload.revision))
                } catch {
                    finished = false
                    if Task.isCancelled { break }
                }
            }
            return finished
        } catch {
            return false
        }
    }

    func remember(_ records: [WardrobeItem]) {
        if let data = try? JSONEncoder().encode(records) {
            saveCache(data, at: cache.appending(path: "items.json"))
        }
    }

    private func checkAccount() async throws {
        try Task.checkCancellation()
        guard try await client.auth.session.user.id == ownerID else { throw WardrobeError.sessionChanged }
    }

    private func fetchItem(_ id: UUID) async throws -> WardrobeItem? {
        try await checkAccount()
        let result: [WardrobeItem] = try await items.select()
            .eq("owner_id", value: ownerID).eq("id", value: id).limit(1).execute().value
        return result.first
    }

    private func abandon(_ revision: UUID) async throws {
        try await client.rpc("wardrobe_abandon_upload", params: ["upload_revision": revision]).execute()
    }

    private func rememberPhotos(_ photos: WardrobePhotoFiles, for item: WardrobeItem) {
        let folder = photoDirectory(itemID: item.id, revision: item.photoRevision)
        saveCache(photos.original, at: folder.appending(path: "original.jpg"))
        if let cleaned = photos.cleaned {
            saveCache(cleaned, at: folder.appending(path: "cleaned.jpg"))
        }
        saveCache(photos.thumbnail, at: folder.appending(path: "thumbnail.jpg"))
    }

    private func photoDirectory(itemID: UUID, revision: UUID) -> URL {
        cache.appending(path: itemID.uuidString).appending(path: revision.uuidString)
    }

    private func saveCache(_ data: Data, at url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

nonisolated private struct Upload: Codable, Sendable {
    let revision: UUID
    let ownerID: UUID
    let itemID: UUID
    let hasCleaned: Bool

    func path(_ file: String) -> String {
        [ownerID, itemID, revision].map { $0.uuidString.lowercased() }.joined(separator: "/") + "/" + file + ".jpg"
    }

    var paths: [String] {
        ["original", "thumbnail"].map(path) + (hasCleaned ? [path("cleaned")] : [])
    }

    enum CodingKeys: String, CodingKey {
        case revision
        case ownerID = "owner_id"
        case itemID = "item_id"
        case hasCleaned = "has_cleaned"
    }
}

nonisolated private struct PhotoFields: Encodable, Sendable {
    let upload: Upload
    let details: WardrobeDetails
    let prefersCleaned: Bool

    var originalPath: String { upload.path("original") }
    var cleanedPath: String? { upload.hasCleaned ? upload.path("cleaned") : nil }
    var thumbnailPath: String { upload.path("thumbnail") }

    func encode(to encoder: any Encoder) throws {
        try details.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(upload.revision, forKey: .revision)
        try container.encode(originalPath, forKey: .originalPath)
        try container.encode(cleanedPath, forKey: .cleanedPath)
        try container.encode(thumbnailPath, forKey: .thumbnailPath)
        try container.encode(prefersCleaned, forKey: .prefersCleaned)
    }

    enum CodingKeys: String, CodingKey {
        case revision = "photo_revision"
        case originalPath = "original_path"
        case cleanedPath = "cleaned_path"
        case thumbnailPath = "thumbnail_path"
        case prefersCleaned = "prefers_cleaned"
    }
}

nonisolated private struct NewItem: Encodable, Sendable {
    let id: UUID
    let ownerID: UUID
    let fields: PhotoFields

    func encode(to encoder: any Encoder) throws {
        try fields.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(ownerID, forKey: .ownerID)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case ownerID = "owner_id"
    }
}
