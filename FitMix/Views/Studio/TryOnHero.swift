import SwiftUI
import UIKit

/// Studio's large preview in "Your Try-On" mode. Only a renderer result that reports
/// `producesTryOn` is labeled a try-on; every other state says plainly what is shown.
struct TryOnHero: View {
    var preview: TryOnPreview
    var source: UIImage?
    /// Set after "Try on my avatar": `source` is the avatar and this listing is what goes on it.
    var avatarListing: AvatarTryOn? = nil
    var addPhoto: () -> Void
    var retry: () -> Void
    var zoom: () -> Void

    var body: some View {
        ZStack {
            AuthPalette.containerHigh
            content
        }
        .containerRelativeFrame(.vertical) { length, _ in min(max(length - 330, 180), 520) }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 6) {
                if let label { StatusPill(text: label.text, emphasized: label.isTryOn) }
                if let avatarListing { ListingChip(listing: avatarListing) }
            }
            .padding(10)
        }
        .overlay(alignment: .bottomTrailing) {
            if displayedImage != nil {
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
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tryOnHero")
    }

    /// The image currently on screen, also used by zoom.
    var displayedImage: UIImage? {
        if case .ready(let image, _, _) = preview { return image }
        return source
    }

    private var label: (text: String, isTryOn: Bool)? {
        switch preview {
        case .ready(_, let isTryOn, _):
            return isTryOn ? ("TRY-ON", true) : ("STAND-IN · NOT A TRY-ON", false)
        case .needsPhoto: return nil
        default:
            guard source != nil else { return nil }
            return (avatarListing == nil ? "YOUR PHOTO · NOT A TRY-ON" : "YOUR AVATAR · NOT A TRY-ON", false)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch preview {
        case .needsPhoto:
            VStack(spacing: 12) {
                Image(systemName: "person.crop.rectangle").font(.system(size: 34)).foregroundStyle(AuthPalette.primaryContainer)
                Text("See this look on you").font(.system(size: 20, weight: .medium, design: .serif)).foregroundStyle(AuthPalette.onSurface)
                Text("Add a full-body photo of yourself. Try-on starts from it.")
                    .font(.system(size: 13)).foregroundStyle(AuthPalette.secondary).multilineTextAlignment(.center)
                Button(action: addPhoto) { Label("Add Your Photo", systemImage: "camera") }
                    .buttonStyle(AuthPrimaryButtonStyle())
                    .frame(maxWidth: 220)
            }
            .padding(20)
        case .ready(let image, let isTryOn, _):
            photo(image, label: isTryOn ? "You wearing the selected look" : "Stand-in preview, not a try-on")
        case .rendering:
            ZStack {
                if let source { photo(source, label: "Your photo").opacity(0.55) }
                statusCard(icon: nil, title: "Putting the look on you…", detail: "This uses your original photo and every piece you've selected.")
            }
            .accessibilityIdentifier("tryOnRendering")
        case .unavailable:
            ZStack(alignment: .bottom) {
                if let source { photo(source, label: avatarListing == nil ? "Your photo as taken" : "Your avatar") }
                if let avatarListing {
                    statusCard(icon: "hourglass", title: "Try-on isn't available yet",
                               detail: "This is your avatar. \(avatarListing.productName) is ready to try on, but FitMix can't generate the try-on image yet.")
                        .padding(.bottom, 56)
                } else {
                    statusCard(icon: "hourglass", title: "Try-on isn't available yet",
                               detail: "This is your photo as you took it. FitMix can't put the selected clothes on it yet. Switch to Street Look to see the outfit.")
                        .padding(.bottom, 56)
                }
            }
            .accessibilityIdentifier("tryOnUnavailable")
        case .nothingSelected:
            ZStack(alignment: .bottom) {
                if let source { photo(source, label: "Your photo as taken") }
                statusCard(icon: "tshirt", title: "Nothing to try on", detail: "This look has no garments to apply.")
                    .padding(.bottom, 56)
            }
        case .failed(let message, _):
            ZStack(alignment: .bottom) {
                if let source { photo(source, label: "Your photo as taken").opacity(0.6) }
                VStack(spacing: 8) {
                    statusCard(icon: "exclamationmark.triangle", title: "Couldn't create the try-on", detail: message)
                    Button("Try Again", action: retry)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).frame(minHeight: 40)
                        .background(AuthPalette.primaryContainer, in: Capsule())
                }
                .padding(.bottom, 56)
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
        .padding(12)
        .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
    }
}

/// The listing headed for the avatar: its own product photo and name.
private struct ListingChip: View {
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

private struct StatusPill: View {
    var text: String
    var emphasized: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold)).tracking(0.8)
            .foregroundStyle(.white)
            .padding(.horizontal, 8).frame(minHeight: 22)
            .background(emphasized ? AuthPalette.primaryContainer : AuthPalette.onSurface.opacity(0.75), in: Capsule())
            .accessibilityIdentifier("tryOnStatus")
    }
}
