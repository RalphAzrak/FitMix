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

    var body: some View {
        VStack(spacing: 0) {
            FMTopBar { FMBagButton(count: cart.count) { router.openCart() } }
            if let item = studio.wardrobeItem {
                wardrobeTryOn(item)
            } else if let scan = studio.scan, let look = studio.look, let hero = studio.hero {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        lookHeader.padding(.top, 10).padding(.bottom, 8)
                        if studio.isLiveLook {
                            budgetControl.padding(.bottom, 12)
                        }
                        Picker("Preview view", selection: $mode) {
                            Text("Try On").tag(PreviewMode.tryOn)
                            Text("Scanned Outfit").tag(PreviewMode.street)
                        }
                        .pickerStyle(.segmented)
                        .padding(.bottom, 12)
                        heroArea(scan: scan, hero: hero, look: look)
                        if saveLookFailed {
                            NoticeRow(tone: .caution, text: "Couldn't save this look. Try again.").padding(.top, 10)
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
                .safeAreaInset(edge: .bottom, spacing: 0) { footer(look) }
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
        if studio.tryOnAvatar(pieceID: piece.id, avatar: avatar.avatarImage) {
            withAnimation(.snappy(duration: 0.2)) { mode = .tryOn }
        } else if avatar.avatarImage == nil {
            needsAvatar = true
        }
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
                          addPhoto: { addPhoto = true }, retry: studio.retryPreview)
            case .street:
                HeroCapture(hero: hero, look: look, selectedID: studio.selectedPieceID,
                            tooltip: studio.selectedPiece.flatMap(tooltip))
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
            if mode == .tryOn, let status = TryOnHero.status(preview: studio.preview, source: studio.tryOnSource, avatarListing: studio.avatarTryOn) {
                FMChip(text: status.text, dot: status.isTryOn ? .fmLime : Color.fmOutline.opacity(0.55))
                    .accessibilityIdentifier("tryOnStatus")
            }
            if mode == .tryOn, let listing = studio.avatarTryOn { ListingChip(listing: listing) }
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
                // One full-width box per garment, stacked, so each one's chosen product photo is large and none
                // is hidden off to the side. The selected garment's other results follow its box.
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(look.pieces) { piece in
                        RetailerMatchCard(piece: piece, selected: piece.id == studio.selectedPieceID,
                                          state: studio.matchStates[piece.id],
                                          crop: studio.cropPreviews[piece.id],
                                          garmentLabel: studio.matchGarmentLabels[piece.id],
                                          moreCount: studio.matchLists[piece.id]?.filter { $0.id != piece.product?.id }.count ?? 0,
                                          select: { withAnimation(.snappy(duration: 0.2)) { studio.select(piece.id) } },
                                          brand: studio.matchBrands[piece.id],
                                          retry: { studio.findMatch(for: piece.id) },
                                          clearBrand: { studio.clearMatchBrand(for: piece.id) },
                                          showMore: { matchListPiece = piece },
                                          tryOnAvatar: { tryOnAvatar(piece) })
                            .id(piece.id)
                        if piece.id == studio.selectedPieceID, let listings = studio.matchLists[piece.id], listings.count > 1 {
                            MatchResultsList(category: piece.detected.category, listings: listings, chosenID: piece.product?.id,
                                             choose: { studio.chooseListing($0, for: piece.id) },
                                             tryOn: { product in
                                                 guard studio.chooseListing(product, for: piece.id) else { return false }
                                                 tryOnAvatar(piece)
                                                 return true
                                             })
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

                if let selected, let bounds = selected.detected.bounds.flatMap(hero.convert) {
                    // The hotspot sits inside the garment, a little in from its left edge.
                    let point = CGPoint(x: fitted.minX + (bounds.minX + bounds.width * 0.18) * fitted.width,
                                        y: fitted.minY + (bounds.minY + bounds.height * 0.3) * fitted.height)
                    // Tooltip to the right of the hotspot, or to its left when the hotspot is on the right half.
                    let onLeft = point.x > proxy.size.width * 0.55
                    if let tooltip {
                        HStack(spacing: 0) {
                            if onLeft {
                                Spacer(minLength: 8)
                                FMTooltip(text: tooltip)
                                Color.clear.frame(width: max(0, proxy.size.width - point.x + 16))
                            } else {
                                Color.clear.frame(width: max(0, point.x + 16))
                                FMTooltip(text: tooltip)
                                Spacer(minLength: 8)
                            }
                        }
                        .frame(width: proxy.size.width)
                        .position(x: proxy.size.width / 2, y: point.y)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("garmentTooltip")
                    }
                    FMHotspot()
                        .position(point)
                        .allowsHitTesting(false)
                        .accessibilityElement()
                        .accessibilityLabel("Marked in photo: \(selected.detected.category.title)")
                        .accessibilityIdentifier("garmentHighlight")
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
                    .padding(8)
                    .background(Color.fmCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(selected ? Color.fmCobalt : Color.fmHairline, lineWidth: selected ? 2.5 : 1)
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
                    .foregroundStyle(selected ? Color.fmCobalt : Color.fmInk)
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
    var select: () -> Void
    var brand: String?
    var retry: () -> Void
    var clearBrand: () -> Void
    var showMore: () -> Void = {}
    var tryOnAvatar: () -> Void = {}

    @Environment(\.openURL) private var openURL

    private var category: GarmentCategory { piece.detected.category }

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
                    if let product, product.isFixture { TagPill(text: "Test fixture").padding(6) }
                }
            HStack(spacing: 6) {
                Text(garmentLabel ?? category.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(selected ? AuthPalette.primary : AuthPalette.onSurface)
                Spacer(minLength: 0)
            }
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
            details
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(selected ? AuthPalette.primaryContainer : AuthPalette.containerHigh, lineWidth: selected ? 2.5 : 1)
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
                    Button(action: tryOnAvatar) {
                        Label("Try on my avatar", systemImage: "person.crop.rectangle")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AuthPalette.primary)
                    .accessibilityHint("Shows this listing with your full-body avatar")
                    .accessibilityIdentifier("tryOnAvatar")
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
                Text("No close match found")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityIdentifier("noMatch")
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
            Text("\(listings.count) results for \(category.searchNoun)")
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
            .navigationTitle("Matches")
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
