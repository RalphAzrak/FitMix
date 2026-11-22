import SwiftUI

/// "On your avatar": the four slots the avatar can wear, head to toe. Each one shows what's in it and
/// where it came from (the scan or your wardrobe), so it's always clear what the try-on is made of.
/// Tapping a slot offers what can go there.
struct AvatarOutfitBoard: View {
    var listing: AvatarTryOn?
    var scannedSlot: AvatarOutfitSlot?
    var mix: [AvatarOutfitSlot: WardrobeMixPiece]
    /// Scanned garments with a listing that could go in an empty slot.
    var scannedOptions: [AvatarOutfitSlot: WorkingLook.Piece]
    var hasAvatar: Bool
    var tryScanned: (WorkingLook.Piece) -> Void
    var showScanned: () -> Void
    var pickFromWardrobe: (AvatarOutfitSlot?) -> Void
    var remove: (AvatarOutfitSlot) -> Void
    var removeListing: () -> Void

    private var isEmpty: Bool { listing == nil && mix.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FMSectionHeader(title: "On your avatar") {
                Button { pickFromWardrobe(nil) } label: {
                    Label("Add from Wardrobe", systemImage: "hanger").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Color.fmCobalt)
                .frame(minHeight: 44)
                .accessibilityIdentifier("addFromWardrobe")
            }
            Text(isEmpty ? "Try a scanned piece, then add clothes you already own to complete the outfit."
                         : "Mix the scanned piece with your own clothes. One piece per slot.")
                .font(.system(size: 13))
                .foregroundStyle(Color.fmSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 8) {
                ForEach(AvatarOutfitSlot.bodyOrder) { slot in slotTile(slot) }
            }
            .padding(.top, 2)
            if !hasAvatar {
                NoticeRow(tone: .info, text: "Create your avatar in Home to dress it.").font(.system(size: 13))
            }
        }
        .padding(12)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.fmHairline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("avatarOutfitBoard")
    }

    private enum Content {
        case scanned(AvatarTryOn)
        case wardrobe(WardrobeMixPiece)
        case empty
    }

    private func content(for slot: AvatarOutfitSlot) -> Content {
        if let listing, scannedSlot == slot { return .scanned(listing) }
        if let piece = mix[slot] { return .wardrobe(piece) }
        return .empty
    }

    @ViewBuilder
    private func slotTile(_ slot: AvatarOutfitSlot) -> some View {
        let content = content(for: slot)
        Menu {
            switch content {
            case .scanned(let listing):
                Section(listing.productName) {
                    Button("Show in Garments", systemImage: "arrow.down", action: showScanned)
                    Button("Swap for one of mine", systemImage: "hanger") { pickFromWardrobe(slot) }
                    Button("Take Off", systemImage: "minus.circle", role: .destructive, action: removeListing)
                }
            case .wardrobe(let piece):
                Section(piece.item.title) {
                    Button("Choose Another", systemImage: "hanger") { pickFromWardrobe(slot) }
                    if let option = scannedOptions[slot] {
                        Button("Use the scanned \(slot.family.badgeTitle.lowercased())", systemImage: "viewfinder") { tryScanned(option) }
                    }
                    Button("Take Off", systemImage: "minus.circle", role: .destructive) { remove(slot) }
                }
            case .empty:
                if let option = scannedOptions[slot] {
                    Button("Try the scanned \(slot.family.badgeTitle.lowercased())", systemImage: "viewfinder") { tryScanned(option) }
                }
                Button("Choose from Wardrobe", systemImage: "hanger") { pickFromWardrobe(slot) }
            }
        } label: {
            tileLabel(slot, content: content)
        }
        .buttonStyle(.plain)
        .disabled(!hasAvatar)
        .accessibilityLabel(accessibilityText(slot, content: content))
        .accessibilityIdentifier("avatarSlot-\(slot.rawValue)")
    }

    private func tileLabel(_ slot: AvatarOutfitSlot, content: Content) -> some View {
        let tint = slot.family.tint
        return VStack(spacing: 5) {
            ZStack {
                switch content {
                case .scanned(let listing):
                    if let image = listing.productImage {
                        Image(uiImage: image).resizable().scaledToFit().padding(6)
                    } else if let url = listing.productImageURL {
                        GarmentTile(source: .remote(url), category: listing.category, cornerRadius: 0)
                    } else {
                        GarmentGlyph(family: slot.family, size: 22).foregroundStyle(tint)
                    }
                case .wardrobe(let piece):
                    Image(uiImage: piece.image).resizable().scaledToFit().padding(6)
                case .empty:
                    VStack(spacing: 4) {
                        GarmentGlyph(family: slot.family, size: 20, filled: false)
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(tint.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 74)
            .background(isFilled(content) ? Color.fmCard : tint.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tint.opacity(isFilled(content) ? 0.9 : 0.45),
                                  style: StrokeStyle(lineWidth: isFilled(content) ? 2 : 1.2, dash: isFilled(content) ? [] : [4, 3]))
            }
            .overlay(alignment: .bottom) { sourceTag(content).offset(y: 8) }
            .padding(.bottom, 6)
            Text(slot.family.badgeTitle.uppercased())
                .font(.system(size: 10, weight: .heavy)).tracking(0.6)
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func sourceTag(_ content: Content) -> some View {
        switch content {
        case .scanned:
            tag("Scan", icon: "viewfinder", color: .fmCobalt)
        case .wardrobe:
            tag("Yours", icon: "hanger", color: .fmGreen)
        case .empty:
            EmptyView()
        }
    }

    private func tag(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text(text.uppercased()).font(.system(size: 9, weight: .heavy)).tracking(0.4)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(minHeight: 17)
        .background(color, in: Capsule())
        .overlay(Capsule().strokeBorder(.white, lineWidth: 1.5))
    }

    private func isFilled(_ content: Content) -> Bool {
        if case .empty = content { return false }
        return true
    }

    private func accessibilityText(_ slot: AvatarOutfitSlot, content: Content) -> String {
        switch content {
        case .scanned(let listing): "\(slot.family.badgeTitle): \(listing.productName), from your scan"
        case .wardrobe(let piece): "\(slot.family.badgeTitle): \(piece.item.title), from your wardrobe"
        case .empty: "\(slot.family.badgeTitle): empty. Double-tap to add one."
        }
    }
}

/// Floats at the bottom of Studio while the preview is scrolled away, so a try-on started from a card
/// further down is never missed: it says what's happening and brings the preview back into view.
struct TryOnProgressPill: View {
    enum Phase: Equatable { case rendering, ready, failed }
    var phase: Phase
    var thumbnail: UIImage?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Color.fmStudio
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
                .overlay {
                    if phase == .rendering { ProgressView().controlSize(.small).tint(.white) }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.fmCharcoal)
                    .frame(width: 30, height: 30)
                    .background(phase == .failed ? Color.fmAmber : Color.fmLime, in: Circle())
            }
            .padding(.leading, 7).padding(.trailing, 8)
            .frame(minHeight: 50)
            .background(Color.fmCharcoal.opacity(0.94), in: Capsule())
            .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityHint("Scrolls up to the try-on preview")
        .accessibilityIdentifier("tryOnProgressPill")
    }

    private var title: String {
        switch phase {
        case .rendering: "Dressing your avatar…"
        case .ready: "Your try-on is ready"
        case .failed: "Try-on didn't work"
        }
    }

    private var detail: String {
        switch phase {
        case .rendering: "Keep browsing, it updates up top"
        case .ready: "Tap to see it"
        case .failed: "Tap to see why and retry"
        }
    }
}
