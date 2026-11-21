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

    @State private var swapPiece: WorkingLook.Piece?
    @State private var showZoom = false
    @State private var showLiveTwinInfo = false
    @State private var mode: PreviewMode = .tryOn
    @State private var addPhoto = false
    @State private var matchListPiece: WorkingLook.Piece?
    @State private var needsAvatar = false

    var body: some View {
        VStack(spacing: 0) {
            FMTopBar { FMBagButton(count: studio.bagCount) { router.showCart = true } }
            if let scan = studio.scan, let look = studio.look, let hero = studio.hero {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        lookHeader.padding(.top, 10).padding(.bottom, 8)
                        heroArea(scan: scan, hero: hero, look: look)
                        garments(look).padding(.top, 18)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { footer(look) }
            } else {
                emptyState
            }
        }
        .background(Color.fmBackground.ignoresSafeArea())
        .preferredColorScheme(.light)
        .sheet(item: $swapPiece) { SwapPickerSheet(piece: $0) }
        .sheet(item: $matchListPiece) { piece in
            MatchListSheet(category: piece.detected.category, listings: studio.matchLists[piece.id] ?? [],
                           chosenID: studio.matchStates[piece.id].flatMap { if case .found(let p) = $0 { p.id } else { nil } }) { product in
                studio.chooseListing(product, for: piece.id)
                matchListPiece = nil
            }
        }
        #if DEBUG
        // FM_DEBUG_AUTO_TRYON=1: press "Try on my avatar" once the selected garment's match arrives.
        .task(id: studio.selectedPiece.flatMap { studio.matchStates[$0.id] }) {
            // Runs on appear too, in case the match arrived before Studio did.
            guard ProcessInfo.processInfo.environment["FM_DEBUG_AUTO_TRYON"] == "1", studio.avatarTryOn == nil,
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
                                  focusLabel: studio.selectedPiece.map { $0.detected.category.title })
            }
        }
        .sheet(isPresented: $addPhoto) {
            TryOnPhotoSheet { studio.setTryOnSource($0) }
        }
        .onAppear { mode = defaultMode }
        // A new look opens on the try-on view when there's something to try on.
        .onChange(of: studio.lookNumber) { mode = defaultMode }
        .alert("Live Twin isn't available yet", isPresented: $showLiveTwinInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(liveTwinMessage)
        }
    }

    /// "Try on my avatar" on a found card: the chosen listing plus the user's full-body avatar go to try-on.
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
        HStack(alignment: .center, spacing: 8) {
            FMTitleLine(title: String(format: "Look %02d", studio.lookNumber), caption: "Studio Fit")
            Spacer(minLength: 4)
            Button { showLiveTwinInfo = true } label: {
                // Gray dot: Live Twin is off until dressing the avatar is connected. Lime means live.
                FMChip(text: "Live Twin", dot: Color.fmOutline.opacity(0.55), style: .soft)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Live Twin")
            .accessibilityValue("Not available")
            .accessibilityHint("Explains why your avatar preview isn't shown")
            optionsMenu
        }
    }

    private var optionsMenu: some View {
        Menu {
            Picker("View", selection: $mode.animation(.snappy(duration: 0.2))) {
                Label("Your Try-On", systemImage: "person.crop.rectangle").tag(PreviewMode.tryOn)
                Label("Street Look", systemImage: "photo").tag(PreviewMode.street)
            }
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

    private var liveTwinMessage: String {
        let base = "Live Twin would show this look on your avatar. Dressing the avatar isn't connected yet. Your Try-On uses your photo instead, and Street Look shows the scanned outfit."
        return avatar.profile.avatar != nil ? base : base + " You also need to create your avatar in My Avatar first."
    }

    // MARK: Hero

    private func heroArea(scan: OutfitScan, hero: HeroFrame, look: WorkingLook) -> some View {
        Group {
            switch mode {
            case .tryOn:
                TryOnHero(preview: studio.preview, source: studio.tryOnSource, avatarListing: studio.avatarTryOn,
                          addPhoto: { addPhoto = true }, retry: studio.retryPreview)
            case .street:
                HeroCapture(scan: scan, hero: hero, look: look, selectedID: studio.selectedPieceID,
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
                FMFloatingButton(systemName: "arrow.counterclockwise",
                                 label: mode == .tryOn ? "Show Street Look" : "Show Your Try-On") {
                    withAnimation(.snappy(duration: 0.25)) { mode = mode == .tryOn ? .street : .tryOn }
                }
                .accessibilityIdentifier("switchView")
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

    // MARK: Garments

    private func garments(_ look: WorkingLook) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FMSectionHeader(title: "Layers & Garments") {
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
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(look.pieces) { piece in
                                RetailerMatchCard(piece: piece, selected: piece.id == studio.selectedPieceID,
                                                  state: studio.matchStates[piece.id],
                                                  crop: studio.cropPreviews[piece.id],
                                                  moreCount: max(0, (studio.matchLists[piece.id]?.count ?? 0) - 1),
                                                  select: { withAnimation(.snappy(duration: 0.2)) { studio.select(piece.id) } },
                                                  retry: { studio.findMatch(for: piece.id) },
                                                  showMore: { matchListPiece = piece },
                                                  tryOnAvatar: { tryOnAvatar(piece) })
                                    .containerRelativeFrame(.horizontal, count: 5, span: 3, spacing: 10)
                                    .id(piece.id)
                            }
                        }
                    }
                    .scrollClipDisabled()
                    .onAppear { if let id = studio.selectedPieceID { reader.scrollTo(id, anchor: .center) } }
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

    // MARK: Footer

    private func footer(_ look: WorkingLook) -> some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Total Outfit").font(.system(size: 17, weight: .bold)).foregroundStyle(Color.fmInk)
                Text(look.pieces.count == 1 ? "1 piece" : "\(look.pieces.count) pieces")
                    .font(.system(size: 15)).foregroundStyle(Color.fmSecondary)
                Spacer()
                PriceSummary(look: look)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 12) {
                Button(action: openCamera) {
                    Label("Camera", systemImage: "camera")
                }
                .buttonStyle(FMOutlineButtonStyle())
                .frame(maxWidth: 150)
                Button { router.showCart = true } label: {
                    Label("Shop This Look", systemImage: "bag")
                }
                .buttonStyle(FMFilledButtonStyle())
                .accessibilityIdentifier("shopThisLook")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(Color.fmBackground)
    }

    // MARK: Empty

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FMTitleLine(title: "Studio", caption: "No look yet")
                VStack(spacing: 14) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Color.fmCobalt)
                        .frame(width: 72, height: 72)
                        .background(.white, in: Circle())
                        .fmFloatingShadow()
                        .accessibilityHidden(true)
                    Text("No scan yet")
                        .font(.fmDisplay(28))
                        .foregroundStyle(Color.fmInk)
                        .accessibilityAddTraits(.isHeader)
                    Text("Scan an outfit you spot with the Camera. It opens here, piece by piece, ready to swap and shop.")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.fmSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: openCamera) { Label("Open Camera", systemImage: "camera") }
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
    var scan: OutfitScan
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
    /// How many other ranked listings there are.
    var moreCount: Int = 0
    var select: () -> Void
    var retry: () -> Void
    var showMore: () -> Void = {}
    var tryOnAvatar: () -> Void = {}

    @Environment(\.openURL) private var openURL

    private var category: GarmentCategory { piece.detected.category }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GarmentTile(source: tileSource, category: category)
                .frame(maxWidth: .infinity)
                .frame(height: 112)
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
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white, lineWidth: 2))
                            .padding(5)
                            .accessibilityLabel("Your scanned \(category.title.lowercased())")
                            .accessibilityIdentifier("scannedCrop")
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let product, product.isFixture { TagPill(text: "Test fixture").padding(6) }
                }
            HStack(spacing: 6) {
                Text(category.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(selected ? AuthPalette.primary : AuthPalette.onSurface)
                if let product {
                    TagPill(text: product.matchLabel)
                        .accessibilityIdentifier("matchLabel")
                }
                Spacer(minLength: 0)
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
                Button(action: tryOnAvatar) {
                    Label("Try on my avatar", systemImage: "person.crop.rectangle")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minHeight: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AuthPalette.primary)
                .accessibilityHint("Shows this listing with your full-body avatar")
                .accessibilityIdentifier("tryOnAvatar")
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
            Text("Searching retailers for \(category.searchNoun) only.")
                .font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .noMatch:
            VStack(alignment: .leading, spacing: 3) {
                Text("No match found").font(.system(size: 13, weight: .semibold)).foregroundStyle(AuthPalette.onSurface)
                Text("No retailer listing looked like \(category.searchNoun). Try scanning again closer up.")
                    .font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("noMatch")
        case .noCloseMatch:
            Text("No close match found")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(AuthPalette.onSurface)
                .accessibilityIdentifier("noCloseMatch")
        case .lensFailed(let detail):
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn't search. Try again.")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(AuthPalette.onSurface)
                #if DEBUG
                Text(detail).font(.system(size: 11)).foregroundStyle(AuthPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
                Button(action: retry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minHeight: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AuthPalette.primary)
                .accessibilityIdentifier("retryMatch")
            }
            .accessibilityIdentifier("lensError")
        case .searchLimitReached:
            VStack(alignment: .leading, spacing: 3) {
                Text("Search limit reached").font(.system(size: 13, weight: .semibold)).foregroundStyle(AuthPalette.onSurface)
                Text("FitMix has used this month's product searches. Try again next month.")
                    .font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("searchLimit")
        case .failed(let message, let retryable):
            VStack(alignment: .leading, spacing: 4) {
                Label(retryable ? "Search failed" : "Search unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AuthPalette.onSurface)
                Text(message).font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if retryable {
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
            .accessibilityIdentifier("matchError")
        case nil:
            Text("Tap to find \(category.searchNoun) at retailers.")
                .font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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

/// Every ranked listing for one garment: exact matches first, then likely-same-brand, then similar.
private struct MatchListSheet: View {
    var category: GarmentCategory
    var listings: [CatalogProduct]
    var chosenID: String?
    var choose: (CatalogProduct) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List(listings) { product in
                Button { choose(product) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        GarmentTile(source: product.image.tileSource, category: category)
                            .frame(width: 72, height: 72)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                TagPill(text: product.matchLabel)
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
                .accessibilityAddTraits(product.id == chosenID ? .isSelected : [])
            }
            .listStyle(.plain)
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
