import SwiftUI
import UIKit

/// Studio's large preview in "Your Try-On" mode. Only a renderer result that reports
/// `producesTryOn` is labeled a try-on; every other state says plainly what is shown.
struct TryOnHero: View {
    var preview: TryOnPreview
    var source: UIImage?
    /// Set after "Try on my avatar": `source` is the avatar and this listing is what goes on it.
    var avatarListing: AvatarTryOn? = nil
    var wardrobeItemName: String? = nil
    /// "Jacket + your Pants": what is going on the avatar, for the progress card.
    var outfitSummary: String? = nil
    var addPhoto: () -> Void
    var retry: () -> Void

    /// The parent sizes and frames the hero, and shows `status` and the zoom control over it.
    var body: some View {
        ZStack {
            Color.fmStudio
            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tryOnHero")
    }

    /// What the hero is showing, for its status chip. Only a real try-on is called one.
    static func status(preview: TryOnPreview, source: UIImage?, avatarListing: AvatarTryOn?,
                       dressingAvatar: Bool = false) -> (text: String, isTryOn: Bool)? {
        switch preview {
        case .ready(_, let isTryOn, _):
            return isTryOn ? ("Try-On", true) : ("Sample Preview", false)
        case .needsPhoto: return nil
        default:
            guard source != nil else { return nil }
            return (avatarListing == nil && !dressingAvatar ? "Original Photo" : "Your Avatar", false)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch preview {
        case .needsPhoto:
            VStack(spacing: 12) {
                Image(systemName: "person.crop.rectangle")
                    .font(.system(size: 28, weight: .medium)).foregroundStyle(Color.fmCobalt)
                    .frame(width: 68, height: 68).background(.white, in: Circle()).fmFloatingShadow()
                Text("See this look on you").font(.fmDisplay(20)).foregroundStyle(AuthPalette.onSurface)
                Text("Add a full-body photo of yourself. Try-on starts from it.")
                    .font(.system(size: 13)).foregroundStyle(AuthPalette.secondary).multilineTextAlignment(.center)
                Button(action: addPhoto) { Label("Add Your Photo", systemImage: "camera") }
                    .buttonStyle(FMFilledButtonStyle())
                    .frame(maxWidth: 240)
            }
            .padding(20)
        case .ready(let image, let isTryOn, _):
            photo(image, label: isTryOn ? "You wearing the selected look" : "Stand-in preview, not a try-on")
        case .rendering, .waiting:
            ZStack(alignment: .bottom) {
                if let source { photo(source, label: "Your photo").opacity(0.55) }
                statusCard(icon: nil, title: outfitSummary == nil ? "Putting your look together…" : "Dressing your avatar…",
                           detail: outfitSummary.map { "Adding \($0). This takes a few seconds." }
                               ?? "Using your photo and the selected pieces.")
                    .padding(.bottom, 14)
            }
            .accessibilityIdentifier("tryOnRendering")
        case .unavailable:
            ZStack(alignment: .bottom) {
                if let source { photo(source, label: avatarListing == nil ? "Your photo as taken" : "Your avatar") }
                if let avatarListing {
                    statusCard(icon: "hourglass", title: "Try-on isn't available yet",
                               detail: "\(avatarListing.productName) is selected. The preview shows your saved avatar.")
                        .padding(.bottom, 14)
                } else if let wardrobeItemName {
                    statusCard(icon: "hourglass", title: "Try-on isn't available yet",
                               detail: "\(wardrobeItemName) is selected. The preview shows your original photo.")
                        .padding(.bottom, 14)
                } else {
                    statusCard(icon: "hourglass", title: "Try-on isn't available yet",
                               detail: "Switch to Scanned Outfit to see the clothes from your scan.")
                        .padding(.bottom, 14)
                }
            }
            .accessibilityIdentifier("tryOnUnavailable")
        case .nothingSelected:
            ZStack(alignment: .bottom) {
                if let source { photo(source, label: "Your photo as taken") }
                statusCard(icon: "tshirt", title: "Nothing to try on", detail: "This look has no garments to apply.")
                    .padding(.bottom, 14)
            }
        case .failed(let message, _):
            ZStack(alignment: .bottom) {
                if let source { photo(source, label: "Your photo as taken").opacity(0.6) }
                VStack(spacing: 8) {
                    statusCard(icon: "exclamationmark.triangle", title: "Couldn't create the try-on", detail: message)
                    Button("Try Again", action: retry)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20).frame(minHeight: 44)
                        .background(.fmPrimaryGradient, in: Capsule())
                }
                .padding(.bottom, 14)
            }
        }
    }

    private func photo(_ image: UIImage, label: String) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(label)
            .accessibilityIdentifier("tryOnImage")
    }

    private func statusCard(icon: String?, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let icon {
                Image(systemName: icon).foregroundStyle(AuthPalette.primary)
            } else {
                ProgressView()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(AuthPalette.onSurface)
                Text(detail).font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .fmFloatingShadow()
        // Clear of the floating buttons on the right edge of the hero.
        .padding(.leading, 14)
        .padding(.trailing, 74)
        .accessibilityElement(children: .combine)
    }
}

/// The listing headed for the avatar: its own product photo and name.
struct ListingChip: View {
    var listing: AvatarTryOn

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let image = listing.productImage {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: listing.category.symbol).foregroundStyle(AuthPalette.secondary)
                }
            }
            .frame(width: 36, height: 36)
            .background(.white, in: RoundedRectangle(cornerRadius: 6))
            Text(listing.productName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AuthPalette.onSurface)
                .lineLimit(2)
                .frame(maxWidth: 140, alignment: .leading)
        }
        .padding(6)
        .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Trying on \(listing.productName)")
        .accessibilityIdentifier("avatarListing")
    }
}
