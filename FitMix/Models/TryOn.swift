import UIKit

// MARK: - Try-on contract
//
// Studio's large preview shows the user wearing the look. A renderer takes the user's own
// full-body photo (always the original, never a previous render) plus the garments to apply, and
// returns the composite. With a FitMix backend configured, `TryOnRenderers.current` is
// `BackendOutfitTryOnRenderer` (the Outfit builder's OpenAI image edit); without one it's nil, and
// Studio shows the user's photo with a clear "not a try-on" state. See Docs/TryOnHandoff.md.

/// One garment to put on the user.
struct TryOnGarment {
    let pieceID: UUID
    let category: GarmentCategory
    /// Catalog product, when the piece is a confirmed replacement or a matched item.
    let productID: String?
    /// Best image of the garment: the replacement's product image, else the detected cutout, else its crop.
    let image: UIImage?
    /// Where the garment is in the street capture (normalized), when the scan provided it.
    let sourceBounds: CGRect?
    /// The listing's own product photo, for a renderer that fetches full resolution itself.
    var productImageURL: URL? = nil
}

/// "Try on my avatar": the one retailer listing the user chose, handed to the try-on flow with their
/// full-body avatar. Only this listing is applied; nothing from the street capture is.
struct AvatarTryOn: Equatable {
    let pieceID: UUID
    let listingID: String
    let category: GarmentCategory
    let productName: String
    let productImageURL: URL?
    /// The listing photo, once downloaded (the renderer's garment input).
    var productImage: UIImage?
}

/// A piece from the user's own wardrobe worn on the avatar together with the scanned listing
/// ("Mix with your wardrobe"). One per avatar slot.
struct WardrobeMixPiece: Identifiable {
    let item: WardrobeItem
    let slot: AvatarOutfitSlot
    /// The wardrobe photo the renderer applies (the cleaned cutout when there is one).
    let image: UIImage
    var id: UUID { item.id }
}

struct TryOnRequest {
    /// The user's original full-body photo.
    let person: UIImage
    /// Only these slots change. Every other slot keeps the clothing the user is wearing in `person`.
    let garments: [TryOnGarment]
    /// Identifies this exact selection, so an older render is never shown for a newer look.
    let signature: String
}

protocol TryOnRenderer {
    /// True only if `render` returns the user actually wearing the garments. Debug stand-ins say false.
    var producesTryOn: Bool { get }
    func render(_ request: TryOnRequest) async throws -> UIImage
    /// False when nothing in `request` is something this renderer can apply (Studio then says so
    /// instead of trying and failing).
    func supports(_ request: TryOnRequest) -> Bool
}

extension TryOnRenderer {
    func supports(_ request: TryOnRequest) -> Bool { true }
}

enum TryOnRenderers {
    /// The FitMix backend's photo try-on when a backend is configured; nil means try-on is unavailable.
    /// Debug builds: FM_DEBUG_TRYON_STUB=1 uses the labelled stand-in instead, which never contacts OpenAI.
    static var current: (any TryOnRenderer)? = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["FM_DEBUG_TRYON_STUB"] == "1" { return DebugStandInRenderer() }
        #endif
        return BackendConfig.current.map(BackendOutfitTryOnRenderer.init(config:))
    }()
}

/// What Studio's large preview can show for the current look.
enum TryOnPreview {
    /// No full-body photo of the user yet.
    case needsPhoto
    /// Nothing selected to try on.
    case nothingSelected
    /// No renderer is connected (or none of the pieces can be applied), so only the user's own photo can be shown.
    case unavailable
    /// Ready to render, waiting for Your Try-On to be shown (a render is an OpenAI request, so it only
    /// starts when the user looks at it).
    case waiting
    case rendering(signature: String)
    /// `isTryOn` is false for debug stand-ins; only a true value may be labeled a try-on.
    case ready(UIImage, isTryOn: Bool, signature: String)
    case failed(String, signature: String)
}

#if DEBUG
/// Debug-only: returns the user's photo stamped with the garments it was asked to apply, to
/// exercise regeneration. It does not dress the user, so it reports `producesTryOn = false`.
struct DebugStandInRenderer: TryOnRenderer {
    var producesTryOn: Bool { false }

    func render(_ request: TryOnRequest) async throws -> UIImage {
        // FM_DEBUG_TRYON_STUB_DELAY=<seconds>: a slower render, to change the look while it's running.
        let delay = ProcessInfo.processInfo.environment["FM_DEBUG_TRYON_STUB_DELAY"].flatMap(Double.init) ?? 0.6
        try await Task.sleep(for: .seconds(delay))
        let size = request.person.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = request.person.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            request.person.draw(at: .zero)
            let lines = ["DEBUG STAND-IN · NOT A TRY-ON"] + request.garments.map {
                "\($0.category.title): \($0.productID ?? "as scanned")"
            }
            let font = UIFont.systemFont(ofSize: max(14, size.width / 28), weight: .bold)
            let text = lines.joined(separator: "\n") as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            let box = text.boundingRect(with: CGSize(width: size.width * 0.9, height: size.height),
                                        options: .usesLineFragmentOrigin, attributes: attributes, context: nil)
            UIColor.black.withAlphaComponent(0.6).setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: size.width, height: box.height + font.pointSize * 1.2))
            text.draw(with: CGRect(x: font.pointSize * 0.6, y: font.pointSize * 0.6, width: size.width * 0.9, height: box.height),
                      options: .usesLineFragmentOrigin, attributes: attributes, context: nil)
            // The garment images it was handed, along the bottom, so a test can see which crops arrived.
            let images = request.garments.compactMap(\.image)
            guard !images.isEmpty else { return }
            let side = min(size.width / CGFloat(images.count), size.height * 0.22)
            UIColor.white.withAlphaComponent(0.85).setFill()
            UIRectFill(CGRect(x: 0, y: size.height - side, width: size.width, height: side))
            for (index, image) in images.enumerated() {
                let scale = min(side / image.size.width, side / image.size.height) * 0.9
                let w = image.size.width * scale, h = image.size.height * scale
                image.draw(in: CGRect(x: CGFloat(index) * side + (side - w) / 2, y: size.height - side + (side - h) / 2, width: w, height: h))
            }
        }
    }
}
#endif
