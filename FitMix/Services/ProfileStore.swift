import Foundation

nonisolated enum ShoppingDepartment: String, CaseIterable, Codable, Sendable {
    case men, women, unisex, any

    var title: String {
        switch self {
        case .men: "Men’s"
        case .women: "Women’s"
        case .unisex: "Unisex"
        case .any: "Any"
        }
    }
}

/// What FitMix saves for one account on this iPhone: sizing preferences and shipping addresses.
nonisolated struct AccountProfileData: Codable, Equatable, Sendable {
    var version = 1
    var sizing = SizingPreferences()
    var addresses: [ShippingAddress] = []
    var defaultAddressID: UUID?
    var shoppingDepartment: ShoppingDepartment?
}

enum ProfileStoreError: LocalizedError, Equatable {
    case notSignedIn, saveFailed, unreadable, notFound

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to save this to your account."
        case .saveFailed: "FitMix couldn't save this on your iPhone. Check available storage and try again."
        case .unreadable: "Your saved sizes and addresses couldn't be read."
        case .notFound: "That address was already removed."
        }
    }
}

/// Owns the signed-in account's sizing preferences and shipping addresses.
///
/// Follows the app's persistence approach for personal data (see `AvatarStore`): a JSON file in the
/// app's own container, with complete file protection. Each account gets its own folder, keyed by
/// its Supabase user ID, and only the signed-in account's file is ever loaded, so one account's
/// data never shows for another. Saved data stays on this iPhone after sign-out and comes back when
/// that account signs in again. It is not synced to other devices.
@Observable
final class ProfileStore {
    enum LoadState: Equatable {
        case signedOut
        case ready
        case failed(String)
    }

    private(set) var state: LoadState = .signedOut
    private(set) var accountID: UUID?
    private(set) var data = AccountProfileData()
    private var guestDepartment = ShoppingDepartment(rawValue: UserDefaults.standard.string(forKey: "guestShoppingDepartment") ?? "") ?? .any

    @ObservationIgnored let baseDirectory: URL

    init(baseDirectory: URL = ProfileStore.standardDirectory) {
        self.baseDirectory = baseDirectory
    }

    static var standardDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Accounts", isDirectory: true)
    }

    var sizing: SizingPreferences { data.sizing }
    var shoppingDepartment: ShoppingDepartment {
        accountID == nil ? guestDepartment : (data.shoppingDepartment ?? .any)
    }

    func saveShoppingDepartment(_ department: ShoppingDepartment) throws {
        if accountID == nil {
            UserDefaults.standard.set(department.rawValue, forKey: "guestShoppingDepartment")
            guestDepartment = department
        } else {
            try update { $0.shoppingDepartment = department }
        }
    }

    /// Saved addresses, default first.
    var addresses: [ShippingAddress] {
        guard let first = defaultAddress else { return [] }
        return [first] + data.addresses.filter { $0.id != first.id }
    }

    var defaultAddress: ShippingAddress? {
        data.addresses.first { $0.id == data.defaultAddressID } ?? data.addresses.first
    }

    func isDefault(_ address: ShippingAddress) -> Bool { defaultAddress?.id == address.id }

    // MARK: Account switching

    /// Loads `accountID`'s saved data, or clears everything from memory when nil (signed out).
    func activate(accountID: UUID?) {
        guard accountID != self.accountID || state != .ready else { return }
        self.accountID = accountID
        data = AccountProfileData()
        guard accountID != nil else { state = .signedOut; return }
        reload()
    }

    func reload() {
        guard let url = fileURL else { state = .signedOut; return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            data = AccountProfileData()
            state = .ready
            return
        }
        do {
            data = try JSONDecoder().decode(AccountProfileData.self, from: Data(contentsOf: url))
            state = .ready
        } catch {
            data = AccountProfileData()
            state = .failed(ProfileStoreError.unreadable.localizedDescription)
        }
    }

    // MARK: Sizing

    func saveSizing(_ sizing: SizingPreferences) throws {
        guard sizing.isValid else { return }
        try update { $0.sizing = sizing }
    }

    // MARK: Addresses

    /// Adds `address`, or replaces the saved address with the same ID. The first address becomes the default.
    func saveAddress(_ address: ShippingAddress, makeDefault: Bool = false) throws {
        let address = address.normalized()
        try update { data in
            if let index = data.addresses.firstIndex(where: { $0.id == address.id }) {
                data.addresses[index] = address
            } else {
                data.addresses.append(address)
            }
            if makeDefault {
                data.defaultAddressID = address.id
            } else if !data.addresses.contains(where: { $0.id == data.defaultAddressID }) {
                data.defaultAddressID = data.addresses.first?.id
            }
        }
    }

    /// Removes an address. If it was the default, the next saved address becomes the default.
    func deleteAddress(id: UUID) throws {
        guard data.addresses.contains(where: { $0.id == id }) else { throw ProfileStoreError.notFound }
        try update { data in
            data.addresses.removeAll { $0.id == id }
            if data.defaultAddressID == id { data.defaultAddressID = data.addresses.first?.id }
        }
    }

    func setDefaultAddress(id: UUID) throws {
        guard data.addresses.contains(where: { $0.id == id }) else { throw ProfileStoreError.notFound }
        try update { $0.defaultAddressID = id }
    }

    /// Deletes this account's saved sizes and addresses from this iPhone. Also clears an unreadable file.
    func deleteSavedData() throws {
        guard let directory = accountDirectory else { throw ProfileStoreError.notSignedIn }
        do {
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        } catch {
            throw ProfileStoreError.saveFailed
        }
        data = AccountProfileData()
        state = .ready
    }

    // MARK: Disk

    private var accountDirectory: URL? {
        accountID.map { baseDirectory.appendingPathComponent($0.uuidString.lowercased(), isDirectory: true) }
    }

    private var fileURL: URL? { accountDirectory?.appendingPathComponent("profile.json") }

    /// Applies a change and writes it to disk. Memory only changes once the write succeeds, so a
    /// failed save never shows as saved.
    private func update(_ change: (inout AccountProfileData) -> Void) throws {
        guard let directory = accountDirectory, let url = fileURL else { throw ProfileStoreError.notSignedIn }
        // Never overwrite a file that couldn't be read; the user can retry or delete it from Privacy & Data.
        guard state == .ready else { throw ProfileStoreError.unreadable }
        var next = data
        change(&next)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
            try JSONEncoder().encode(next).write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            throw ProfileStoreError.saveFailed
        }
        data = next
    }
}
