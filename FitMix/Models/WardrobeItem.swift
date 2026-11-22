import Foundation

nonisolated enum WardrobeCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case tshirt, pants, shoes, outerwear, accessory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tshirt: "T-Shirts"
        case .pants: "Pants"
        case .shoes: "Shoes"
        case .outerwear: "Jackets & Hoodies"
        case .accessory: "Accessories"
        }
    }

    var garment: GarmentCategory {
        switch self {
        case .tshirt: .tshirt
        case .pants: .pants
        case .shoes: .shoes
        case .outerwear: .jacket
        case .accessory: .accessory
        }
    }
}

nonisolated struct WardrobeCatalogPhoto: Decodable, Sendable {
    let category: WardrobeCategory?
    let image: Data?
    let message: String?
}

nonisolated struct WardrobeItem: Identifiable, Codable, Sendable {
    let id: UUID
    let ownerID: UUID
    let name: String?
    let category: WardrobeCategory
    let photoRevision: UUID
    let originalPath: String
    let cleanedPath: String?
    let thumbnailPath: String
    let prefersCleaned: Bool
    let rowVersion: UUID
    let createdAt: Date
    let updatedAt: Date

    var title: String { name ?? category.garment.title }
    var displayPath: String { (prefersCleaned ? cleanedPath : nil) ?? originalPath }
    var tryOnPath: String { cleanedPath ?? originalPath }

    enum CodingKeys: String, CodingKey {
        case id, name, category
        case ownerID = "owner_id"
        case photoRevision = "photo_revision"
        case originalPath = "original_path"
        case cleanedPath = "cleaned_path"
        case thumbnailPath = "thumbnail_path"
        case prefersCleaned = "prefers_cleaned"
        case rowVersion = "row_version"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

nonisolated struct WardrobePhotoFiles: Sendable {
    let original: Data
    let cleaned: Data?
    let thumbnail: Data
    let prefersCleaned: Bool
}

nonisolated struct WardrobeDetails: Encodable, Sendable {
    let name: String?
    let category: WardrobeCategory

    init(name: String, category: WardrobeCategory) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed.isEmpty ? nil : trimmed
        self.category = category
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(category, forKey: .category)
    }

    private enum CodingKeys: String, CodingKey { case name, category }
}
