import SwiftUI
import UIKit
import AVFoundation

/// Studio: the scanned person in their full outfit, with each garment underneath to inspect,
/// swap, and shop. Fed by the Camera through `StudioStore.open(_:)`.
struct StudioView: View {
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

    var body: some View {
        VStack(spacing: 0) {
            header
            if let scan = studio.scan, let look = studio.look {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        lookHeader.padding(.bottom, 12)
                        HeroCapture(scan: scan, look: look, selectedID: studio.selectedPieceID,
                                    lastSwap: studio.lastSwap, zoom: { showZoom = true })
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
        .fullScreenCover(isPresented: $showZoom) {
            if let scan = studio.scan {
                ZoomableImageView(image: scan.image, focus: studio.selectedPiece?.detected.bounds,
                                  focusLabel: studio.selectedPiece.map { $0.detected.category.title })
            }
        }
        .alert("Live Twin isn't available yet", isPresented: $showLiveTwinInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(liveTwinMessage)
        }
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
        let base = "Studio is showing your street capture. Dressing your avatar in these pieces isn't connected yet, so no avatar preview is shown."
        return avatar.hasPersonalizedAvatar ? base : base + " You also need to create your avatar in My Avatar first."
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
                let selected = studio.selectedPiece
                Button("Swap item") { swapPiece = selected }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AuthPalette.primary)
                    .frame(minHeight: 44)
                    .disabled(selected == nil)
                    .accessibilityHint(selected.map { "Swap the selected \($0.detected.category.title.lowercased())" } ?? "Select a garment first")
            }
            if look.pieces.isEmpty {
                NoticeRow(tone: .info, text: "The scan didn't find separate garments on this person.")
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

/// The street capture, uncropped, with the selected garment's region outlined.
private struct HeroCapture: View {
    var scan: OutfitScan
    var look: WorkingLook
    var selectedID: UUID?
    var lastSwap: (pieceID: UUID, category: GarmentCategory)?
    var zoom: () -> Void

    private var selected: WorkingLook.Piece? { look.pieces.first { $0.id == selectedID } }

    var body: some View {
        GeometryReader { proxy in
            let fitted = AVMakeRect(aspectRatio: scan.image.size, insideRect: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                Image(uiImage: scan.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: fitted.width, height: fitted.height)
                    .offset(x: fitted.minX, y: fitted.minY)
                    .accessibilityLabel(heroLabel)

                if let selected, let bounds = selected.detected.bounds {
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
                        .accessibilityHidden(true)
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
        .containerRelativeFrame(.vertical) { length, _ in min(max(length - 290, 180), 520) }
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
                if SampleScans.isSample(scan) {
                    Text("SAMPLE SCAN")
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
