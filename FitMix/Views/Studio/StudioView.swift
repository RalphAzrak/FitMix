import SwiftUI
import UIKit
import AVFoundation

/// Studio: the user trying on the look chosen in Outfit Review, with each garment underneath to
/// inspect, swap, and shop. "Street Look" shows the original capture as the reference.
/// Fed by Outfit Review through `StudioStore.open(_:selected:tryOnSource:)`.
struct StudioView: View {
    enum PreviewMode: Hashable { case tryOn, street }

    /// Opens the Camera flow (closes Studio first).
    var openCamera: () -> Void

    @Environment(StudioStore.self) private var studio
    @Environment(AvatarStore.self) private var avatar
    @Environment(\.dismiss) private var dismiss

    @State private var showAccount = false
    @State private var showShopping = false
    @State private var swapPiece: WorkingLook.Piece?
    @State private var showZoom = false
    @State private var showLiveTwinInfo = false
    @State private var mode: PreviewMode = .tryOn
    @State private var addPhoto = false
    @State private var matchListPiece: WorkingLook.Piece?
    @State private var needsAvatar = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let scan = studio.scan, let look = studio.look, let hero = studio.hero {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        lookHeader.padding(.bottom, 8)
                        modeSwitch.padding(.bottom, 10)
                        switch mode {
                        case .tryOn:
                            TryOnHero(preview: studio.preview, source: studio.tryOnSource, avatarListing: studio.avatarTryOn,
                                      addPhoto: { addPhoto = true }, retry: studio.retryPreview,
                                      zoom: { showZoom = true })
                        case .street:
                            HeroCapture(scan: scan, hero: hero, look: look, selectedID: studio.selectedPieceID,
                                        lastSwap: studio.lastSwap, reserve: studio.isLiveLook ? 450 : 330,
                                        zoom: { showZoom = true })
                        }
                        garments(look).padding(.top, 20)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { footer(look) }
            } else {
                emptyState
            }
        }
        .background(AuthPalette.surface.ignoresSafeArea())
        .preferredColorScheme(.light)
        .fullScreenCover(isPresented: $showAccount) { AccountFlowView() }
        .sheet(isPresented: $showShopping) { ShoppingReviewView() }
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
        .onAppear { if studio.isLiveLook || studio.look?.pieces.isEmpty ?? true { mode = .street } }
        .onChange(of: studio.lookNumber) {
            // A new look opens on the try-on view when there's something to try on. A garment picked
            // live opens on the outfit it came from.
            mode = (studio.isLiveLook || studio.look?.pieces.isEmpty ?? true) ? .street : .tryOn
        }
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

    private var tryOnImage: UIImage? {
        if case .ready(let image, _, _) = studio.preview { return image }
        return studio.tryOnSource
    }

    private var modeSwitch: some View {
        HStack(spacing: 0) {
            ForEach([PreviewMode.tryOn, .street], id: \.self) { option in
                let selected = mode == option
                Button {
                    withAnimation(.snappy(duration: 0.2)) { mode = option }
                } label: {
                    Text(option == .tryOn ? "Your Try-On" : "Street Look")
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? AuthPalette.onSurface : AuthPalette.secondary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white)
                                    .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(AuthPalette.container, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            CircleIconButton(systemName: "xmark", label: "Close Studio") { dismiss() }
            Text("FitMix")
                .font(.system(size: 24, weight: .medium, design: .serif))
                .foregroundStyle(AuthPalette.onSurface)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { showShopping = true } label: {
                Image(systemName: "bag")
                    .font(.system(size: 19))
                    .foregroundStyle(AuthPalette.onSurface)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Shopping bag")
            Button { showAccount = true } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(AuthPalette.primaryContainer, in: Circle())
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Account")
            .accessibilityIdentifier("studioAccount")
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    private var lookHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(String(format: "Look %02d", studio.lookNumber))
                .font(.system(size: 24, weight: .medium, design: .serif))
                .foregroundStyle(AuthPalette.onSurface)
            Text("STUDIO FIT")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(AuthPalette.secondary)
            Spacer()
            Button { showLiveTwinInfo = true } label: {
                HStack(spacing: 6) {
                    Circle().fill(AuthPalette.outline).frame(width: 7, height: 7)
                    Text("Live Twin").font(.system(size: 13, weight: .semibold))
                    Text("Off").font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                }
                .foregroundStyle(AuthPalette.onSurface)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(AuthPalette.container, in: Capsule())
                .frame(minHeight: 44)
            }
            .accessibilityLabel("Live Twin")
            .accessibilityValue("Not available")
            .accessibilityHint("Explains why your avatar preview isn't shown")
        }
    }

    private var liveTwinMessage: String {
        let base = "Live Twin would show this look on your avatar. Dressing the avatar isn't connected yet. Your Try-On uses your photo instead, and Street Look shows the scanned outfit."
        return avatar.profile.avatar != nil ? base : base + " You also need to create your avatar in My Avatar first."
    }

    // MARK: Garments

    private func garments(_ look: WorkingLook) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LAYERS & GARMENTS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(AuthPalette.secondary)
                Spacer()
                if !look.pieces.isEmpty, !studio.isLiveLook {
                    let selected = studio.selectedPiece
                    Button("Swap item") { swapPiece = selected }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AuthPalette.primary)
                        .frame(minHeight: 44)
                        .disabled(selected == nil)
                        .accessibilityHint(selected.map { "Swap the selected \($0.detected.category.title.lowercased())" } ?? "Select a garment first")
                }
            }
            .frame(minHeight: 44)
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
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(look.pieces) { piece in
                            GarmentCard(piece: piece, selected: piece.id == studio.selectedPieceID,
                                        hasRegion: piece.detected.bounds != nil) {
                                withAnimation(.snappy(duration: 0.2)) { studio.select(piece.id) }
                            }
                            .containerRelativeFrame(.horizontal, count: 4, spacing: 10)
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
    }

    // MARK: Footer

    private func footer(_ look: WorkingLook) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Total Outfit").font(.system(size: 15, weight: .semibold)).foregroundStyle(AuthPalette.onSurface)
                Text(look.pieces.count == 1 ? "1 piece" : "\(look.pieces.count) pieces")
                    .font(.system(size: 13)).foregroundStyle(AuthPalette.secondary)
                Spacer()
                PriceSummary(look: look)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 10) {
                Button(action: openCamera) {
                    Label("Camera", systemImage: "camera")
                }
                .buttonStyle(AuthSocialButtonStyle(background: AuthPalette.container, foreground: AuthPalette.onSurface))
                .frame(maxWidth: 130)
                Button { showShopping = true } label: {
                    Label("Shop This Look", systemImage: "bag")
                }
                .buttonStyle(AuthPrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(AuthPalette.surface)
        .overlay(alignment: .top) { Rectangle().fill(AuthPalette.containerHigh).frame(height: 1) }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "camera.viewfinder").font(.system(size: 44)).foregroundStyle(AuthPalette.primaryContainer)
            Text("No scan yet")
                .font(.system(size: 28, weight: .medium, design: .serif))
                .foregroundStyle(AuthPalette.onSurface)
                .accessibilityAddTraits(.isHeader)
            Text("Scan an outfit you spot with the Camera. It opens here, piece by piece, ready to swap and shop.")
                .font(.system(size: 15))
                .foregroundStyle(AuthPalette.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button(action: openCamera) { Label("Open Camera", systemImage: "camera") }
                .buttonStyle(AuthPrimaryButtonStyle())
        }
        .padding(24)
    }
}

// MARK: - Hero

/// The captured person in their original outfit (the scan's photo, framed on the subject), with
/// the selected garment's region outlined. Swaps never change this image.
private struct HeroCapture: View {
    var scan: OutfitScan
    var hero: HeroFrame
    var look: WorkingLook
    var selectedID: UUID?
    var lastSwap: (pieceID: UUID, category: GarmentCategory)?
    /// Height kept free below the photo so the garment cards show without scrolling.
    var reserve: CGFloat = 330
    var zoom: () -> Void

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
                    let rect = CGRect(x: fitted.minX + bounds.minX * fitted.width,
                                      y: fitted.minY + bounds.minY * fitted.height,
                                      width: bounds.width * fitted.width,
                                      height: bounds.height * fitted.height)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(AuthPalette.primaryContainer, style: StrokeStyle(lineWidth: 2.5, dash: [7, 4]))
                        .background(AuthPalette.primaryContainer.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                        .accessibilityElement()
                        .accessibilityLabel("Highlighted in photo: \(selected.detected.category.title)")
                        .accessibilityIdentifier("garmentHighlight")
                    if let name = selected.displayName {
                        DetailBadge(text: name, swapped: selected.isSwapped)
                            .frame(maxWidth: min(220, proxy.size.width - 24), alignment: .leading)
                            .fixedSize()
                            .offset(x: max(8, min(rect.minX + 6, proxy.size.width - 230)),
                                    y: max(8, min(rect.minY + 6, proxy.size.height - 40)))
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        // Leave room for the look header and the garment row so they show without scrolling.
        .containerRelativeFrame(.vertical) { length, _ in min(max(length - reserve, 180), 520) }
        .background(AuthPalette.containerHigh)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 6) {
                if let lastSwap {
                    Label("\(lastSwap.category.title) swapped", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AuthPalette.onSurface)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 28)
                        .background(.white, in: Capsule())
                        .accessibilityIdentifier("swapBadge")
                }
                #if DEBUG
                if let kind = SampleScans.kind(of: scan) {
                    Text(kind == .illustration ? "SAMPLE SCAN" : "TEST PHOTO · FIXTURE GARMENT DATA")
                        .font(.system(size: 10, weight: .bold)).tracking(0.8)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).frame(minHeight: 22)
                        .background(AuthPalette.onSurface.opacity(0.75), in: Capsule())
                }
                #endif
            }
            .padding(10)
        }
        .overlay(alignment: .bottomTrailing) {
            Button(action: zoom) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AuthPalette.onSurface)
                    .frame(width: 40, height: 40)
                    .background(.white, in: Circle())
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Zoom photo")
            .padding(8)
        }
        .overlay(alignment: .bottomLeading) {
            if look.pieces.contains(where: \.isSwapped) {
                Text("Photo shows the original outfit")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 24)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(12)
            }
        }
    }

    private var heroLabel: String {
        let pieces = look.pieces.map { $0.detected.category.title.lowercased() }.joined(separator: ", ")
        return "Street capture of the scanned outfit" + (pieces.isEmpty ? "" : ": \(pieces)")
    }
}

private struct DetailBadge: View {
    var text: String
    var swapped: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(AuthPalette.primaryContainer).frame(width: 8, height: 8)
            Text(swapped ? "Swapped · \(text)" : text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .background(AuthPalette.onSurface.opacity(0.82), in: Capsule())
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
            VStack(spacing: 6) {
                GarmentTile(source: piece.tileSource, category: piece.detected.category)
                    .frame(maxWidth: .infinity)
                    .frame(height: 100)
                    .overlay(alignment: .bottom) {
                        if let tag { TagPill(text: tag).padding(4) }
                    }
                    .padding(3)
                    .background(.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(selected ? AuthPalette.primaryContainer : AuthPalette.containerHigh, lineWidth: selected ? 2.5 : 1)
                    )
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(AuthPalette.primaryContainer, in: Circle())
                                .offset(x: 6, y: -6)
                        }
                    }
                Text(piece.detected.category.title)
                    .font(.system(size: 13, weight: selected ? .bold : .semibold))
                    .foregroundStyle(selected ? AuthPalette.primary : AuthPalette.onSurface)
                Text(nameLine)
                    .font(.system(size: 12))
                    .foregroundStyle(AuthPalette.secondary)
                    .lineLimit(1)
                Capsule()
                    .fill(selected ? AuthPalette.primaryContainer : .clear)
                    .frame(width: 24, height: 3)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(hasRegion ? "Highlights it in the photo" : "")
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

/// A garment from a live selection, with its retailer search. The card shows the retailer's own
/// product photo once a listing arrives; the camera crop is search input only and isn't shown.
private struct RetailerMatchCard: View {
    var piece: WorkingLook.Piece
    var selected: Bool
    var state: RetailerMatchState?
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
                .overlay {
                    if state == .searching {
                        ZStack {
                            Color.white.opacity(0.55)
                            VStack(spacing: 8) {
                                ProgressView()
                                Text("Finding a retailer match…")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(AuthPalette.onSurface)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityIdentifier("matchLoading")
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
        product.map { $0.image.tileSource } ?? .none
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
                .font(.system(size: 20))
                .foregroundStyle(AuthPalette.secondary)
                .frame(width: 40, height: 40)
                .background(AuthPalette.container, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("No garments detected")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AuthPalette.onSurface)
                Text("Garments recognized in this photo appear here, ready to swap and shop. To try another photo, tap Camera.")
                    .font(.system(size: 13))
                    .foregroundStyle(AuthPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AuthPalette.containerLow, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AuthPalette.containerHigh))
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
            .background(AuthPalette.primaryContainer, in: Capsule())
    }
}

/// Total of known catalog prices, saying when it covers only some pieces.
struct PriceSummary: View {
    var look: WorkingLook

    var body: some View {
        if look.hasMixedCurrencies {
            Text("Prices in several currencies").font(.system(size: 13)).foregroundStyle(AuthPalette.secondary)
        } else if let total = look.total {
            VStack(alignment: .trailing, spacing: 1) {
                Text(total.price.formatted).font(.system(size: 17, weight: .bold)).foregroundStyle(AuthPalette.onSurface)
                if total.pricedCount < look.pieces.count {
                    Text("for \(total.pricedCount) of \(look.pieces.count) pieces")
                        .font(.system(size: 11)).foregroundStyle(AuthPalette.secondary)
                }
            }
        } else {
            Text("Prices unavailable").font(.system(size: 13)).foregroundStyle(AuthPalette.secondary)
        }
    }
}
