import Foundation
import os

enum DemoOrderError: LocalizedError, Equatable {
    case emptyCart, saveFailed, unreadable

    var errorDescription: String? {
        switch self {
        case .emptyCart: "Your cart is empty, so there's nothing to order."
        case .saveFailed: "FitMix couldn't save the demo order on this iPhone. Your cart is unchanged. Check available storage and try again."
        case .unreadable: "Your saved demo orders couldn't be read, so FitMix won't add to them."
        }
    }
}

/// Demo orders placed on this iPhone. Entirely local: no network, no payment, no store is contacted.
///
/// Saved at `Application Support/Accounts/<user-id>/demo-orders.json` for a signed-in account, or
/// `Accounts/guest/demo-orders.json` when signed out, with complete file protection. Unlike the
/// signed-out cart, a guest's orders are kept on disk, so a confirmation is still there after the app
/// restarts. Each account only ever sees its own orders.
@Observable
final class DemoOrderStore {
    /// Newest first.
    private(set) var orders: [DemoOrder] = []
    private(set) var loadError: String?
    @ObservationIgnored private(set) var accountID: UUID?
    @ObservationIgnored private var activated = false
    @ObservationIgnored let baseDirectory: URL

    init(baseDirectory: URL = ProfileStore.standardDirectory) {
        self.baseDirectory = baseDirectory
    }

    /// Loads the orders of `accountID`, or the guest's when nil.
    func activate(accountID: UUID?) {
        guard !activated || accountID != self.accountID else { return }
        activated = true
        self.accountID = accountID
        orders = []
        loadError = nil
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            orders = try JSONDecoder().decode(DemoOrderData.self, from: Data(contentsOf: fileURL)).orders
        } catch {
            loadError = DemoOrderError.unreadable.localizedDescription
        }
    }

    func order(id: UUID) -> DemoOrder? { orders.first { $0.id == id } }

    /// Saves a demo order of `items` and returns it. Memory only changes once the file is written, so an
    /// order that failed to save never shows as placed.
    func place(_ items: [CartItem], at date: Date = .now) throws -> DemoOrder {
        guard !items.isEmpty else { throw DemoOrderError.emptyCart }
        guard loadError == nil else { throw DemoOrderError.unreadable }
        let order = DemoOrder(id: UUID(), number: DemoOrder.makeNumber(at: date, existing: Set(orders.map(\.number))),
                              placedAt: date, items: items)
        let next = [order] + orders
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(DemoOrderData(orders: next)).write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            throw DemoOrderError.saveFailed
        }
        orders = next
        return order
    }

    var fileURL: URL {
        baseDirectory.appendingPathComponent(accountID?.uuidString.lowercased() ?? "guest", isDirectory: true)
            .appendingPathComponent("demo-orders.json")
    }
}

/// Cart and checkout logging. Never logs payment details (FitMix never has any).
enum CheckoutLog {
    static let logger = Logger(subsystem: "app.fitmix", category: "checkout")

    static func record(_ kind: String, store: String, note: String? = nil) {
        var summary = "[checkout] \(kind) store=\(store)"
        if let note { summary += " \(note)" }
        logger.info("\(summary, privacy: .public)")
        #if DEBUG
        print(summary)
        #endif
    }
}
