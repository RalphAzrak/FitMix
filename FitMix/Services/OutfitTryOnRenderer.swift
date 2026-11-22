import UIKit

/// Photo try-on through the FitMix backend: the same OpenAI image edit, endpoint (`POST /v1/avatar-outfit`),
/// model configuration and request format the Outfit builder already uses (`BackendAvatarGenerator.style`).
/// Image 1 is the person, then one reference image per outfit slot; the server renders them as one outfit.
///
/// Used by Studio for scanned looks and for Wardrobe Try-On. See Docs/TryOnHandoff.md.
nonisolated struct BackendOutfitTryOnRenderer: TryOnRenderer {
    var generator: BackendAvatarGenerator
    var producesTryOn: Bool { true }

    init(config: BackendConfig) {
        generator = BackendAvatarGenerator(config: config)
    }

    /// The backend's outfit slots. One garment per slot; categories without a slot (bags, hats,
    /// accessories, dresses) can't be tried on this way.
    static func slot(for category: GarmentCategory) -> AvatarOutfitSlot? {
        switch category {
        case .jacket: .outerwear
        case .tshirt, .top: .tshirt
        case .pants, .bottoms, .shorts, .skirt: .pants
        case .shoes: .shoes
        case .dress, .bag, .hat, .accessory, .other: nil
        }
    }

    /// The garments this renderer will send: the first usable one per slot, in the look's order.
    static func references(in request: TryOnRequest) -> [(AvatarOutfitSlot, TryOnGarment)] {
        var seen = Set<AvatarOutfitSlot>()
        return request.garments.compactMap { garment in
            guard let slot = slot(for: garment.category), garment.image != nil || garment.productImageURL != nil,
                  seen.insert(slot).inserted else { return nil }
            return (slot, garment)
        }
    }

    func supports(_ request: TryOnRequest) -> Bool { !Self.references(in: request).isEmpty }

    func render(_ request: TryOnRequest) async throws -> UIImage {
        let references = Self.references(in: request)
        guard !references.isEmpty else { throw TryOnRenderError.nothingToApply }
        guard let person = await request.person.uploadJPEG(maxDimension: 1536) else { throw TryOnRenderError.unreadablePhoto }
        var garments: [(AvatarOutfitSlot, Data)] = []
        for (slot, garment) in references {
            var image = garment.image
            if image == nil, let url = garment.productImageURL {
                // A swapped-in product whose photo hasn't been downloaded yet.
                image = await ListingPhoto.download(url, session: .shared).map { UIImage(cgImage: $0) }
            }
            guard let image, let data = await image.uploadJPEG(maxDimension: 1200) else {
                throw TryOnRenderError.missingGarmentImage(garment.category.title)
            }
            garments.append((slot, data))
        }
        try Task.checkCancellation()
        let data: Data
        do {
            data = try await generator.style(portrait: person, garments: garments)
        } catch let error as AvatarGenerationError {
            // The shared client words its own errors for the avatar; say what failed here.
            switch error {
            case .notConfigured: throw TryOnRenderError.service("Try-on isn't set up in this build of FitMix.")
            case .timedOut: throw TryOnRenderError.service("Creating the try-on took too long. Try again.")
            case .unreachable: throw TryOnRenderError.service("FitMix couldn't reach its try-on service. Check your connection and try again.")
            case .invalidResponse: throw TryOnRenderError.service("The try-on service sent back something FitMix couldn't use. Try again.")
            case .offline, .service: throw error
            }
        }
        guard let image = UIImage(data: data) else { throw AvatarGenerationError.invalidResponse }
        return image
    }
}

enum TryOnRenderError: LocalizedError {
    case nothingToApply, unreadablePhoto, missingGarmentImage(String), service(String)

    var errorDescription: String? {
        switch self {
        case .nothingToApply: "None of these pieces can be tried on yet. Try-on works for jackets, tops, pants and shoes."
        case .unreadablePhoto: "Your try-on photo couldn't be read. Choose it again in Profile."
        case .missingGarmentImage(let name): "The \(name.lowercased())'s photo couldn't be loaded. Check your connection and try again."
        case .service(let message): message
        }
    }
}
