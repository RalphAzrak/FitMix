import SwiftUI
import UIKit

/// Home shows the accepted portrait and opens the fitting, scanning, and shopping flows.
struct HomeView: View {
    @Environment(AvatarStore.self) private var store
    @Environment(AuthSession.self) private var auth
    @Environment(AppRouter.self) private var router
    @Environment(CartStore.self) private var cart
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var showProfile = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                GeometryReader { viewport in
                    let width = max(0, min(viewport.size.width - 28, 580))
                    let portraitHeight = min(width * 1.44, max(322, viewport.size.height - 192))

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Fitting Room")
                                .font(.fmDisplay(37, relativeTo: .largeTitle))
                                .foregroundStyle(Color.fmInk)
                                .accessibilityAddTraits(.isHeader)
                            statusBanner
                            HomePortrait(
                                portrait: store.avatarImage,
                                hasAvatar: store.profile.avatar != nil,
                                setupStarted: store.profile.setupStarted,
                                openProfile: { showProfile = true },
                                createAvatar: { router.flow = store.resumeStep }
                            )
                            .frame(height: portraitHeight)
                            outfitButton
                            shortcuts
                        }
                        .frame(width: width)
                        .padding(.top, 16)
                        .padding(.bottom, 26)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .background(Color(hex: 0xF8F6F1).ignoresSafeArea())
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
            FMBagButton(count: cart.count) { router.openCart() }
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

    private var outfitButton: some View {
        Button { router.showOutfit = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "hanger")
                    .font(.title3.weight(.medium))
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.15), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Outfit").font(.headline)
                    Text("Style your avatar").font(.subheadline).foregroundStyle(.white.opacity(0.88))
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.right").font(.body.weight(.semibold)).accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .background(.fmPrimaryGradient, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feature-outfit")
    }

    private var shortcuts: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                 count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
            shortcut("Wardrobe", icon: "square.grid.2x2", id: "closet") { router.tab = .closet }
            shortcut("Studio", icon: "tshirt", id: "studio") { router.tab = .studio }
            shortcut("Scan Fits", icon: "camera.viewfinder", id: "scan", action: router.openCamera)
            shortcut("Shop This Look", icon: "bag", id: "shop") { router.showShopLook = true }
        }
    }

    private func shortcut(_ title: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.fmCobaltDeep)
                    .frame(width: 30, height: 34)
                    .accessibilityHidden(true)
                Text(title).font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.fmInk)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.fmHairline))
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityIdentifier("feature-\(id)")
    }
}

private struct HomePortrait: View {
    let portrait: UIImage?
    let hasAvatar: Bool
    let setupStarted: Bool
    let openProfile: () -> Void
    let createAvatar: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if hasAvatar {
                Button(action: openProfile) { portraitPanel }
                    .buttonStyle(PressableCardStyle())
                    .accessibilityLabel("My Avatar")
                    .accessibilityHint("Opens your avatar profile")
            } else {
                emptyPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Color.fmInk.opacity(0.08)).allowsHitTesting(false))
        .accessibilityIdentifier("home-avatar")
    }

    private var backdrop: some View {
        RadialGradient(colors: [Color(hex: 0xF1ECE4), Color(hex: 0xE4DBD0)],
                       center: .topLeading, startRadius: 5, endRadius: 560)
    }

    private var portraitPanel: some View {
        ZStack {
            backdrop
            if let portrait {
                Image(uiImage: portrait)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            } else {
                ProgressView()
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: portrait == nil)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 7) {
                Text("My Avatar").font(.caption.weight(.semibold))
                Image(systemName: "arrow.up.right").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Color.fmInk)
            .padding(.horizontal, 13)
            .frame(minHeight: 44)
            .background(.white.opacity(0.94), in: Capsule())
            .padding(12)
            .accessibilityHidden(true)
        }
    }

    private var emptyPanel: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.rectangle")
                .font(.system(size: 43, weight: .light))
                .foregroundStyle(Color.fmCobaltDeep)
                .accessibilityHidden(true)
            Text(setupStarted ? "Your avatar is in progress" : "Create your avatar")
                .font(.fmDisplay(26, relativeTo: .title2))
                .foregroundStyle(Color.fmInk)
            Text(setupStarted ? "Pick up where you left off." : "Start with a full-body photo.")
                .font(.subheadline)
                .foregroundStyle(Color.fmSecondary)
            Button(setupStarted ? "Continue Setup" : "Create My Avatar", action: createAvatar)
                .buttonStyle(FMFilledButtonStyle())
                .frame(maxWidth: 242)
        }
        .multilineTextAlignment(.center)
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { backdrop }
    }
}

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
