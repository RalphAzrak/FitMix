import SwiftUI

/// Owns the Studio session: the current scan (kept as the reference) and the working look built
/// from it. Lives for the app session, so leaving Studio and coming back keeps the look.
@Observable
final class StudioStore {
    /// The capture Studio is showing. Never modified after `open(_:)`.
    private(set) var scan: OutfitScan?
    private(set) var look: WorkingLook?
    var selectedPieceID: UUID?
    /// The last confirmed swap, for the short confirmation on the photo.
    private(set) var lastSwap: (pieceID: UUID, category: GarmentCategory)?
    /// Counts scans opened this session, for "Look 01", "Look 02"…
    private(set) var lookNumber = 0

    /// Camera hand-off. Call once the scanner has a confirmed result for the chosen person.
    /// Replaces the previous look entirely: its selection and swaps are cleared.
    func open(_ scan: OutfitScan) {
        self.scan = scan
        look = WorkingLook(scan: scan)
        selectedPieceID = scan.garments.first?.id
        lastSwap = nil
        lookNumber += 1
    }

    var selectedPiece: WorkingLook.Piece? {
        look?.pieces.first { $0.id == selectedPieceID }
    }

    func select(_ id: UUID) {
        selectedPieceID = id
    }

    /// Confirms a swap on one piece. Passing nil goes back to what the photo shows.
    func swap(pieceID: UUID, to product: CatalogProduct?) {
        guard var look, let index = look.pieces.firstIndex(where: { $0.id == pieceID }) else { return }
        look.pieces[index].replacement = product
        self.look = look
        lastSwap = product == nil ? nil : (pieceID, look.pieces[index].detected.category)
    }

    var hasSwaps: Bool { look?.pieces.contains(where: \.isSwapped) ?? false }
}
