import SwiftUI

/// Where the retailer search for one garment stands.
enum RetailerMatchState: Equatable {
    case searching
    case found(CatalogProduct)
    /// The provider answered, but nothing credible in this category.
    case noMatch
    /// The search failed. `retryable` when trying again may work (network, busy provider).
    case failed(String, retryable: Bool)
    /// Google Lens answered with nothing close and usable.
    case noCloseMatch
    /// The Google Lens search failed; Retry runs it again. `detail` is shown in Debug builds only.
    case lensFailed(detail: String)
    /// The server's monthly Google Lens cap (or Scrappa's allowance) is used up. Retrying won't help.
    case searchLimitReached
}

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
    /// True for a look opened from a live camera selection: Studio shows the outfit frame first.
    private(set) var isLiveLook = false

    /// Retailer search per piece of a live look. Pieces without an entry haven't been searched.
    private(set) var matchStates: [UUID: RetailerMatchState] = [:]
    /// Every ranked listing for a searched piece, best first. `.found` holds the one the user chose.
    private(set) var matchLists: [UUID: [CatalogProduct]] = [:]
    /// Listing photos downloaded for the on-device comparison, by listing id. Reused for try-on.
    @ObservationIgnored private var listingPhotos: [String: CGImage] = [:]
    /// The listing the user chose to try on their avatar, if any.
    private(set) var avatarTryOn: AvatarTryOn?
    private(set) var wardrobeItem: WardrobeItem?
    private(set) var wardrobeGarment: TryOnGarment?
    private(set) var wardrobePerson: UIImage?
    /// Crops used as search input only, never shown. Cut from the same frame as the scan image,
    /// with the colour measured on the garment there.
    @ObservationIgnored private var searchCrops: [UUID: (image: CGImage, color: SIMD3<Float>?)] = [:]
    /// The same crops, for display: a live card shows the garment the user tapped while it searches, and keeps
    /// it beside the retailer's photo once a match arrives.
    private(set) var cropPreviews: [UUID: UIImage] = [:]
    /// One search per garment, running side by side, so one garment's failure never holds up another's.
    @ObservationIgnored private var searchTasks: [UUID: Task<Void, Never>] = [:]
    /// Identifies, per garment, the one search whose result may still be applied.
    @ObservationIgnored private var searchTokens: [UUID: UUID] = [:]
    @ObservationIgnored var searcher: RetailerSearching = RetailerSearchers.current

    /// The user's own full-body photo. Every render starts from this, never from a previous render.
    private(set) var tryOnSource: UIImage?
    private(set) var preview: TryOnPreview = .needsPhoto
    @ObservationIgnored private var renderTask: Task<Void, Never>?

    // MARK: Camera → Outfit Review → Studio

    /// Hand-off for a ready-made scan (debug samples and fixtures): hold it for Outfit Review.
    func review(_ scan: OutfitScan) {
        pendingScan = scan
    }

    func discardReview() {
        pendingScan = nil
    }

    /// Try Full Look: replaces the previous look entirely with the chosen garments from `scan`.
    /// Its selection, swaps, and render are cleared.
    func open(_ scan: OutfitScan, selected: Set<UUID>? = nil, tryOnSource: UIImage?) {
        cancelSearch()
        matchStates = [:]
        matchLists = [:]
        listingPhotos = [:]
        avatarTryOn = nil
        wardrobeItem = nil
        wardrobeGarment = nil
        wardrobePerson = nil
        searchCrops = [:]
        cropPreviews = [:]
        isLiveLook = false
        self.scan = scan
        hero = HeroFrame(scan: scan)
        let look = WorkingLook(scan: scan, selected: selected)
        self.look = look
        selectedPieceID = look.pieces.first?.id
        lastSwap = nil
        lookNumber += 1
        if pendingScan?.id == scan.id { pendingScan = nil }
        self.tryOnSource = tryOnSource
        refreshPreview()
    }

    /// Camera → Studio: the user tapped one garment in the live feed. Opens a look on that frame
    /// (shown whole, as the reference), with every garment detected in the same frame and the tapped
    /// one selected, and starts a product search for every garment with a usable crop.
    func openLive(_ selection: LiveGarmentSelection, tryOnSource: UIImage?) {
        let frame = UIImage(cgImage: selection.frame, scale: 1, orientation: .up)
        var crops: [UUID: (image: CGImage, color: SIMD3<Float>?)] = [:]
        var selectedID: UUID?
        let garments = selection.garments.map { garment in
            // No cutout or crop on the garment: cards show the retailer's photo, not the camera's.
            let detected = DetectedGarment(category: garment.category, bounds: garment.bounds)
            crops[detected.id] = (garment.crop, garment.color)
            if garment.category == selection.selected { selectedID = detected.id }
            return detected
        }
        let scan = OutfitScan(capturedAt: selection.capturedAt, image: frame, subjectBounds: nil, garments: garments)
        #if DEBUG
        if selection.isTestPhoto { SampleScans.register(scan, as: .fixture) }
        else if selection.isSample { SampleScans.register(scan) }
        #endif
        open(scan, tryOnSource: tryOnSource)
        isLiveLook = true
        searchCrops = crops
        cropPreviews = crops.mapValues { UIImage(cgImage: $0.image) }
        if let selectedID { selectedPieceID = selectedID }
        // The tapped garment first, then the others in their card order.
        let ids = look?.pieces.map(\.id) ?? []
        for id in ids.filter({ $0 == selectedID }) + ids.filter({ $0 != selectedID }) { findMatch(for: id) }
    }

    /// Categories the product search accepts, and the smallest crop worth sending.
    static let searchableCategories: Set<GarmentCategory> = [.jacket, .tshirt, .pants, .shoes]
    static let minimumCropSide = 48

    /// Searches retailers for one piece of a live look. A search already running for the same piece is
    /// replaced (its result is dropped even if it arrives later); other pieces' searches carry on.
    func findMatch(for pieceID: UUID) {
        guard isLiveLook, let crop = searchCrops[pieceID], let scanID = scan?.id,
              let piece = look?.pieces.first(where: { $0.id == pieceID }) else { return }
        searchTasks[pieceID]?.cancel()
        guard Self.searchableCategories.contains(piece.detected.category),
              min(crop.image.width, crop.image.height) >= Self.minimumCropSide else {
            matchStates[pieceID] = .failed("This garment's crop is too small to search. Scan a little closer.", retryable: false)
            return
        }
        let token = UUID()
        searchTokens[pieceID] = token
        matchStates[pieceID] = .searching
        let category = piece.detected.category
        let searcher = self.searcher
        searchTasks[pieceID] = Task { [weak self] in
            let state: RetailerMatchState
            var ranked: [CatalogProduct] = []
            var photos: VisualReranker.Photos = [:]
            if let request = await GarmentSearchInput.make(category: category, crop: crop.image, measuredColor: crop.color) {
                do {
                    switch try await searcher.search(request) {
                    case .noMatch: state = .noMatch
                    case .lensNoMatch: state = .noCloseMatch
                    case .lensMatch(let listing):
                        // One listing, already filtered to this category with a link and a photo: shown as is.
                        let product = Self.product(from: listing, category: category)
                        ranked = [product]
                        state = .found(product)
                    case .matches(let listings):
                        // The backend already limited listings to this category; order within each label
                        // by how the listing photos compare with the crop.
                        let reranked = await VisualReranker.rerank(listings, crop: crop.image)
                        photos = reranked.photos
                        ranked = reranked.listings.map { Self.product(from: $0, category: category) }
                        state = ranked.first.map(RetailerMatchState.found) ?? .noMatch
                    }
                } catch is CancellationError {
                    return
                } catch RetailerSearchError.lensFailed(let detail) {
                    state = .lensFailed(detail: detail)
                } catch RetailerSearchError.searchLimitReached {
                    state = .searchLimitReached
                } catch let error as RetailerSearchError {
                    state = .failed(error.localizedDescription, retryable: error.isRetryable)
                } catch {
                    state = .failed(error.localizedDescription, retryable: true)
                }
            } else {
                state = .failed("This garment's image couldn't be prepared for search.", retryable: false)
            }
            guard let self, !Task.isCancelled, self.searchTokens[pieceID] == token, self.scan?.id == scanID else { return }
            self.matchLists[pieceID] = ranked
            self.listingPhotos.merge(photos) { new, _ in new }
            self.apply(state, to: pieceID)
        }
    }

    /// The user picked another listing from the ranked list for this piece.
    func chooseListing(_ product: CatalogProduct, for pieceID: UUID) {
        guard matchLists[pieceID]?.contains(product) == true else { return }
        apply(.found(product), to: pieceID)
        if avatarTryOn?.pieceID == pieceID { avatarTryOn = nil; refreshPreview() }
    }

    /// "Try on my avatar": hands the chosen listing (id, category, product photo) and the user's full-body
    /// avatar to the try-on flow. Returns false when there's no avatar or no chosen listing.
    @discardableResult
    func tryOnAvatar(pieceID: UUID, avatar: UIImage?) -> Bool {
        guard let avatar, case .found(let product)? = matchStates[pieceID],
              let piece = look?.pieces.first(where: { $0.id == pieceID }) else { return false }
        let url: URL? = if case .remote(let url) = product.image { url } else { nil }
        var handoff = AvatarTryOn(pieceID: pieceID, listingID: product.id, category: piece.detected.category,
                                  productName: product.name, productImageURL: url)
        if let photo = listingPhotos[product.id] {
            handoff.productImage = UIImage(cgImage: photo)
        } else if case .local(let image) = product.image {
            handoff.productImage = image
        }
        avatarTryOn = handoff
        tryOnSource = avatar
        refreshPreview()
        if handoff.productImage == nil, let url {
            Task { [weak self] in
                guard let photo = await VisualReranker.download(url, session: .shared) else { return }
                guard let self, self.avatarTryOn?.listingID == handoff.listingID else { return }
                self.listingPhotos[handoff.listingID] = photo
                self.avatarTryOn?.productImage = UIImage(cgImage: photo)
                self.refreshPreview()
            }
        }
        return true
    }

    private func apply(_ state: RetailerMatchState, to pieceID: UUID) {
        matchStates[pieceID] = state
        searchTokens[pieceID] = nil
        searchTasks[pieceID] = nil
        guard var look, let index = look.pieces.firstIndex(where: { $0.id == pieceID }) else { return }
        if case .found(let product) = state { look.pieces[index].retailerMatch = product } else { look.pieces[index].retailerMatch = nil }
        self.look = look
    }

    /// Stops every running search (a new look is opening).
    private func cancelSearch() {
        searchTasks.values.forEach { $0.cancel() }
        searchTasks = [:]
        // A search cut short goes back to "not searched", rather than spinning forever.
        for id in searchTokens.keys where matchStates[id] == .searching { matchStates[id] = nil }
        searchTokens = [:]
    }

    private static func product(from listing: RetailerListing, category: GarmentCategory) -> CatalogProduct {
        CatalogProduct(id: listing.id, name: listing.title, brand: listing.brand, retailer: listing.seller.map { "\(listing.retailer) · \($0)" } ?? listing.retailer,
                       category: category, match: listing.tier == .exact ? .exact : listing.tier == .brand ? .brand : .similar,
                       image: listing.imageURL.map(ProductImage.remote),
                       price: listing.price.flatMap { amount in listing.currency.map { Price(amount: amount, currencyCode: $0) } },
                       retailerURL: listing.listingURL, isFixture: listing.isFixture, evidence: listing.evidence)
    }

    func openWardrobeItem(_ item: WardrobeItem, garment: UIImage, person: UIImage?) {
        wardrobeItem = item
        wardrobeGarment = TryOnGarment(pieceID: item.id, category: item.category.garment,
                                        productID: nil, image: garment, sourceBounds: nil)
        wardrobePerson = person
        refreshPreview()
    }

    func closeWardrobeItem() {
        guard wardrobeItem != nil else { return }
        wardrobeItem = nil
        wardrobeGarment = nil
        wardrobePerson = nil
        refreshPreview()
    }

    /// The user added their photo from Studio. Renders the current look on it.
    func setTryOnSource(_ image: UIImage) {
        if wardrobeItem != nil { wardrobePerson = image } else { tryOnSource = image }
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
        // In a live look, selecting a garment searches for it (once; a failure can be retried).
        guard isLiveLook else { return }
        switch matchStates[id] {
        case nil: findMatch(for: id)
        case .searching, .found, .noMatch, .failed, .noCloseMatch, .lensFailed, .searchLimitReached: break
        }
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

    // MARK: Try-on

    func retryPreview() { refreshPreview() }

    /// The request for the current look, or nil when there's nothing to render.
    var currentRequest: TryOnRequest? {
        if let item = wardrobeItem, let garment = wardrobeGarment {
            guard let wardrobePerson else { return nil }
            return TryOnRequest(person: wardrobePerson, garments: [garment],
                                signature: "wardrobe:\(item.id.uuidString):\(item.photoRevision.uuidString):\(item.category.rawValue)")
        }
        guard let tryOnSource, let look, !look.pieces.isEmpty else { return nil }
        if let avatarTryOn {
            // Only the chosen listing goes on the avatar, identified by its listing id.
            let garment = TryOnGarment(pieceID: avatarTryOn.pieceID, category: avatarTryOn.category, productID: avatarTryOn.listingID,
                                       image: avatarTryOn.productImage, sourceBounds: nil, productImageURL: avatarTryOn.productImageURL)
            return TryOnRequest(person: tryOnSource, garments: [garment],
                                signature: "avatar:\(avatarTryOn.listingID):\(avatarTryOn.productImage == nil ? "pending" : "photo")")
        }
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
        guard (wardrobeItem == nil ? tryOnSource : wardrobePerson) != nil else { preview = .needsPhoto; return }
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
                guard !Task.isCancelled, let self, self.isCurrent(signature) else { return }
                self.preview = .failed(error.localizedDescription, signature: signature)
            }
        }
    }

    private func isCurrent(_ signature: String) -> Bool {
        currentRequest?.signature == signature
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
