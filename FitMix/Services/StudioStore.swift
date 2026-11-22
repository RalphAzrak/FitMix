import OSLog
import SwiftUI

/// Where the retailer search for one garment stands.
enum RetailerMatchState: Equatable {
    case searching
    case found(CatalogProduct)
    /// The provider answered, but nothing credible in this category.
    case noMatch
    /// The search failed. `retryable` when trying again may work (network, busy provider).
    case failed(String, retryable: Bool)
    case budgetMissing
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
    private(set) var matchDescriptions: [UUID: String] = [:]
    private(set) var matchGarmentLabels: [UUID: String] = [:]
    private(set) var matchBrands: [UUID: String] = [:]
    private(set) var matchCropBounds: [UUID: CGRect] = [:]
    private(set) var shoppingDepartment: ShoppingDepartment = .any
    private(set) var outfitBudget: Decimal?
    private(set) var isExpandingBudget = false
    private(set) var budgetSearchFailed = false
    @ObservationIgnored private var searchIDs: [UUID: String] = [:]
    @ObservationIgnored private var baseStates: [UUID: RetailerMatchState] = [:]
    @ObservationIgnored private var pinned: [UUID: String] = [:]
    @ObservationIgnored private var budgetTask: Task<Void, Never>?
    @ObservationIgnored private var triedCap: Decimal?
    @ObservationIgnored private var matchingStart: ContinuousClock.Instant?
    @ObservationIgnored private var loggedFirst = false
    @ObservationIgnored private var loggedSettled = false
    private static let log = Logger(subsystem: "app.fitmix", category: "OutfitMatching")
    private static let tryOnLog = Logger(subsystem: "app.fitmix", category: "TryOn")

    /// Listing photos downloaded for the on-device comparison, by listing id. Reused for try-on.
    @ObservationIgnored private var listingPhotos: [String: CGImage] = [:]
    /// The listing the user chose to try on their avatar, if any.
    private(set) var avatarTryOn: AvatarTryOn?
    private(set) var wardrobeItem: WardrobeItem?
    private(set) var wardrobeGarment: TryOnGarment?
    private(set) var wardrobePerson: UIImage?
    /// The garment crop that is both displayed and sent for search.
    @ObservationIgnored private var searchCrops: [UUID: CGImage] = [:]
    /// The exact crop from the displayed outfit frame.
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
    /// Your Try-On is on screen. A scanned look renders only then: each render is an OpenAI request.
    @ObservationIgnored private var tryOnVisible = false

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
        matchDescriptions = [:]
        matchGarmentLabels = [:]
        matchBrands = [:]
        matchCropBounds = [:]
        baseStates = [:]
        searchIDs = [:]
        pinned = [:]
        triedCap = nil
        budgetSearchFailed = false
        matchingStart = nil
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
    /// (shown whole, as the reference), with its detected garments and the tapped one selected.
    /// Every detected garment starts a product search, the tapped one first.
    func openLive(_ selection: LiveGarmentSelection, tryOnSource: UIImage?,
                  department: ShoppingDepartment) {
        let confirmedAt = ContinuousClock.now
        let frame = UIImage(cgImage: selection.frame, scale: 1, orientation: .up)
        var crops: [UUID: CGImage] = [:]
        var previews: [UUID: UIImage] = [:]
        var selectedID: UUID?
        let garments = selection.garments.map { garment in
            // No cutout or crop on the garment: cards show the retailer's photo, not the camera's.
            let detected = DetectedGarment(category: garment.category, bounds: garment.bounds)
            crops[detected.id] = garment.crop
            previews[detected.id] = UIImage(cgImage: garment.crop)
            if garment.category == selection.selected { selectedID = detected.id }
            return detected
        }
        let scan = OutfitScan(capturedAt: selection.capturedAt, image: frame, subjectBounds: nil, garments: garments)
        #if DEBUG
        if selection.isTestPhoto { SampleScans.register(scan, as: .fixture) }
        else if selection.isSample { SampleScans.register(scan) }
        #endif
        tryOnVisible = false
        open(scan, tryOnSource: tryOnSource)
        isLiveLook = true
        shoppingDepartment = department
        matchingStart = confirmedAt
        loggedFirst = false
        loggedSettled = false
        searchCrops = crops
        cropPreviews = previews
        matchCropBounds = Dictionary(uniqueKeysWithValues: garments.compactMap { item in
            item.bounds.map { (item.id, $0) }
        })
        // The backend renderer needs the scanned crops before it can prepare the preview.
        refreshPreview()
        if let selectedID { select(selectedID) }
        // Every detected garment is searched, the tapped one first, so each box shows the product chosen for it.
        for piece in look?.pieces ?? [] where matchStates[piece.id] == nil { findMatch(for: piece.id) }
    }

    func setShoppingDepartment(_ department: ShoppingDepartment) {
        guard isLiveLook, shoppingDepartment != department, let look else { return }
        cancelSearch()
        shoppingDepartment = department
        searchIDs = [:]
        matchLists = [:]
        baseStates = [:]
        pinned = [:]
        budgetSearchFailed = false
        updateSelections()
        let ids = look.pieces.map(\.id)
        for id in ids.filter({ $0 == selectedPieceID }) + ids.filter({ $0 != selectedPieceID }) {
            findMatch(for: id)
        }
    }

    /// Categories the product search accepts, and the smallest crop worth sending.
    static let searchableCategories: Set<GarmentCategory> = [.jacket, .tshirt, .pants, .shoes]
    static let minimumCropSide = 48

    static func matchCropLimits(for detected: CGRect) -> CGRect {
        detected.insetBy(dx: -detected.width * 0.25, dy: -detected.height * 0.16)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func refineMatch(pieceID: UUID, scanID: UUID, bounds: CGRect, brand: String) -> Bool {
        guard isLiveLook, let scan, scan.id == scanID, let frame = scan.image.cgImage,
              let detected = scan.garments.first(where: { $0.id == pieceID })?.bounds,
              Self.matchCropLimits(for: detected).insetBy(dx: -0.000001, dy: -0.000001).contains(bounds),
              bounds.width < 1 || bounds.height < 1,
              let crop = LiveGarmentSelection.crop(frame, to: bounds, padding: 0),
              min(crop.width, crop.height) >= Self.minimumCropSide else { return false }
        searchCrops[pieceID] = crop
        cropPreviews[pieceID] = UIImage(cgImage: crop)
        matchCropBounds[pieceID] = bounds
        matchBrands[pieceID] = brand.isEmpty ? nil : brand
        matchDescriptions[pieceID] = nil
        matchGarmentLabels[pieceID] = nil
        matchLists[pieceID] = nil
        pinned[pieceID] = nil
        selectedPieceID = pieceID
        findMatch(for: pieceID)
        return true
    }

    func clearMatchBrand(for pieceID: UUID) {
        guard let scanID = scan?.id, let bounds = matchCropBounds[pieceID] else { return }
        _ = refineMatch(pieceID: pieceID, scanID: scanID, bounds: bounds, brand: "")
    }

    /// Searches retailers for one piece of a live look. A search already running for the same piece is
    /// replaced (its result is dropped even if it arrives later); other pieces' searches carry on.
    func findMatch(for pieceID: UUID) {
        guard isLiveLook, let crop = searchCrops[pieceID], let scanID = scan?.id,
              let piece = look?.pieces.first(where: { $0.id == pieceID }) else { return }
        searchTasks[pieceID]?.cancel()
        searchTasks[pieceID] = nil
        searchTokens[pieceID] = nil
        budgetTask?.cancel()
        budgetTask = nil
        isExpandingBudget = false
        searchIDs[pieceID] = nil
        triedCap = nil
        if min(crop.width, crop.height) < Self.minimumCropSide ||
            !Self.searchableCategories.contains(piece.detected.category) {
            baseStates[pieceID] = .failed("This garment’s crop is too small. Scan a little closer.", retryable: false)
            updateSelections()
            logMatchingProgress()
            return
        }
        let token = UUID()
        searchTokens[pieceID] = token
        baseStates[pieceID] = .searching
        updateSelections()
        let category = piece.detected.category
        let brand = matchBrands[pieceID] ?? ""
        let department = shoppingDepartment
        let searcher = self.searcher
        searchTasks[pieceID] = Task { [weak self] in
            var state: RetailerMatchState = .failed("This garment’s image couldn’t be prepared.", retryable: false)
            var products: [CatalogProduct] = []
            var searchID: String?
            var description: String?
            var garmentLabel: String?
            if let request = await GarmentSearchInput.make(category: category, crop: crop, brand: brand, department: department),
               !Task.isCancelled {
                do {
                    switch try await searcher.search(request) {
                    case .outfit(let id, let listings, let details, let label):
                        searchID = id
                        description = details
                        garmentLabel = label
                        for listing in listings { ListingThumbnails.store(listing.thumbnail, for: listing.imageURL) }
                        products = listings.map { Self.product(from: $0, category: category) }
                    case .matches(let listings):
                        products = listings.map { Self.product(from: $0, category: category) }
                    case .noMatch: break
                    }
                    state = products.first(where: { !$0.isAlternative }).map(RetailerMatchState.found) ?? .noMatch
                } catch is CancellationError {
                    return
                } catch let error as RetailerSearchError {
                    state = .failed(error.localizedDescription, retryable: error.isRetryable)
                } catch {
                    state = .failed("Retailer search is unavailable. Try again.", retryable: true)
                }
            }
            guard let self, !Task.isCancelled, self.searchTokens[pieceID] == token, self.scan?.id == scanID else { return }
            self.searchIDs[pieceID] = searchID
            self.matchDescriptions[pieceID] = description
            self.matchGarmentLabels[pieceID] = garmentLabel
            self.matchLists[pieceID] = products
            self.baseStates[pieceID] = state
            self.searchTokens[pieceID] = nil
            self.searchTasks[pieceID] = nil
            if let choice = self.pinned[pieceID], !products.contains(where: { $0.id == choice }) { self.pinned[pieceID] = nil }
            self.updateSelections()
            self.expandBudgetIfNeeded()
            self.logMatchingProgress()
        }
    }

    var budgetSubtotal: Decimal {
        look?.pieces.compactMap { $0.product?.price }
            .filter { $0.currencyCode == OutfitBudget.currency }.reduce(0) { $0 + $1.amount } ?? 0
    }

    var missingBudgetPieces: [GarmentCategory] {
        look?.pieces.filter { $0.product == nil }.map { $0.detected.category } ?? []
    }

    func setBudget(_ cap: Decimal?) {
        guard outfitBudget != cap else { return }
        outfitBudget = cap
        pinned = [:]
        triedCap = nil
        budgetSearchFailed = false
        budgetTask?.cancel()
        budgetTask = nil
        isExpandingBudget = false
        updateSelections()
        if cap != nil, isLiveLook {
            for piece in look?.pieces ?? [] where baseStates[piece.id] == nil { findMatch(for: piece.id) }
        }
        expandBudgetIfNeeded()
    }

    func retryBudgetSearch() {
        triedCap = nil
        expandBudgetIfNeeded()
    }

    /// A rejected choice leaves both Studio and the shopping review unchanged.
    func chooseListing(_ product: CatalogProduct, for pieceID: UUID) -> Bool {
        guard matchLists[pieceID]?.contains(product) == true else { return false }
        if let cap = outfitBudget {
            guard let price = product.price, price.currencyCode == OutfitBudget.currency else { return false }
            let old = look?.pieces.first(where: { $0.id == pieceID })?.product?.price?.amount ?? 0
            guard budgetSubtotal - old + price.amount <= cap else { return false }
        }
        pinned[pieceID] = product.id
        updateSelections()
        return true
    }

    private func updateSelections() {
        guard var look, isLiveLook else { return }
        let groups = look.pieces.map { matchLists[$0.id] ?? [] }
        let closeMatches = groups.map { $0.filter { !$0.isAlternative } }
        var choices = look.pieces.indices.map { index in
            groups[index].first { $0.id == pinned[look.pieces[index].id] }
        }
        if let cap = outfitBudget {
            let fixedCost = choices.compactMap { $0?.price?.amount }.reduce(0, +)
            let options = groups.indices.map { index in
                choices[index] == nil ? closeMatches[index].compactMap { product -> OutfitBudget.Option? in
                    guard let price = product.price, price.currencyCode == OutfitBudget.currency else { return nil }
                    return OutfitBudget.Option(id: product.id, price: price.amount, score: product.visualScore ?? 0)
                } : []
            }
            let plan = OutfitBudget.select(options, cap: cap - fixedCost)
            for index in choices.indices where choices[index] == nil {
                choices[index] = groups[index].first { $0.id == plan[index] }
            }
        } else {
            for index in choices.indices where choices[index] == nil { choices[index] = closeMatches[index].first }
        }
        for index in look.pieces.indices {
            let id = look.pieces[index].id
            let chosen = choices[index]
            look.pieces[index].retailerMatch = chosen
            if let chosen { matchStates[id] = .found(chosen) }
            else if !closeMatches[index].isEmpty, outfitBudget != nil { matchStates[id] = .budgetMissing }
            else { matchStates[id] = baseStates[id] }
        }
        self.look = look
        if let avatarTryOn, look.pieces.first(where: { $0.id == avatarTryOn.pieceID })?.product?.id != avatarTryOn.listingID {
            self.avatarTryOn = nil
            refreshPreview()
        }
    }

    private func expandBudgetIfNeeded() {
        guard let cap = outfitBudget, let look, let scanID = scan?.id, searchTokens.isEmpty, !missingBudgetPieces.isEmpty,
              !isExpandingBudget, triedCap != cap else { return }
        let requests = look.pieces.compactMap { piece -> (UUID, GarmentCategory, String)? in
            searchIDs[piece.id].map { (piece.id, piece.detected.category, $0) }
        }
        guard !requests.isEmpty else { return }
        triedCap = cap
        isExpandingBudget = true
        budgetSearchFailed = false
        let searcher = self.searcher
        budgetTask = Task { [weak self] in
            await withTaskGroup(of: (UUID, GarmentCategory, [RetailerListing]?).self) { group in
                for (id, category, searchID) in requests {
                    group.addTask {
                        let results = try? await searcher.cheaperListings(category: category, searchID: searchID, cap: cap)
                        return (id, category, results)
                    }
                }
                for await (id, category, results) in group {
                    guard !Task.isCancelled, let self, self.scan?.id == scanID, self.outfitBudget == cap else { return }
                    if let results {
                        let existing = self.matchLists[id] ?? []
                        let known = Set(existing.map(\.id))
                        let added = results.filter { !known.contains($0.id) }
                            .map { Self.product(from: $0, category: category) }
                        self.matchLists[id] = (existing + added).sorted { left, right in
                            let leftScore = left.visualScore ?? 0
                            let rightScore = right.visualScore ?? 0
                            if leftScore != rightScore { return leftScore > rightScore }
                            return left.match == .exact && right.match != .exact
                        }
                        self.updateSelections()
                    } else {
                        self.budgetSearchFailed = true
                    }
                }
            }
            guard !Task.isCancelled, let self, self.scan?.id == scanID, self.outfitBudget == cap else { return }
            self.isExpandingBudget = false
            self.budgetTask = nil
            self.logMatchingProgress()
        }
    }

    private func logMatchingProgress() {
        guard let matchingStart, let look else { return }
        let matched = look.pieces.filter { $0.product != nil }.count
        let elapsed = matchingStart.duration(to: .now).components
        let ms = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        if !loggedFirst, matched > 0 {
            loggedFirst = true
            Self.log.info("First outfit product card in \(ms, privacy: .public) ms")
        }
        if !loggedSettled, searchTokens.isEmpty, !isExpandingBudget,
              look.pieces.contains(where: { baseStates[$0.id] != nil }) {
            loggedSettled = true
            Self.log.info("Outfit matching settled in \(ms, privacy: .public) ms (\(matched, privacy: .public)/\(look.pieces.count, privacy: .public) garments)")
        }
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
        } else if let url, let photo = ListingThumbnails.image(for: url) {
            // The photo that came with the search result: no download needed before the try-on.
            handoff.productImage = photo
        }
        avatarTryOn = handoff
        tryOnSource = avatar
        refreshPreview()
        if handoff.productImage == nil, let url {
            Task { [weak self] in
                guard let photo = await ListingPhoto.download(url, session: .shared) else { return }
                guard let self, self.avatarTryOn?.listingID == handoff.listingID else { return }
                self.listingPhotos[handoff.listingID] = photo
                self.avatarTryOn?.productImage = UIImage(cgImage: photo)
                self.refreshPreview()
            }
        }
        return true
    }

    /// Stops every running search (a new look is opening).
    private func cancelSearch() {
        budgetTask?.cancel()
        budgetTask = nil
        isExpandingBudget = false
        searchTasks.values.forEach { $0.cancel() }
        searchTasks = [:]
        // A search cut short goes back to "not searched", rather than spinning forever.
        for id in searchTokens.keys where matchStates[id] == .searching { matchStates[id] = nil }
        searchTokens = [:]
    }

    private static func product(from listing: RetailerListing, category: GarmentCategory) -> CatalogProduct {
        let product = CatalogProduct(id: listing.id, name: listing.title, brand: listing.brand, retailer: listing.seller.map { "\(listing.retailer) · \($0)" } ?? listing.retailer,
                       category: category, match: listing.tier == .exact ? .exact : listing.tier == .brand ? .brand : .similar,
                       image: listing.imageURL.map(ProductImage.remote),
                       price: listing.price.flatMap { amount in listing.currency.map { Price(amount: amount, currencyCode: $0) } },
                       retailerURL: listing.listingURL, isFixture: listing.isFixture, evidence: listing.evidence,
                       visualScore: listing.visualScore, bestMatch: listing.bestMatch, isAlternative: listing.isAlternative)
        return product
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
        case .searching, .found, .noMatch, .failed, .budgetMissing: break
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

    /// Studio switched to or away from Your Try-On. Showing it starts the render if one is needed.
    func setTryOnVisible(_ visible: Bool) {
        guard visible != tryOnVisible else { return }
        tryOnVisible = visible
        if visible, case .waiting = preview { refreshPreview() }
    }

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
        // Every selected piece, as one outfit. By default each piece is the garment as scanned (its
        // cutout or crop); a retailer match is never needed. Only a piece the user explicitly swapped in
        // Studio uses that product's photo.
        let garments = look.pieces.map { piece in
            TryOnGarment(pieceID: piece.id, category: piece.detected.category,
                         productID: piece.replacement?.id,
                         image: tryOnImage(for: piece),
                         sourceBounds: piece.detected.bounds,
                         productImageURL: piece.replacement.flatMap { if case .remote(let url) = $0.image { url } else { nil } })
        }
        return TryOnRequest(person: tryOnSource, garments: garments,
                            signature: "photo:\(ObjectIdentifier(tryOnSource).hashValue)|" + Self.signature(of: look))
    }

    /// The garment image a renderer should apply for `piece`.
    private func tryOnImage(for piece: WorkingLook.Piece) -> UIImage? {
        if let replacement = piece.replacement {
            if case .local(let image) = replacement.image { return image }
            return listingPhotos[replacement.id].map { UIImage(cgImage: $0) }  // else the renderer fetches its URL
        }
        if let image = piece.tryOnImage { return image }
        // Live scans keep their crops apart from the garment (cards show the retailer's photo): the
        // clearest search crop, else the exact crop from the frame.
        if let crop = searchCrops[piece.id] { return UIImage(cgImage: crop) }
        return cropPreviews[piece.id]
    }

    private static func signature(of look: WorkingLook) -> String {
        look.pieces.map { "\($0.id.uuidString):\($0.replacement?.id ?? "scanned")" }.joined(separator: "|")
    }

    private func refreshPreview() {
        renderTask?.cancel()
        renderTask = nil
        guard (wardrobeItem == nil ? tryOnSource : wardrobePerson) != nil else { preview = .needsPhoto; return }
        guard let request = currentRequest else { preview = .nothingSelected; return }
        guard let renderer = TryOnRenderers.current, renderer.supports(request) else { preview = .unavailable; return }
        // Wardrobe Try-On always shows its preview; a scanned look waits until Your Try-On is shown.
        guard wardrobeItem != nil || avatarTryOn != nil || tryOnVisible else { preview = .waiting; return }

        let signature = request.signature
        preview = .rendering(signature: signature)
        let person = request.person.size
        Self.tryOnLog.info("Try-on render: \(String(describing: type(of: renderer)), privacy: .public), person \(Int(person.width), privacy: .public)×\(Int(person.height), privacy: .public), garments \(request.garments.map { "\($0.category.rawValue)=\($0.productID ?? "scanned"):\($0.image.map { "\(Int($0.size.width))×\(Int($0.size.height))" } ?? ($0.productImageURL == nil ? "no-image" : "url"))" }.joined(separator: ","), privacy: .public)")
        #if DEBUG
        print("[tryon] render \(type(of: renderer)) person=\(Int(person.width))x\(Int(person.height)) garments=\(request.garments.map { "\($0.category.rawValue)=\($0.productID ?? "scanned"):\($0.image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? ($0.productImageURL == nil ? "no-image" : "url"))" })")
        #endif
        renderTask = Task { [weak self] in
            do {
                let image = try await renderer.render(request)
                guard !Task.isCancelled, let self, self.isCurrent(signature) else {
                    #if DEBUG
                    print("[tryon] stale result ignored")
                    #endif
                    return
                }
                self.preview = .ready(image, isTryOn: renderer.producesTryOn, signature: signature)
                #if DEBUG
                print("[tryon] ready \(Int(image.size.width))x\(Int(image.size.height)) isTryOn=\(renderer.producesTryOn)")
                #endif
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self, self.isCurrent(signature) else { return }
                self.preview = .failed(error.localizedDescription, signature: signature)
                #if DEBUG
                print("[tryon] failed \(error.localizedDescription)")
                #endif
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
