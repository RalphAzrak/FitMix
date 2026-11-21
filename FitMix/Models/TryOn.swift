import UIKit

// MARK: - Try-on contract
//
// Studio's large preview shows the user wearing the look. A renderer takes the user's own
// full-body photo (always the original, never a previous render) plus the garments to apply, and
// returns the composite. FitMix has no renderer yet: `TryOnRenderers.current` is nil, so Studio
// shows the user's photo with a clear "not a try-on" state. See Docs/TryOnHandoff.md.

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
}

enum TryOnRenderers {
    /// HANDOFF: set this at launch once a renderer exists. Nil means try-on is unavailable.
    static var current: (any TryOnRenderer)? = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["FM_DEBUG_TRYON_STUB"] == "1" { return DebugStandInRenderer() }
        #endif
        return nil
    }()
}

/// What Studio's large preview can show for the current look.
enum TryOnPreview {
    /// No full-body photo of the user yet.
    case needsPhoto
    /// Nothing selected to try on.
    case nothingSelected
    /// No renderer is connected, so only the user's own photo can be shown.
    case unavailable
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
        try await Task.sleep(for: .milliseconds(600))
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
        }
    }
}
#endif
