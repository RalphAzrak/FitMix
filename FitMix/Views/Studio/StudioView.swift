import SwiftUI
import UIKit
import AVFoundation

/// Studio: the user trying on the look chosen in Outfit Review, with each garment underneath to
/// inspect, swap, and shop. "Street Look" shows the original capture as the reference.
/// Fed by Outfit Review through `StudioStore.open(_:selected:tryOnSource:)`. Lives in the Studio tab.
struct StudioView: View {
    enum PreviewMode: Hashable { case tryOn, street }

    /// Opens the Camera flow over the app.
    var openCamera: () -> Void

    @Environment(StudioStore.self) private var studio
    @Environment(AvatarStore.self) private var avatar
    @Environment(ProfileStore.self) private var profile
    @Environment(AppRouter.self) private var router
    @Environment(CartStore.self) private var cart
    @Environment(AuthSession.self) private var auth
    @Environment(SavedLookStore.self) private var library

    @State private var swapPiece: WorkingLook.Piece?
    @State private var showZoom = false
    @State private var mode: PreviewMode = .tryOn
    @State private var addPhoto = false
    @State private var matchListPiece: WorkingLook.Piece?
    @State private var refinementPiece: WorkingLook.Piece?
    @State private var needsAvatar = false
    @State private var showBudget = false
    @State private var savingLook = false
    @State private var savedLookKey: String?
    @State private var saveLookFailed = false
    @State private var mixRequest: WardrobeMixRequest?
    /// False while the preview is scrolled out of view; the progress pill shows then.
    @State private var heroVisible = true
    /// The render the user has already seen finish, so the pill doesn't nag about it.
    @State private var seenSignature: String?
    @State private var scrollTarget: String?

    private static let previewAnchor = "studioPreview"

    /// Debug: FM_DEBUG_STUDIO_NO_AUTOSCROLL=1 leaves the page where it is when something goes on the avatar,
    /// to check the floating progress pill.
    private static var debugNoAutoScroll: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["FM_DEBUG_STUDIO_NO_AUTOSCROLL"] == "1"
        #else
        false
        #endif
    }

    var body: some View {
        studioContent
            .sheet(item: $mixRequest) { request in
                WardrobeMixPicker(request: request, scannedSlot: studio.scannedSlot) { item, image in
                    if !studio.addToMix(item, image: image, avatar: avatar.avatarImage) { needsAvatar = true }
                }
            }
            // Something went on the avatar: show the preview where the result will appear.
            .onChange(of: studio.avatarChangeCount) {
                mode = .tryOn
                seenSignature = nil
                if !heroVisible, !Self.debugNoAutoScroll { scrollTarget = Self.previewAnchor }
            }
            // Feel and hear when the try-on lands, even while looking elsewhere.
            .sensoryFeedback(trigger: readySignature) { _, new in
                new == nil ? nil : .success
            }
            .onChange(of: readySignature) {
                guard readySignature != nil else { return }
                if heroVisible { seenSignature = readySignature }
                AccessibilityNotification.Announcement("Try-on ready").post()
            }
            .onChange(of: auth.user?.id) { studio.clearMix(unlessOwnedBy: auth.user?.id) }
            #if DEBUG
            .task(id: studio.lookNumber) { await debugWardrobeMix() }
            #endif
    }

    private var studioContent: some View {
        VStack(spacing: 0) {
            FMTopBar { FMBagButton(count: cart.count) { router.openCart() } }
            if let item = studio.wardrobeItem {
                wardrobeTryOn(item)
            } else if let scan = studio.scan, let look = studio.look, let hero = studio.hero {
                lookPage(scan: scan, look: look, hero: hero)
            } else {
                emptyState
            }
        }
        .background(Color.fmCanvas.ignoresSafeArea())
        .preferredColorScheme(.light)
        .sheet(isPresented: $showBudget) { OutfitBudgetSheet(cap: studio.outfitBudget, save: studio.setBudget) }
        .sheet(item: $swapPiece) { SwapPickerSheet(piece: $0) }
        .sheet(item: $matchListPiece) { piece in
            MatchListSheet(category: piece.detected.category, listings: studio.matchLists[piece.id] ?? [],
                           budgetCurrency: studio.outfitBudget == nil ? nil : OutfitBudget.currency,
                           chosenID: studio.matchStates[piece.id].flatMap { if case .found(let p) = $0 { p.id } else { nil } }) { product in
                guard studio.chooseListing(product, for: piece.id) else { return false }
                matchListPiece = nil
                return true
            }
        }
        .sheet(item: $refinementPiece) { piece in
            if let scan = studio.scan, let detected = piece.detected.bounds,
               let bounds = studio.matchCropBounds[piece.id] {
                MatchRefinementSheet(frame: scan.image, category: piece.detected.category,
                                     detectedBounds: detected, initialBounds: bounds,
                                     brand: studio.matchBrands[piece.id] ?? "",
                                     description: studio.matchDescriptions[piece.id]) { bounds, brand in
                    studio.refineMatch(pieceID: piece.id, scanID: scan.id, bounds: bounds, brand: brand)
                }
            }
        }
        #if DEBUG
        // FM_DEBUG_AUTO_TRYON=1: press "Try on my avatar" once the selected garment's match arrives.
        .task(id: studio.selectedPiece.flatMap { studio.matchStates[$0.id] }) {
            // Runs on appear too, in case the match arrived before Studio did.
            guard ProcessInfo.processInfo.environment["FM_DEBUG_AUTO_TRYON"] == "1", studio.avatarTryOn == nil, studio.wardrobeItem == nil,
                  let piece = studio.selectedPiece, case .found? = studio.matchStates[piece.id] else { return }
            try? await Task.sleep(for: .seconds(2))
            tryOnAvatar(piece)
        }
        #endif
        .alert("Create your avatar first", isPresented: $needsAvatar) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try-on uses your full-body avatar. Create it in My Avatar, then come back to try this on.")
        }
        .fullScreenCover(isPresented: $showZoom) {
            if mode == .tryOn, let image = tryOnImage {
                ZoomableImageView(image: image, focus: nil, focusLabel: nil)
            } else if let hero = studio.hero {
                ZoomableImageView(image: hero.image, focus: studio.selectedPiece?.detected.bounds.flatMap(hero.convert),
                                  focusLabel: studio.selectedPiece.map { studio.matchGarmentLabels[$0.id] ?? $0.detected.category.title })
            }
        }
        .sheet(isPresented: $addPhoto) {
            TryOnPhotoSheet { studio.setTryOnSource($0) }
        }
        .onAppear {
            mode = defaultMode
            studio.setTryOnVisible(mode == .tryOn)
        }
        .onDisappear { studio.setTryOnVisible(false) }
        // A new look opens on the try-on view when there's something to try on.
        .onChange(of: studio.lookNumber) { mode = defaultMode }
        .onChange(of: mode) { studio.setTryOnVisible(mode == .tryOn) }
        .onChange(of: auth.user?.id) {
            savedLookKey = nil
            saveLookFailed = false
        }
    }

    #if DEBUG
    /// FM_DEBUG_WARDROBE_MIX=/path.png (+ FM_DEBUG_WARDROBE_MIX_CATEGORY=pants|tshirt|shoes|outerwear, default
    /// pants): puts that local image on the avatar as a wardrobe piece shortly after a look opens.
    private func debugWardrobeMix() async {
            let env = ProcessInfo.processInfo.environment
            guard let path = env["FM_DEBUG_WARDROBE_MIX"], let image = UIImage(contentsOfFile: path), studio.look != nil else { return }
            try? await Task.sleep(for: .seconds(Double(env["FM_DEBUG_WARDROBE_MIX_DELAY"] ?? "") ?? 4))
            let category = env["FM_DEBUG_WARDROBE_MIX_CATEGORY"].flatMap(WardrobeCategory.init(rawValue:)) ?? .pants
            let item = WardrobeItem(id: UUID(), ownerID: auth.user?.id ?? UUID(), name: "My \(category.garment.title.lowercased()) (test)",
                                    category: category, photoRevision: UUID(), originalPath: path, cleanedPath: nil,
                                    thumbnailPath: path, prefersCleaned: false, rowVersion: UUID(), createdAt: .now, updatedAt: .now)
            studio.addToMix(item, image: image, avatar: avatar.avatarImage)
    }
    #endif

    private func lookPage(scan: OutfitScan, look: WorkingLook, hero: HeroFrame) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                lookHeader.padding(.top, 10).padding(.bottom, 8)
                if studio.isLiveLook {
                    ShoppingDepartmentPicker(title: "Shop this scan for", identifier: "scanShoppingDepartment", selection: Binding(
                        get: { studio.shoppingDepartment }, set: studio.setShoppingDepartment
                    ))
                    .fmCard(padding: 10)
                    .padding(.bottom, 8)
                    budgetControl.padding(.bottom, 12)
                }
                Picker("Preview view", selection: $mode) {
                    Text("Try On").tag(PreviewMode.tryOn)
                    Text("Scanned Outfit").tag(PreviewMode.street)
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 12)
                .id(Self.previewAnchor)
                heroArea(scan: scan, hero: hero, look: look)
                    .onScrollVisibilityChange(threshold: 0.3) { heroVisible = $0 }
                if saveLookFailed {
                    NoticeRow(tone: .caution, text: "Couldn't save this look. Try again.").padding(.top, 10)
                }
                if studio.isLiveLook {
                    outfitBoard(look).padding(.top, 14)
                }
                if studio.isLiveLook, let product = studio.selectedPiece?.product {
                    selectedProduct(product).padding(.top, 12)
                }
                garments(look).padding(.top, 18)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .defaultScrollAnchor(Self.debugScrollAnchor)
        .overlay(alignment: .bottom) {
            if let phase = pillPhase {
                TryOnProgressPill(phase: phase, thumbnail: pillThumbnail) { scrollTarget = Self.previewAnchor }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: pillPhase)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer(look) }
        .onChange(of: scrollTarget) {
            guard let target = scrollTarget else { return }
            withAnimation(.smooth(duration: 0.45)) { proxy.scrollTo(target, anchor: .top) }
            if target == Self.previewAnchor, case .ready(_, _, let signature) = studio.preview { seenSignature = signature }
            scrollTarget = nil
        }
        }
    }

    // MARK: Try-on progress

    /// The signature of a finished render of the avatar, once one is on screen.
    private var readySignature: String? {
        if case .ready(_, _, let signature) = studio.preview, studio.isDressingAvatar { return signature }
        return nil
    }

    /// The floating pill's state: only while the preview is out of view and there's news about it.
    private var pillPhase: TryOnProgressPill.Phase? {
        guard !heroVisible, studio.isDressingAvatar || mode == .tryOn else { return nil }
        switch studio.preview {
        case .rendering: return .rendering
        case .ready(_, _, let signature): return signature == seenSignature ? nil : .ready
        case .failed(_, let signature): return signature == seenSignature ? nil : .failed
        default: return nil
        }
    }

    private var pillThumbnail: UIImage? {
        if case .ready(let image, _, _) = studio.preview { return image }
        return studio.tryOnSource
    }

    /// "Jacket + your Pants": what the avatar is being dressed in.
    private var outfitSummary: String? {
        guard studio.isDressingAvatar else { return nil }
        var parts: [String] = []
        if let listing = studio.avatarTryOn { parts.append("the scanned \(listing.category.family.badgeTitle.lowercased())") }
        for slot in AvatarOutfitSlot.bodyOrder where slot != studio.scannedSlot {
            if studio.wardrobeMix[slot] != nil { parts.append("your \(slot.family.badgeTitle.lowercased())") }
        }
        return parts.isEmpty ? nil : ListFormatter.localizedString(byJoining: parts)
    }

    // MARK: Outfit board

    private func outfitBoard(_ look: WorkingLook) -> some View {
        var options: [AvatarOutfitSlot: WorkingLook.Piece] = [:]
        for piece in look.pieces {
            guard let slot = BackendOutfitTryOnRenderer.slot(for: piece.detected.category), options[slot] == nil,
                  case .found(let product)? = studio.matchStates[piece.id], product.image != nil else { continue }
            options[slot] = piece
        }
        return AvatarOutfitBoard(
            listing: studio.avatarTryOn, scannedSlot: studio.scannedSlot, mix: studio.wardrobeMix,
            scannedOptions: options, hasAvatar: avatar.avatarImage != nil,
            tryScanned: { tryOnAvatar($0) },
            showScanned: {
                guard let id = studio.avatarTryOn?.pieceID else { return }
                studio.select(id)
                scrollTarget = id.uuidString
            },
            pickFromWardrobe: { slot in
                guard avatar.avatarImage != nil else { needsAvatar = true; return }
                mixRequest = WardrobeMixRequest(slot: slot)
            },
            remove: { studio.removeFromMix($0) },
            removeListing: { studio.removeAvatarListing() })
    }

    private func wardrobeTryOn(_ item: WardrobeItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FMPageHeading(title: item.title, detail: "Wardrobe Try-On")
                TryOnHero(preview: studio.preview, source: studio.wardrobePerson, wardrobeItemName: item.title,
                          addPhoto: { addPhoto = true }, retry: studio.retryPreview)
                    .containerRelativeFrame(.vertical) { height, _ in min(470, max(315, height * 0.65)) }
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                if let image = studio.wardrobeGarment?.image {
                    HStack(spacing: 12) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(width: 66, height: 66)
                            .background(.white, in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.headline)
                            Text(item.category.title).font(.subheadline).foregroundStyle(Color.fmSecondary)
                        }
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { wardrobeTryOnActions }
                    VStack(alignment: .leading, spacing: 10) { wardrobeTryOnActions }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var wardrobeTryOnActions: some View {
        Button("Back to Wardrobe", systemImage: "square.grid.2x2") { router.tab = .closet }
            .buttonStyle(FMOutlineButtonStyle())
        Button("Close Try-On") { studio.closeWardrobeItem() }
            .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
    }

    /// "Try on my avatar" on a found card: the chosen listing plus the user's full-body avatar go to try-on.
    /// Debug: FM_DEBUG_STUDIO_SCROLL=0.6 opens Studio scrolled that far down the page (1 is the bottom), for
    /// screenshots of the garments below the photo.
    private static var debugScrollAnchor: UnitPoint? {
        #if DEBUG
        if let position = ProcessInfo.processInfo.environment["FM_DEBUG_STUDIO_SCROLL"].flatMap(Double.init) {
            return UnitPoint(x: 0.5, y: min(max(position, 0), 1))
        }
        #endif
        return nil
    }

    private func tryOnAvatar(_ piece: WorkingLook.Piece) {
        // Already on the avatar: just bring the preview into view.
        if avatarState(for: piece) != .off {
            mode = .tryOn
            scrollTarget = Self.previewAnchor
            return
        }
        if studio.tryOnAvatar(pieceID: piece.id, avatar: avatar.avatarImage) {
            withAnimation(.snappy(duration: 0.2)) { mode = .tryOn }
        } else if avatar.avatarImage == nil {
            needsAvatar = true
        }
    }

    /// Whether this card's chosen listing is the one on the avatar, and how far its render is.
    private func avatarState(for piece: WorkingLook.Piece) -> AvatarCardState {
        guard let listing = studio.avatarTryOn, listing.pieceID == piece.id, listing.listingID == piece.product?.id else { return .off }
        if case .rendering = studio.preview { return .rendering }
        return .on
    }

    private var defaultMode: PreviewMode {
        #if DEBUG
        if ProcessInfo.processInfo.environment["FM_DEBUG_STUDIO_MODE"] == "street" { return .street }
        #endif
        return (studio.isLiveLook || studio.look?.pieces.isEmpty ?? true) ? .street : .tryOn
    }

    private var tryOnImage: UIImage? {
        if case .ready(let image, _, _) = studio.preview { return image }
        return studio.tryOnSource
    }

    // MARK: Look header

    private var lookHeader: some View {
        HStack(spacing: 8) {
            FMPageHeading(title: "Studio")
            if let snapshot = studioSnapshot {
                FMRoundIconButton(systemName: savedLookKey == snapshot.key ? "bookmark.fill" : "bookmark",
                                  label: savedLookKey == snapshot.key ? "Look saved" : "Save Look") {
                    guard auth.user != nil else { router.openAccount(); return }
                    Task { await saveLook(snapshot) }
                }
                .disabled(savingLook || savedLookKey == snapshot.key)
            }
            if isRefinementAvailable, let piece = studio.selectedPiece {
                FMRoundIconButton(systemName: "crop", label: "Refine Search") { refinementPiece = piece }
                    .accessibilityHint("Adjust the garment crop or filter by brand")
                    .accessibilityIdentifier("refine-match")
            }
            optionsMenu
        }
    }

    private var isRefinementAvailable: Bool {
        studio.isLiveLook && studio.selectedPieceID.flatMap { studio.matchCropBounds[$0] } != nil
    }

    private struct Snapshot {
        let image: UIImage
        let key: String
        let kind: SavedLook.Kind
        let pieces: [SavedLook.Piece]
    }

    private var studioSnapshot: Snapshot? {
        let pieces = (studio.look?.pieces ?? []).map {
            SavedLook.Piece(slot: nil, itemID: nil, name: $0.product?.name ?? $0.detected.category.title)
        }
        if mode == .street, let scan = studio.scan, let hero = studio.hero {
            let originalPieces = (studio.look?.pieces ?? []).map {
                SavedLook.Piece(slot: nil, itemID: nil, name: $0.detected.category.title)
            }
            return Snapshot(image: hero.image, key: scan.id.uuidString, kind: .scan, pieces: originalPieces)
        }
        if case .ready(let image, true, let signature) = studio.preview {
            let previewPieces = studio.avatarTryOn.map {
                [SavedLook.Piece(slot: nil, itemID: nil, name: $0.productName)]
            } ?? pieces
            return Snapshot(image: image, key: signature, kind: .preview, pieces: previewPieces)
        }
        return nil
    }

    private func saveLook(_ snapshot: Snapshot) async {
        guard !savingLook, savedLookKey != snapshot.key else { return }
        savingLook = true
        saveLookFailed = false
        defer { savingLook = false }
        do {
            _ = try await library.save(image: snapshot.image, pieces: snapshot.pieces, ownerID: auth.user?.id,
                                       kind: snapshot.kind)
            savedLookKey = snapshot.key
        } catch {
            saveLookFailed = true
        }
    }

    private var optionsMenu: some View {
        Menu {
            Button { addPhoto = true } label: { Label("Change Try-On Photo", systemImage: "camera") }
            if !studio.isLiveLook, let selected = studio.selectedPiece {
                Button { swapPiece = selected } label: {
                    Label("Swap \(selected.detected.category.title)", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        } label: {
            FMRoundIcon(systemName: "slider.horizontal.3")
        }
        .accessibilityLabel("Look options")
        .accessibilityIdentifier("studioOptions")
    }

    // MARK: Hero

    private func heroArea(scan: OutfitScan, hero: HeroFrame, look: WorkingLook) -> some View {
        Group {
            switch mode {
            case .tryOn:
                TryOnHero(preview: studio.preview, source: studio.tryOnSource, avatarListing: studio.avatarTryOn,
                          outfitSummary: outfitSummary,
                          addPhoto: { addPhoto = true }, retry: studio.retryPreview)
            case .street:
                HeroCapture(hero: hero, look: look, selectedID: studio.selectedPieceID,
                            tooltip: studio.selectedPiece.flatMap(tooltip),
                            labels: studio.isLiveLook ? studio.matchGarmentLabels : [:]) { id in
                    withAnimation(.snappy(duration: 0.2)) { studio.select(id) }
                }
            }
        }
        // Most of the screen, with the top of the garment row still in view.
        .containerRelativeFrame(.vertical) { length, _ in min(max(length * 0.6, 300), 600) }
        .frame(maxWidth: .infinity)
        .fmHeroFrame()
        .overlay(alignment: .topLeading) { heroChips(scan: scan).padding(12) }
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 12) {
                if mode == .street || tryOnImage != nil {
                    FMFloatingButton(systemName: "plus.magnifyingglass", label: "Zoom photo") { showZoom = true }
                }
            }
            .padding(14)
        }
        .overlay(alignment: .bottomLeading) {
            if mode == .street, look.pieces.contains(where: \.isSwapped) {
                Text("Photo shows the original outfit")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 28)
                    .background(Color.fmCharcoal.opacity(0.7), in: Capsule())
                    .padding(14)
            }
        }
    }

    /// Top-left of the hero: what the image is, then the latest swap.
    private func heroChips(scan: OutfitScan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if mode == .tryOn, let status = TryOnHero.status(preview: studio.preview, source: studio.tryOnSource, avatarListing: studio.avatarTryOn,
                                                                dressingAvatar: studio.isDressingAvatar) {
                FMChip(text: status.text, dot: status.isTryOn ? .fmLime : Color.fmOutline.opacity(0.55))
                    .accessibilityIdentifier("tryOnStatus")
            }
            if mode == .tryOn, studio.wardrobeMix.isEmpty, let listing = studio.avatarTryOn { ListingChip(listing: listing) }
            if let lastSwap = studio.lastSwap {
                FMChip(text: "\(lastSwap.category.title) Swapped", dot: .fmLime, icon: "arrow.triangle.2.circlepath")
                    .accessibilityIdentifier("swapBadge")
            }
            #if DEBUG
            if let kind = SampleScans.kind(of: scan) {
                Text(kind == .illustration ? "SAMPLE SCAN" : "TEST PHOTO · FIXTURE GARMENT DATA")
                    .font(.system(size: 10, weight: .bold)).tracking(0.8)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).frame(minHeight: 22)
                    .background(Color.fmCharcoal.opacity(0.75), in: Capsule())
            }
            #endif
        }
    }

    /// "W32 L30 · Raw Denim": the user's saved size for this kind of piece (from Profile), then its name.
    private func tooltip(for piece: WorkingLook.Piece) -> String? {
        if studio.isLiveLook { return studio.matchGarmentLabels[piece.id] ?? piece.detected.category.title }
        let sizing = profile.sizing
        let size: String? = switch piece.detected.category {
        case .jacket, .tshirt, .top, .dress: sizing.top?.rawValue
        case .pants, .skirt, .shorts, .bottoms: sizing.bottom?.display
        case .shoes: sizing.shoe?.display
        case .bag, .hat, .accessory, .other: nil
        }
        let parts = [size, piece.displayName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func selectedProduct(_ product: CatalogProduct) -> some View {
        HStack(alignment: .center, spacing: 12) {
            GarmentTile(source: product.image.tileSource, category: product.category)
                .frame(width: 62, height: 62)
            VStack(alignment: .leading, spacing: 3) {
                Text(product.name).font(.system(size: 14, weight: .semibold))
                Text(product.visualMatchLabel)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(AuthPalette.primary)
                if let retailer = product.retailer {
                    Text(product.price.map { "\(retailer) · \($0.formatted) \($0.currencyCode)" } ?? retailer)
                        .font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("studioSelectedProduct")
    }

    // MARK: Garments

    private func garments(_ look: WorkingLook) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FMSectionHeader(title: "Garments") {
                if !look.pieces.isEmpty, !studio.isLiveLook {
                    let selected = studio.selectedPiece
                    Button("Swap item") { swapPiece = selected }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.fmCobalt)
                        .frame(minHeight: 44)
                        .disabled(selected == nil)
                        .accessibilityHint(selected.map { "Swap the selected \($0.detected.category.title.lowercased())" } ?? "Select a garment first")
                }
            }
            #if DEBUG
            if let scan = studio.scan, SampleScans.kind(of: scan) == .fixture {
                NoticeRow(tone: .caution, text: studio.isLiveLook ? "Test fixture: Camera used a test photo"
                                                                : "Test fixture: garment data is from scan.json")
                    .font(.system(size: 12))
                    .accessibilityIdentifier("fixtureNotice")
            }
            #endif
            if look.pieces.isEmpty {
                NoGarmentsCard()
            } else if studio.isLiveLook {
                let ordered = Self.headToToe(look.pieces)
                garmentJumpBar(ordered)
                // One full-width box per garment, stacked, so each one's chosen product photo is large and none
                // is hidden off to the side. The selected garment's other results follow its box.
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ordered) { piece in
                        let listings = studio.matchLists[piece.id] ?? []
                        let close = listings.filter { !$0.isAlternative }
                        let alternatives = listings.filter(\.isAlternative)
                        RetailerMatchCard(piece: piece, selected: piece.id == studio.selectedPieceID,
                                          state: studio.matchStates[piece.id],
                                          crop: studio.cropPreviews[piece.id],
                                          garmentLabel: studio.matchGarmentLabels[piece.id],
                                          moreCount: listings.filter { $0.id != piece.product?.id }.count,
                                          fallbackOnly: close.isEmpty && !alternatives.isEmpty,
                                          select: { withAnimation(.snappy(duration: 0.2)) { studio.select(piece.id) } },
                                          brand: studio.matchBrands[piece.id],
                                          retry: { studio.findMatch(for: piece.id) },
                                          clearBrand: { studio.clearMatchBrand(for: piece.id) },
                                          showMore: { matchListPiece = piece },
                                          tryOnAvatar: { tryOnAvatar(piece) },
                                          avatarState: avatarState(for: piece),
                                          viewOnAvatar: { scrollTarget = Self.previewAnchor })
                            .id(piece.id.uuidString)
                        if piece.id == studio.selectedPieceID, close.count > 1 {
                            resultList(close, for: piece, title: "Close matches")
                        }
                        if !alternatives.isEmpty, close.isEmpty || piece.id == studio.selectedPieceID {
                            resultList(alternatives, for: piece, title: "Similar options")
                        }
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(look.pieces) { piece in
                            GarmentCard(piece: piece, selected: piece.id == studio.selectedPieceID,
                                        hasRegion: piece.detected.bounds != nil) {
                                withAnimation(.snappy(duration: 0.2)) { studio.select(piece.id) }
                            }
                            .containerRelativeFrame(.horizontal, count: 4, spacing: 12)
                        }
                    }
                    .padding(.top, 8)
                }
                .scrollClipDisabled()
            }
        }
    }

    /// Jacket → shirt → pants → shoes, whatever order detection found them in.
    private static func headToToe(_ pieces: [WorkingLook.Piece]) -> [WorkingLook.Piece] {
        pieces.enumerated().sorted { left, right in
            left.element.detected.category.bodyOrder != right.element.detected.category.bodyOrder
                ? left.element.detected.category.bodyOrder < right.element.detected.category.bodyOrder
                : left.offset < right.offset
        }.map(\.element)
    }

    /// One chip per garment in its own color, with how its search is going. Tapping one selects it and
    /// scrolls to its card, so a long page of results is easy to move around.
    private func garmentJumpBar(_ pieces: [WorkingLook.Piece]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(pieces) { piece in
                    let category = piece.detected.category
                    let selected = piece.id == studio.selectedPieceID
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { studio.select(piece.id) }
                        scrollTarget = piece.id.uuidString
                    } label: {
                        HStack(spacing: 6) {
                            GarmentGlyph(family: category.family, size: 13)
                            Text(category.family == .other ? category.title : category.family.badgeTitle)
                                .font(.system(size: 14, weight: .semibold))
                            jumpStatus(for: piece)
                        }
                        .foregroundStyle(selected ? .white : category.tint)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 40)
                        .background(selected ? category.tint : category.tint.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityHint("Shows its matches")
                    .accessibilityIdentifier("jump-\(category.rawValue)")
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func jumpStatus(for piece: WorkingLook.Piece) -> some View {
        switch studio.matchStates[piece.id] {
        case .searching: ProgressView().controlSize(.mini)
        case .found:
            if studio.avatarTryOn?.pieceID == piece.id {
                Image(systemName: "person.crop.rectangle.fill").font(.system(size: 11)).accessibilityLabel("On your avatar")
            } else {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).accessibilityLabel("Match found")
            }
        case .failed, .noMatch, .budgetMissing:
            Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold)).accessibilityLabel("No match")
        case nil: EmptyView()
        }
    }

    private func resultList(_ listings: [CatalogProduct], for piece: WorkingLook.Piece, title: String) -> some View {
        MatchResultsList(title: title, category: piece.detected.category, listings: listings, chosenID: piece.product?.id,
                         choose: { studio.chooseListing($0, for: piece.id) },
                         tryOn: { product in
                             guard studio.chooseListing(product, for: piece.id) else { return false }
                             tryOnAvatar(piece)
                             return true
                         })
    }

    // MARK: Budget and shopping

    private var budgetControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { showBudget = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: studio.outfitBudget == nil ? "dollarsign.circle" : "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.fmCobalt)
                        .frame(width: 40, height: 40)
                        .background(Color.fmCobalt.opacity(0.10), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        if let cap = studio.outfitBudget {
                            let format = Decimal.FormatStyle.Currency(code: OutfitBudget.currency)
                                .presentation(.narrow).precision(.fractionLength(0...2))
                            let subtotal = studio.budgetSubtotal.formatted(format)
                            let limit = cap.formatted(format)
                            Text("Outfit budget").font(.subheadline.weight(.semibold))
                            Text("\(subtotal) of \(limit) \(OutfitBudget.currency)")
                                .font(.caption)
                                .foregroundStyle(Color.fmSecondary)
                                .accessibilityIdentifier("budgetSubtotal")
                        } else {
                            Text("Set Outfit Budget").font(.subheadline.weight(.semibold))
                            Text("Find a look within your limit")
                                .font(.caption)
                                .foregroundStyle(Color.fmSecondary)
                        }
                    }
                    .foregroundStyle(Color.fmInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if studio.outfitBudget != nil {
                        Text("Edit").font(.subheadline.weight(.semibold)).foregroundStyle(Color.fmCobalt)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.fmCobalt)
                            .accessibilityHidden(true)
                    }
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("outfitBudgetButton")

            if studio.outfitBudget != nil {
                if studio.isExpandingBudget || studio.matchStates.values.contains(.searching) {
                    Label("Checking matches for this budget", systemImage: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(Color.fmSecondary)
                        .padding([.horizontal, .bottom], 10)
                } else if !studio.missingBudgetPieces.isEmpty {
                    Text("Still missing: \(studio.missingBudgetPieces.map(\.title).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(Color.fmSecondary)
                        .accessibilityIdentifier("budgetMissing")
                        .padding([.horizontal, .bottom], 10)
                }
                if studio.budgetSearchFailed {
                    Button("Retry budget search", action: studio.retryBudgetSearch)
                        .font(.caption.weight(.semibold))
                        .padding([.horizontal, .bottom], 10)
                }
            }
        }
        .background(Color.fmCobalt.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.fmCobalt.opacity(0.18)))
    }

    private func footer(_ look: WorkingLook) -> some View {
        VStack(spacing: 8) {
            if studio.outfitBudget == nil || !studio.isLiveLook {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Matched subtotal").font(.subheadline.weight(.semibold))
                        Spacer()
                        PriceSummary(look: look)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Matched subtotal").font(.subheadline.weight(.semibold))
                        PriceSummary(look: look)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 10) {
                FMRoundIconButton(systemName: "camera", label: "Open Camera", action: openCamera)
                Button { router.showShopLook = true } label: {
                    Label("Shop This Look", systemImage: "bag")
                }
                .buttonStyle(FMFilledButtonStyle())
                .accessibilityIdentifier("shopThisLook")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.fmBackground)
    }

    // MARK: Empty

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FMPageHeading(title: "Studio")
                VStack(spacing: 14) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Color.fmCobalt)
                        .frame(width: 72, height: 72)
                        .background(.white, in: Circle())
                        .fmFloatingShadow()
                        .accessibilityHidden(true)
                    Text("Scan an outfit")
                        .font(.fmDisplay(28))
                        .foregroundStyle(Color.fmInk)
                        .accessibilityAddTraits(.isHeader)
                    Text("Find individual garments in a look and explore ways to wear them.")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.fmSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: openCamera) { Label("Scan Outfit", systemImage: "camera") }
                        .buttonStyle(FMFilledButtonStyle())
                        .padding(.top, 6)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity)
                .fmHeroFrame()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
    }
}

// MARK: - Hero

/// The captured person in their original outfit (the scan's photo, framed on the subject). The selected
/// garment is marked with a hotspot and a tooltip. Swaps never change this image. The parent supplies
/// the frame, chips and floating buttons.
private struct HeroCapture: View {
    var hero: HeroFrame
    var look: WorkingLook
    var selectedID: UUID?
    var tooltip: String?
    /// Names from search per piece ("Bomber jacket"), shown on its outline.
    var labels: [UUID: String] = [:]
    var select: (UUID) -> Void = { _ in }

    private var selected: WorkingLook.Piece? { look.pieces.first { $0.id == selectedID } }

    var body: some View {
        GeometryReader { proxy in
            let fitted = AVMakeRect(aspectRatio: hero.image.size, insideRect: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                Image(uiImage: hero.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: fitted.width, height: fitted.height)
                    .offset(x: fitted.minX, y: fitted.minY)
                    .accessibilityLabel(heroLabel)
                    .accessibilityIdentifier("heroPhoto")

                // Every garment outlined in its own color, so jacket, shirt, pants and shoes are told apart at a glance.
                // The selected one is drawn last, so its outline and label sit on top.
                ForEach(look.pieces.filter { $0.id != selectedID } + look.pieces.filter { $0.id == selectedID }) { piece in
                    if let bounds = piece.detected.bounds.flatMap(hero.convert) {
                        let rect = CGRect(x: fitted.minX + bounds.minX * fitted.width, y: fitted.minY + bounds.minY * fitted.height,
                                          width: bounds.width * fitted.width, height: bounds.height * fitted.height)
                        let isSelected = piece.id == selectedID
                        let tint = piece.detected.category.tint
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(tint.opacity(isSelected ? 0.10 : 0.04))
                            .strokeBorder(tint, style: StrokeStyle(lineWidth: isSelected ? 3 : 1.8, dash: isSelected ? [] : [6, 4]))
                            .frame(width: rect.width, height: rect.height)
                            .overlay(alignment: .topLeading) {
                                // Selected: the full name. Others: just their glyph, so nested garments
                                // (a shirt under a jacket) don't stack labels on each other.
                                Group {
                                    if isSelected {
                                        GarmentCategoryBadge(piece.detected.category, title: tooltip, solid: true)
                                            .fixedSize()
                                            .offset(x: -2, y: -12)
                                    } else {
                                        GarmentGlyph(family: piece.detected.category.family, size: 11)
                                            .foregroundStyle(.white)
                                            .frame(width: 24, height: 24)
                                            .background(tint, in: Circle())
                                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                                            .offset(x: -6, y: -8)
                                    }
                                }
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { select(piece.id) }
                            .position(x: rect.midX, y: rect.midY)
                            .accessibilityElement()
                            .accessibilityLabel(piece.detected.category.title)
                            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                            .accessibilityIdentifier("heroOutline-\(piece.detected.category.rawValue)")
                    }
                }

            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    private var heroLabel: String {
        let pieces = look.pieces.map { $0.detected.category.title.lowercased() }.joined(separator: ", ")
        return "Street capture of the scanned outfit" + (pieces.isEmpty ? "" : ": \(pieces)")
    }
}

// MARK: - Garment card

private struct GarmentCard: View {
    var piece: WorkingLook.Piece
    var selected: Bool
    var hasRegion: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                GarmentTile(source: piece.tileSource, category: piece.detected.category, cornerRadius: 10)
                    .frame(maxWidth: .infinity)
                    .frame(height: 96)
                    .overlay(alignment: .bottom) {
                        if let tag { TagPill(text: tag).padding(4) }
                    }
                    .overlay(alignment: .topLeading) {
                        GarmentGlyph(family: piece.detected.category.family, size: 11)
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(piece.detected.category.tint, in: Circle())
                            .padding(3)
                    }
                    .padding(8)
                    .background(piece.detected.category.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(selected ? Color.fmCobalt : piece.detected.category.tint.opacity(0.35), lineWidth: selected ? 2.5 : 1)
                    )
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Color.fmCobalt, in: Circle())
                                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                                .offset(x: 7, y: -7)
                        }
                    }
                    .padding(.bottom, 6)
                Text(piece.detected.category.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(piece.detected.category.tint)
                    .lineLimit(1)
                Text(nameLine)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.fmInk : Color.fmSecondary)
                    .lineLimit(1)
                Capsule()
                    .fill(selected ? Color.fmCobalt : .clear)
                    .frame(width: 30, height: 4)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(hasRegion ? "Marks it in the Street Look photo" : "")
        .accessibilityIdentifier("garment-\(piece.detected.category.rawValue)")
    }

    private var tag: String? {
        guard let replacement = piece.replacement else { return nil }
        return replacement.match == .similar ? "Similar swap" : "Swapped"
    }

    private var nameLine: String {
        if let replacement = piece.replacement { return replacement.name }
        if let label = piece.detected.label { return label }
        if let match = piece.detected.matches.first { return match.match == .similar ? "Similar: \(match.name)" : match.name }
        return "Not identified"
    }

    private var accessibilityText: String {
        var parts = [piece.detected.category.title, nameLine]
        if let tag { parts.append(tag) }
        if case .none = piece.tileSource { parts.append("no image") }
        return parts.joined(separator: ", ")
    }
}

/// A garment from a live selection, with its retailer search. The card shows the garment the user tapped
/// while it searches, then the retailer's own product photo with the tapped garment kept beside it.
private struct RetailerMatchCard: View {
    var piece: WorkingLook.Piece
    var selected: Bool
    var state: RetailerMatchState?
    /// The garment crop the user tapped (the search input).
    var crop: UIImage?
    var garmentLabel: String?
    /// How many other ranked listings there are.
    var moreCount: Int = 0
    var fallbackOnly: Bool
    var select: () -> Void
    var brand: String?
    var retry: () -> Void
    var clearBrand: () -> Void
    var showMore: () -> Void = {}
    var tryOnAvatar: () -> Void = {}
    var avatarState: AvatarCardState = .off
    var viewOnAvatar: () -> Void = {}

    @Environment(\.openURL) private var openURL

    private var category: GarmentCategory { piece.detected.category }
    private var tint: Color { category.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GarmentTile(source: tileSource, category: category)
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .overlay(alignment: .bottom) {
                    // The tapped garment stays fully visible while searching: only a small badge on top.
                    if state == .searching {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Finding a match…")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AuthPalette.onSurface)
                        }
                        .padding(.horizontal, 8).frame(minHeight: 24)
                        .background(.white.opacity(0.92), in: Capsule())
                        .padding(6)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("matchLoading")
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // Once a listing is shown, the tapped garment stays beside it for comparison.
                    if product != nil, let crop {
                        Image(uiImage: crop)
                            .resizable().scaledToFill()
                            .frame(width: 68, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white, lineWidth: 2))
                            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                            .padding(8)
                            .accessibilityLabel("Your scanned \((garmentLabel ?? category.title).lowercased())")
                            .accessibilityIdentifier("scannedCrop")
                    }
                }
                .overlay(alignment: .topLeading) {
                    GarmentCategoryBadge(category, solid: true).padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    if let product, product.isFixture { TagPill(text: "Test fixture").padding(8) }
                }
                .overlay(alignment: .topTrailing) {
                    if avatarState != .off, product?.isFixture != true {
                        Label("On avatar", systemImage: "person.crop.rectangle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).frame(minHeight: 24)
                            .background(Color.fmCobalt, in: Capsule())
                            .padding(8)
                    }
                }
            HStack(spacing: 6) {
                Text(garmentLabel ?? category.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AuthPalette.onSurface)
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
            if let brand, !brand.isEmpty {
                HStack {
                    Label(brand, systemImage: "tag").foregroundStyle(Color.fmSecondary)
                    Spacer(minLength: 0)
                    Button("Clear Brand", systemImage: "xmark.circle", action: clearBrand)
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        .buttonStyle(.plain).foregroundStyle(Color.fmCobalt)
                        .accessibilityIdentifier("clear-match-brand")
                }
                .font(.caption)
            }
            details.padding(.leading, 6)
        }
        .padding(8)
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        // The garment's color runs down the card's edge, so a jacket card never reads as a pants card.
        .overlay(alignment: .leading) {
            Rectangle().fill(tint).frame(width: 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(selected ? AuthPalette.primaryContainer : tint.opacity(0.3), lineWidth: selected ? 2.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture(perform: select)
        // Contain, not combine, so View listing and Retry stay their own buttons for VoiceOver.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Select \(category.title)", select)
        .accessibilityIdentifier("garment-\(category.rawValue)")
    }

    private var product: CatalogProduct? {
        if case .found(let product) = state { return product }
        return nil
    }

    private var tileSource: GarmentTile.Source {
        if let product { return product.image.tileSource }
        return crop.map(GarmentTile.Source.image) ?? .none
    }

    @ViewBuilder
    private var details: some View {
        switch state {
        case .found(let product):
            VStack(alignment: .leading, spacing: 3) {
                if fallbackOnly { noCloseMatchLabel }
                Text(product.visualMatchLabel)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(AuthPalette.primary)
                    .accessibilityIdentifier("matchLabel")
                Text(product.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AuthPalette.onSurface)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("matchName")
                if let retailer = product.retailer {
                    Text(retailer).font(.system(size: 12)).foregroundStyle(AuthPalette.secondary).lineLimit(1)
                }
                if let price = product.price {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(price.formatted).font(.system(size: 15, weight: .bold)).foregroundStyle(AuthPalette.onSurface)
                        Text(price.currencyCode).font(.system(size: 11, weight: .semibold)).foregroundStyle(AuthPalette.secondary)
                    }
                    .accessibilityIdentifier("matchPrice")
                } else {
                    Text("Price unavailable").font(.system(size: 13)).foregroundStyle(AuthPalette.secondary)
                        .accessibilityIdentifier("matchPrice")
                }
                if let url = product.retailerURL {
                    Button { openURL(url) } label: {
                        Label("View listing", systemImage: "arrow.up.right.square")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AuthPalette.primary)
                    .accessibilityHint("Opens the listing at \(product.retailer ?? "the retailer")")
                    .accessibilityIdentifier("viewListing")
                }
                // A try-on needs the product's photo.
                if product.image != nil {
                    avatarButton.padding(.top, 4)
                }
                if moreCount > 0 {
                    Button(action: showMore) {
                        Label("More matches (\(moreCount))", systemImage: "list.bullet")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AuthPalette.primary)
                    .accessibilityIdentifier("moreMatches")
                }
            }
        case .searching:
            Text("Searching the web for \(category.searchNoun) only.")
                .font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .noMatch:
            VStack(alignment: .leading, spacing: 4) {
                noCloseMatchLabel
                retryButton
            }
        case .budgetMissing:
            VStack(alignment: .leading, spacing: 4) {
                Text("Missing from this budget")
                    .font(.system(size: 13, weight: .semibold))
                Button("View alternatives", action: showMore)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AuthPalette.primary)
            }
        case .failed(let message, let retryable):
            VStack(alignment: .leading, spacing: 4) {
                Label(retryable ? "Search failed" : "Search unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AuthPalette.onSurface)
                    .accessibilityIdentifier("matchError")
                Text(message).font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if retryable {
                    retryButton
                }
            }
        case nil:
            Button("Find Similar", systemImage: "magnifyingglass", action: select)
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
                .buttonStyle(.plain)
                .foregroundStyle(Color.fmCobalt)
        }
    }

    /// The card's main action. Once the piece is on the avatar it says so, and takes you to the preview.
    @ViewBuilder
    private var avatarButton: some View {
        switch avatarState {
        case .off:
            Button(action: tryOnAvatar) {
                Label("Try on my avatar", systemImage: "person.crop.rectangle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(minHeight: 40)
                    .background(.fmPrimaryGradient, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Puts this listing on your avatar. The preview at the top of Studio updates.")
            .accessibilityIdentifier("tryOnAvatar")
        case .rendering, .on:
            Button(action: viewOnAvatar) {
                HStack(spacing: 7) {
                    if avatarState == .rendering {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.fmGreen)
                    }
                    Text(avatarState == .rendering ? "Dressing your avatar…" : "On your avatar")
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.fmInk)
                .padding(.horizontal, 14).frame(minHeight: 40)
                .background(Color.fmFill, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.fmHairline))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Scrolls up to the try-on preview")
            .accessibilityIdentifier("viewOnAvatar")
        }
    }

    private var noCloseMatchLabel: some View {
        Text("No close match found")
            .font(.system(size: 13, weight: .semibold))
            .accessibilityIdentifier("noMatch")
    }

    private var retryButton: some View {
        Button(action: retry) {
            Label("Retry", systemImage: "arrow.clockwise")
                .font(.system(size: 13, weight: .semibold))
                .frame(minHeight: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AuthPalette.primary)
        .accessibilityIdentifier("retryMatch")
    }
}

/// A garment card's relation to the avatar preview.
enum AvatarCardState: Equatable { case off, rendering, on }

private extension GarmentCategory {
    /// "this jacket", "these pants".
    var searchNoun: String {
        switch self {
        case .pants, .shoes, .shorts: "these \(title.lowercased())"
        case .tshirt: "this T-shirt"
        default: "this \(title.lowercased())"
        }
    }
}

/// Every result for the selected garment, listed under the cards so none is hidden behind a button.
/// Tapping one puts it on the garment's card.
private struct MatchResultsList: View {
    var title: String
    var category: GarmentCategory
    var listings: [CatalogProduct]
    var chosenID: String?
    var choose: (CatalogProduct) -> Bool
    /// Puts the item on the card and shows it on the user's avatar. False when the budget rules it out.
    var tryOn: (CatalogProduct) -> Bool
    @State private var rejected = false

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AuthPalette.onSurface)
                .accessibilityAddTraits(.isHeader)
            ForEach(listings) { product in
                HStack(alignment: .top, spacing: 10) {
                    GarmentTile(source: product.image.tileSource, category: category)
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(product.visualMatchLabel)
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(AuthPalette.primary)
                            if product.id == chosenID {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                                    .foregroundStyle(AuthPalette.primaryContainer)
                                    .accessibilityLabel("Shown on the card")
                            }
                        }
                        Text(product.name)
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(AuthPalette.onSurface)
                            .lineLimit(2)
                        Text([product.retailer, product.price.map { "\($0.formatted) \($0.currencyCode)" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(AuthPalette.secondary).lineLimit(1)
                        HStack(spacing: 16) {
                            Button { if !tryOn(product) { rejected = true } } label: {
                                Label("Try on", systemImage: "person.crop.rectangle").frame(minHeight: 36)
                            }
                            .accessibilityHint("Shows this item on your avatar")
                            .accessibilityIdentifier("tryOn-\(product.id)")
                            if let url = product.retailerURL {
                                Button { openURL(url) } label: {
                                    Label("View", systemImage: "arrow.up.right.square").frame(minHeight: 36)
                                }
                                .accessibilityLabel("View at \(product.retailer ?? "the store")")
                            }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .buttonStyle(.borderless)
                        .foregroundStyle(AuthPalette.primary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(product.id == chosenID ? AuthPalette.primaryContainer : AuthPalette.containerHigh,
                                      lineWidth: product.id == chosenID ? 2 : 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture { if !choose(product) { rejected = true } }
                .accessibilityElement(children: .contain)
                .accessibilityAction(named: "Show on the card") { if !choose(product) { rejected = true } }
                .accessibilityIdentifier("result-\(product.id)")
            }
        }
        .padding(.top, 6)
        .alert("This item doesn't fit your outfit budget", isPresented: $rejected) {
            Button("OK", role: .cancel) {}
        }
        .accessibilityIdentifier("matchResults")
    }
}

/// Every ranked listing for one garment: exact matches first, then likely-same-brand, then similar.
private struct MatchListSheet: View {
    var category: GarmentCategory
    var listings: [CatalogProduct]
    var budgetCurrency: String?
    var chosenID: String?
    var choose: (CatalogProduct) -> Bool
    @State private var swapRejected = false
    @State private var swapMessage = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List(listings) { product in
                Button {
                    guard !choose(product) else { return }
                    if let budgetCurrency, product.price?.currencyCode != budgetCurrency {
                        swapMessage = "This listing is priced outside your \(budgetCurrency) budget"
                    } else {
                        swapMessage = "This swap exceeds your outfit budget"
                    }
                    swapRejected = true
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        GarmentTile(source: product.image.tileSource, category: category)
                            .frame(width: 72, height: 72)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                TagPill(text: product.visualMatchLabel)
                                if product.isFixture { TagPill(text: "Test fixture") }
                                if product.id == chosenID {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(AuthPalette.primaryContainer)
                                        .accessibilityLabel("Chosen")
                                }
                            }
                            Text(product.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(AuthPalette.onSurface)
                                .lineLimit(2)
                            if let retailer = product.retailer {
                                Text(retailer).font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                            }
                            Text(product.price.map { "\($0.formatted) \($0.currencyCode)" } ?? "Price unavailable")
                                .font(.system(size: 13, weight: product.price == nil ? .regular : .bold))
                                .foregroundStyle(product.price == nil ? AuthPalette.secondary : AuthPalette.onSurface)
                            ForEach(product.evidence, id: \.self) { line in
                                Label(line, systemImage: "checkmark.seal").font(.system(size: 11)).foregroundStyle(AuthPalette.secondary)
                            }
                            if let url = product.retailerURL {
                                Button("View listing") { openURL(url) }
                                    .font(.system(size: 12, weight: .semibold))
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("choose-\(product.id)")
                .accessibilityAddTraits(product.id == chosenID ? .isSelected : [])
            }
            .listStyle(.plain)
            .alert(swapMessage, isPresented: $swapRejected) {
                Button("OK", role: .cancel) {}
            }
            .navigationTitle(listings.allSatisfy(\.isAlternative) ? "Similar options" : "Matches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .accessibilityIdentifier("matchList")
    }
}

/// Shown under the photo when the scan has no garments (e.g. a plain Camera capture before
/// garment recognition is connected). The photo above stays the look's reference.
private struct NoGarmentsCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "tshirt")
                .font(.system(size: 18))
                .foregroundStyle(Color.fmCobalt)
                .frame(width: 40, height: 40)
                .background(.white, in: Circle())
                .overlay(Circle().strokeBorder(Color.fmHairline))
            VStack(alignment: .leading, spacing: 4) {
                Text("No garments detected")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.fmInk)
                Text("Garments recognized in this photo appear here, ready to swap and shop. To try another photo, tap Camera.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.fmSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fmCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.fmHairline))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("noGarments")
    }
}

struct TagPill: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(minHeight: 18)
            .background(Color.fmCobalt, in: Capsule())
    }
}

/// Total of known catalog prices ("$385 USD"), saying when it covers only some pieces.
struct PriceSummary: View {
    var look: WorkingLook

    var body: some View {
        if look.hasMixedCurrencies {
            Text("Prices in several currencies").font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
        } else if let total = look.total {
            VStack(alignment: .trailing, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(total.price.amount.formatted(.currency(code: total.price.currencyCode)
                        .presentation(.narrow).precision(.fractionLength(0...2))))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.fmInk)
                    Text(total.price.currencyCode)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.fmSecondary)
                }
                if total.pricedCount < look.pieces.count {
                    Text("for \(total.pricedCount) of \(look.pieces.count) pieces")
                        .font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
                }
            }
        } else {
            Text("Prices unavailable").font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
        }
    }
}
