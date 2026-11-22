import Foundation
import Observation
import UIKit

nonisolated enum AvatarOutfitSlot: String, CaseIterable, Identifiable, Codable, Sendable {
    case tshirt, pants, shoes, outerwear

    var id: String { rawValue }

    var category: WardrobeCategory {
        switch self {
        case .tshirt: .tshirt
        case .pants: .pants
        case .shoes: .shoes
        case .outerwear: .outerwear
        }
    }

    var title: String {
        switch self {
        case .tshirt: "T-Shirt"
        case .pants: "Pants"
        case .shoes: "Shoes"
        case .outerwear: "Jacket or Hoodie"
        }
    }
}

@MainActor @Observable
final class AvatarOutfitSelection {
    private(set) var ownerID: UUID?
    private(set) var itemIDs: [AvatarOutfitSlot: UUID] = [:]
    @ObservationIgnored private var previews: [(key: String, image: UIImage)] = []

    func activate(ownerID: UUID?) {
        guard self.ownerID != ownerID else { return }
        self.ownerID = ownerID
        itemIDs = [:]
        previews.removeAll()
        guard let key = storageKey,
              let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else { return }
        for (slot, itemID) in saved {
            if let slot = AvatarOutfitSlot(rawValue: slot), let id = UUID(uuidString: itemID) {
                itemIDs[slot] = id
            }
        }
    }

    func choose(_ item: WardrobeItem) {
        guard item.ownerID == ownerID, let slot = AvatarOutfitSlot(rawValue: item.category.rawValue) else { return }
        for previous in AvatarOutfitSlot.allCases where previous != slot && itemIDs[previous] == item.id {
            itemIDs[previous] = nil
        }
        itemIDs[slot] = item.id
        persist()
    }

    func remove(_ slot: AvatarOutfitSlot) {
        itemIDs[slot] = nil
        persist()
    }

    func restore(_ pieces: [SavedLook.Piece]) {
        guard ownerID != nil else { return }
        itemIDs = [:]
        for piece in pieces {
            if let slot = piece.slot, let id = piece.itemID { itemIDs[slot] = id }
        }
        persist()
    }

    func item(in slot: AvatarOutfitSlot, from wardrobe: [WardrobeItem]) -> WardrobeItem? {
        guard let id = itemIDs[slot] else { return nil }
        return wardrobe.first { $0.id == id && $0.ownerID == ownerID && $0.category == slot.category }
    }

    func preview(for key: String) -> UIImage? {
        previews.first { $0.key == key }?.image
    }

    func rememberPreview(_ image: UIImage, key: String) {
        previews.removeAll { $0.key == key }
        previews.append((key, image))
        if previews.count > 3 { previews.removeFirst() }
    }

    private var storageKey: String? { ownerID.map { "avatar-outfit.\($0.uuidString)" } }

    private func persist() {
        guard let key = storageKey else { return }
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: itemIDs.map { ($0.key.rawValue, $0.value.uuidString) }),
                                  forKey: key)
    }
}
