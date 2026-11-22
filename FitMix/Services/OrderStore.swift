import Foundation

enum OrderStoreError: LocalizedError, Equatable {
    case saveFailed

    var errorDescription: String? {
        "FitMix couldn't save this order on your iPhone. It's still shown on the confirmation."
    }
}

/// Orders placed through FitMix's checkout, newest first. They're all demo orders until a real payment
/// provider exists.
///
/// Saved per account at `Application Support/Accounts/<user-id>/orders.json` with complete file
/// protection, like `CartStore` and `ProfileStore`. Signed out, an order is shown on its confirmation
/// but not saved. An unreadable file is never overwritten.
@Observable
final class OrderStore {
    private(set) var orders: [DemoOrder] = []
    private(set) var accountID: UUID?
    private(set) var loadError: String?

    @ObservationIgnored let baseDirectory: URL

    init(baseDirectory: URL = ProfileStore.standardDirectory) {
        self.baseDirectory = baseDirectory
    }

    var canSave: Bool { accountID != nil && loadError == nil }

    /// Loads `accountID`'s orders, or clears them from memory when nil (signed out).
    func activate(accountID: UUID?) {
        guard accountID != self.accountID else { return }
        self.accountID = accountID
        orders = []
        loadError = nil
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            orders = try JSONDecoder().decode(OrderData.self, from: Data(contentsOf: url)).orders
        } catch {
            loadError = "Your past orders couldn't be read."
        }
    }

    /// Saves `order` to the signed-in account. Returns false when signed out (nothing is saved).
    @discardableResult
    func record(_ order: DemoOrder) throws -> Bool {
        guard canSave, let url = fileURL else { return false }
        let next = [order] + orders
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
            try JSONEncoder().encode(OrderData(orders: next)).write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            throw OrderStoreError.saveFailed
        }
        orders = next
        return true
    }

    private var fileURL: URL? {
        accountID.map {
            baseDirectory.appendingPathComponent($0.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent("orders.json")
        }
    }
}
