import Foundation
import Observation
import Supabase

@MainActor @Observable
final class WardrobeStore {
    let repository: WardrobeRepository
    private(set) var items: [WardrobeItem] = []
    private(set) var loading = true
    private(set) var loadError: String?
    private(set) var cleanupPending = false

    @ObservationIgnored private var loadToken = 0

    init(client: SupabaseClient, ownerID: UUID) {
        repository = WardrobeRepository(client: client, ownerID: ownerID)
    }

    func load() async {
        loadToken += 1
        let token = loadToken
        loading = true
        loadError = nil
        if items.isEmpty, let cached = await repository.cachedItems(), token == loadToken, !Task.isCancelled {
            items = cached
        }
        do {
            let records = try await repository.fetchItems()
            guard token == loadToken, !Task.isCancelled else { return }
            items = records
            await repository.remember(records)
            guard token == loadToken, !Task.isCancelled else { return }
        } catch {
            guard token == loadToken, !Task.isCancelled else { return }
            loadError = "Couldn’t sync your wardrobe. Check your connection and try again."
        }
        loading = false
        await cleanUp()
    }

    func apply(_ item: WardrobeItem) async {
        loadToken += 1
        loading = false
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        await repository.remember(items)
    }

    func remove(_ item: WardrobeItem) async throws {
        try await repository.delete(item)
        loadToken += 1
        loading = false
        items.removeAll { $0.id == item.id }
        await repository.remember(items)
    }

    func cleanUp() async {
        cleanupPending = !(await repository.drainCleanup())
    }
}
