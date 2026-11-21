import SwiftUI

/// Owns the Studio session: the scan awaiting Outfit Review, the current scan (kept as the
/// reference), the working look built from the garments the user chose, and the try-on preview.
/// Lives for the app session, so leaving Studio and coming back keeps the look.
@Observable
final class StudioStore {
    /// A confirmed Camera scan the user is reviewing. Studio's current look is untouched until
    /// they tap Try Full Look.
    private(set) var pendingScan: OutfitScan?

    /// The capture Studio is showing. Never modified after `open`.
    private(set) var scan: OutfitScan?
    private(set) var look: WorkingLook?
    /// The person from the capture, framed for the Street Look view. Built once per scan.
    private(set) var hero: HeroFrame?
    var selectedPieceID: UUID?
    /// The last confirmed swap, for the short confirmation on the photo.
    private(set) var lastSwap: (pieceID: UUID, category: GarmentCategory)?
    /// Counts looks opened this session, for "Look 01", "Look 02"…
    private(set) var lookNumber = 0

    /// The user's own full-body photo. Every render starts from this, never from a previous render.
    private(set) var tryOnSource: UIImage?
    private(set) var preview: TryOnPreview = .needsPhoto
    @ObservationIgnored private var renderTask: Task<Void, Never>?

    // MARK: Camera → Outfit Review → Studio

    /// True while garments are being found on `pendingScan`'s photo.
    private(set) var isAnalyzing = false
    /// What the analysis wants the user to know about `pendingScan` (no garments, only a top, …).
    private(set) var analysis: CaptureAnalysis?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?

    /// Hand-off for a ready-made scan (debug samples and fixtures): hold it for Outfit Review.
    func review(_ scan: OutfitScan) {
        cancelAnalysis()
        pendingScan = scan
    }

    /// Camera hand-off: show the photo in Outfit Review right away and find its garments in the
    /// background. The result replaces `pendingScan` (same photo, now with garments).
    func review(_ capture: ConfirmedCapture) {
        cancelAnalysis()
        let placeholder = CaptureHandoff.scan(for: capture)
        pendingScan = placeholder
        isAnalyzing = true
        analysisTask = Task { [weak self] in
            let result = await CaptureHandoff.analyze(capture)
            guard !Task.isCancelled, let self, self.pendingScan?.id == placeholder.id else { return }
            self.pendingScan = result.scan
            self.analysis = result
            self.isAnalyzing = false
        }
    }

    func discardReview() {
        cancelAnalysis()
        pendingScan = nil
    }

    private func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        isAnalyzing = false
        analysis = nil
    }

    /// Try Full Look: replaces the previous look entirely with the chosen garments from `scan`.
    /// Its selection, swaps, and render are cleared.
    func open(_ scan: OutfitScan, selected: Set<UUID>? = nil, tryOnSource: UIImage?) {
        self.scan = scan
        hero = HeroFrame(scan: scan)
        let look = WorkingLook(scan: scan, selected: selected)
        self.look = look
        selectedPieceID = look.pieces.first?.id
        lastSwap = nil
        lookNumber += 1
        if pendingScan?.id == scan.id {
            pendingScan = nil
            analysis = nil
        }
        self.tryOnSource = tryOnSource
        refreshPreview()
    }

    /// The user added their photo from Studio. Renders the current look on it.
    func setTryOnSource(_ image: UIImage) {
        tryOnSource = image
        refreshPreview()
    }

    /// Keeps Studio on the user's current try-on photo: a replaced photo re-renders the look, and a
    /// removed one is dropped so nothing renders from it.
    func useTryOnPhoto(_ image: UIImage?) {
        guard image !== tryOnSource else { return }
        tryOnSource = image
        refreshPreview()
    }

    // MARK: Editing

    var selectedPiece: WorkingLook.Piece? {
        look?.pieces.first { $0.id == selectedPieceID }
    }

    func select(_ id: UUID) {
        selectedPieceID = id
    }

    /// Confirms a swap on one piece (nil goes back to what was scanned), then re-renders the
    /// whole updated selection from the original photo.
    func swap(pieceID: UUID, to product: CatalogProduct?) {
        guard var look, let index = look.pieces.firstIndex(where: { $0.id == pieceID }) else { return }
        guard look.pieces[index].replacement != product else { return }
        look.pieces[index].replacement = product
        self.look = look
        lastSwap = product == nil ? nil : (pieceID, look.pieces[index].detected.category)
        refreshPreview()
    }

    var hasSwaps: Bool { look?.pieces.contains(where: \.isSwapped) ?? false }

    // MARK: Try-on

    func retryPreview() { refreshPreview() }

    /// The request for the current look, or nil when there's nothing to render.
    var currentRequest: TryOnRequest? {
        guard let tryOnSource, let look, !look.pieces.isEmpty else { return nil }
        let garments = look.pieces.map { piece in
            TryOnGarment(pieceID: piece.id, category: piece.detected.category,
                         productID: piece.replacement?.id,
                         image: piece.tryOnImage,
                         sourceBounds: piece.detected.bounds)
        }
        return TryOnRequest(person: tryOnSource, garments: garments, signature: Self.signature(of: look))
    }

    private static func signature(of look: WorkingLook) -> String {
        look.pieces.map { "\($0.id.uuidString):\($0.replacement?.id ?? "scanned")" }.joined(separator: "|")
    }

    private func refreshPreview() {
        renderTask?.cancel()
        renderTask = nil
        guard tryOnSource != nil else { preview = .needsPhoto; return }
        guard let request = currentRequest else { preview = .nothingSelected; return }
        guard let renderer = TryOnRenderers.current else { preview = .unavailable; return }

        let signature = request.signature
        preview = .rendering(signature: signature)
        renderTask = Task { [weak self] in
            do {
                let image = try await renderer.render(request)
                guard !Task.isCancelled, let self, self.isCurrent(signature) else { return }
                self.preview = .ready(image, isTryOn: renderer.producesTryOn, signature: signature)
            } catch is CancellationError {
            } catch {
                guard let self, self.isCurrent(signature) else { return }
                self.preview = .failed(error.localizedDescription, signature: signature)
            }
        }
    }

    private func isCurrent(_ signature: String) -> Bool {
        look.map(Self.signature(of:)) == signature
    }
}

extension WorkingLook.Piece {
    /// The garment image a renderer should apply: replacement product, else cutout, else crop.
    var tryOnImage: UIImage? {
        if let replacement {
            if case .local(let image) = replacement.image { return image }
            return nil
        }
        return detected.cutout ?? detected.crop
    }
}
