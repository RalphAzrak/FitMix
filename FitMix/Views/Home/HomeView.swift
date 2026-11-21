import SwiftUI
import UIKit

/// FitMix's Home tab: the user's avatar on the left, the features they can open on the right.
/// Managing the avatar, the original photo and the measurements happens in Profile (`AvatarProfileView`).
/// Both screens read the same `AvatarStore`, so an accepted avatar shows up here straight away.
/// Flows that cover the whole app (Camera, the avatar flow, Account) are opened through `AppRouter`.
struct HomeView: View {
    @Environment(AvatarStore.self) private var store
    @Environment(AuthSession.self) private var auth
    @Environment(AppRouter.self) private var router
    @Environment(CartStore.self) private var cart
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var showProfile = false
    /// Width available to the hub, measured so the two columns can be sized from it.
    @State private var contentWidth: CGFloat = 361

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        FMTitleLine(title: "Fitting Room", caption: "Home")
                        statusBanner
                        hub
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
            }
            .background(Color.fmBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showProfile) {
                AvatarProfileView(changeAvatar: { router.flow = $0 }, editMetrics: { router.showMetricsEditor = true },
                                  openAccount: router.openAccount)
            }
        }
        .tint(Color.fmInk)
        .onAppear {
            if AppShell.debugScreen == "avatar-profile" { showProfile = true }
        }
    }

    // MARK: Header

    private var header: some View {
        FMTopBar {
            FMBagButton(count: cart.count) { router.showCart = true }
            // Opens the account Profile when signed in, otherwise Sign In (see AccountFlowView).
            // The avatar's Profile opens from the avatar on Home.
            Button(action: router.openAccount) {
                Group {
                    if let user = auth.user {
                        Text(user.initials)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.fmPrimaryGradient, in: Circle())
                    } else {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(Color.fmInk)
                            .frame(width: 40, height: 40)
                            .background(Color.fmFill, in: Circle())
                            .overlay(Circle().strokeBorder(Color.fmHairline))
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(auth.user == nil ? "Sign in" : "Account")
            .accessibilityIdentifier("accountButton")
        }
    }

    /// Shown only while something about the avatar needs attention. Everything else stays reachable meanwhile.
    @ViewBuilder
    private var statusBanner: some View {
        switch store.homeState {
        case .generating:
            HomeStatusBanner(text: "Creating your new avatar…", working: true, action: "View") { router.flow = .generate }
        case .reviewPending:
            HomeStatusBanner(text: "Your new avatar is ready to review.", action: "Review") { router.flow = .review }
        case .error:
            HomeStatusBanner(text: "Your avatar couldn't be created.", caution: true, action: "Try Again") { router.flow = .generate }
        case .empty, .setupInProgress, .ready:
            EmptyView()
        }
    }

    // MARK: Hub

    /// Side by side by default. With very large text or on a very narrow screen the two parts stack,
    /// so every label stays readable and every action reachable.
    private var stacked: Bool { typeSize.isAccessibilitySize || contentWidth < 330 }

    @ViewBuilder
    private var hub: some View {
        let features = features
        if stacked {
            VStack(spacing: 14) {
                HomeAvatarPanel(imageWidth: min(contentWidth, 300), openProfile: { showProfile = true }, create: { router.flow = store.resumeStep })
                    .frame(maxWidth: .infinity)
                VStack(spacing: 10) {
                    ForEach(features) { HomeFeatureCard(feature: $0, compact: false) }
                }
            }
        } else {
            let spacing: CGFloat = 12
            let avatarWidth = ((contentWidth - spacing) * 0.62).rounded(.down)
            HStack(alignment: .top, spacing: spacing) {
                HomeAvatarPanel(imageWidth: avatarWidth, openProfile: { showProfile = true }, create: { router.flow = store.resumeStep })
                VStack(spacing: 10) {
                    ForEach(features) { HomeFeatureCard(feature: $0, compact: true).frame(maxHeight: .infinity) }
                }
                .frame(height: HomeAvatarPanel.height(imageWidth: avatarWidth))
            }
        }
    }

    /// What can be opened from Home, in order. Each one leads to a screen that exists today, under the name
    /// that screen already uses. Closet is not built yet, so it is shown last and cannot be opened.
    private var features: [HomeFeature] {
        var list = [
            HomeFeature(id: "studio", title: "Studio", detail: "Swap pieces and style a look", icon: "tshirt") { router.tab = .studio },
            HomeFeature(id: "scan", title: "Scan Fits", detail: "Capture an outfit with the camera", icon: "camera.viewfinder") { router.openCamera() },
            HomeFeature(id: "shop", title: "Shop This Look", detail: "Review the pieces in your look", icon: "bag") { router.showShopLook = true },
            HomeFeature(id: "closet", title: "Closet", detail: "Coming soon", icon: "square.grid.2x2", isAvailable: false) {},
        ]
        // Try-on is offered only once something can actually render it.
        if TryOnRenderers.current?.producesTryOn == true {
            list.insert(HomeFeature(id: "tryon", title: "Try-On", detail: "See the look on you", icon: "tshirt") { router.tab = .studio }, at: 1)
        }
        return list
    }
}

// MARK: Status banner

private struct HomeStatusBanner: View {
    var text: String
    var working = false
    var caution = false
    var action: String
    var perform: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if working {
                Circle().fill(Color.fmLime).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.black.opacity(0.08)))
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: caution ? "exclamationmark.triangle.fill" : "sparkles")
                    .foregroundStyle(caution ? Color.fmAmber : Color.fmCobalt)
            }
            Text(text).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.fmInk)
            Spacer(minLength: 8)
            Button(action, action: perform)
                .font(.system(size: 14, weight: .semibold))
                .tint(Color.fmCobalt)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .background(Color.fmCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.fmHairline))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Avatar panel

/// The left side of Home: the whole avatar, head to shoes, never cropped or stretched. Tapping it opens
/// Profile. Before there is an avatar, the same space offers to create one.
struct HomeAvatarPanel: View {
    var imageWidth: CGFloat
    var openProfile: () -> Void
    var create: () -> Void
    @Environment(AvatarStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Portraits are 2:3, so the panel is too; the figure fills it without cropping.
    static func height(imageWidth: CGFloat) -> CGFloat { (imageWidth * 1.5).rounded() }

    var body: some View {
        Group {
            if store.profile.avatar != nil {
                Button(action: openProfile) { portrait }
                    .buttonStyle(PressableCardStyle())
                    .accessibilityLabel("Your avatar")
                    .accessibilityHint("Opens Profile")
            } else {
                empty
            }
        }
        .frame(width: imageWidth, height: Self.height(imageWidth: imageWidth))
        .fmHeroFrame()
    }

    private var portrait: some View {
        ZStack {
            Color.fmStudio
            if let image = store.avatarImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .id(store.profile.avatar?.createdAt)    // a replacement fades in over the old one
                    .transition(.opacity)
            } else {
                ProgressView()
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: store.profile.avatar?.createdAt)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: store.avatarImage == nil)
        .overlay(alignment: .topLeading) {
            FMChip(text: "My Avatar", dot: .fmLime).padding(10)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.fmInk)
                .frame(width: 40, height: 40)
                .background(.white, in: Circle())
                .fmFloatingShadow()
                .padding(10)
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Image(systemName: "figure.stand").font(.system(size: 56, weight: .ultraLight)).foregroundStyle(Color.fmSecondary.opacity(0.6))
                .accessibilityHidden(true)
            Text(store.profile.setupStarted ? "Your avatar isn't finished yet" : "No avatar yet")
                .font(.system(size: 14))
                .foregroundStyle(Color.fmSecondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            Button(action: create) {
                Text(store.profile.setupStarted ? "Continue Setup" : "Create My Avatar")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(.fmPrimaryGradient, in: Capsule())
                    .shadow(color: Color.fmCobalt.opacity(0.3), radius: 10, y: 5)
            }
            .buttonStyle(PressableCardStyle())
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.fmStudio)
    }
}

// MARK: Feature cards

/// One thing that can be opened from Home.
struct HomeFeature: Identifiable {
    var id: String
    var title: String
    var detail: String
    var icon: String
    /// False for a feature that is planned but cannot be opened yet.
    var isAvailable = true
    var open: () -> Void
}

/// A feature shortcut. `compact` is the tile used beside the avatar; otherwise a full-width row.
struct HomeFeatureCard: View {
    var feature: HomeFeature
    var compact: Bool

    var body: some View {
        Group {
            if feature.isAvailable {
                Button(action: feature.open) { label }
                    .buttonStyle(PressableCardStyle())
                    .accessibilityLabel(feature.title)
                    .accessibilityHint(feature.detail)
            } else {
                label
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(feature.title), \(feature.detail.lowercased())")
            }
        }
        .accessibilityIdentifier("feature-\(feature.id)")
    }

    private var label: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        icon
                        Spacer(minLength: 0)
                        if !feature.isAvailable { soon }
                    }
                    Spacer(minLength: 0)
                    Text(feature.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.fmInk)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .multilineTextAlignment(.leading)
                }
                .padding(11)
            } else {
                HStack(spacing: 12) {
                    icon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.fmInk)
                        Text(feature.detail).font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
                    }
                    Spacer(minLength: 0)
                    if feature.isAvailable {
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.fmSecondary)
                    }
                }
                .padding(14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .frame(minHeight: 56)
        .background(Color.fmCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.fmHairline))
        .opacity(feature.isAvailable ? 1 : 0.62)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var icon: some View {
        Image(systemName: feature.icon)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(feature.isAvailable ? Color.fmCobalt : Color.fmSecondary)
            .frame(width: 34, height: 34)
            .background(Color.fmTile, in: Circle())
            .overlay(Circle().strokeBorder(Color.fmHairline))
            .accessibilityHidden(true)
    }

    private var soon: some View {
        Text("Soon")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.fmSecondary)
            .padding(.horizontal, 6)
            .frame(minHeight: 18)
            .background(Color.fmTile, in: Capsule())
    }
}

/// A card that dips slightly while pressed. With Reduce Motion on, it only dims.
struct PressableCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
