import SwiftUI
import UIKit

/// Home is the app's control centre: a greeting, the avatar with its one main action, the two ways to start
/// (scan an outfit, add your own clothing), and a way back to what the user did last.
struct HomeView: View {
    @Environment(AvatarStore.self) private var store
    @Environment(AuthSession.self) private var auth
    @Environment(AppRouter.self) private var router
    @Environment(CartStore.self) private var cart
    @Environment(StudioStore.self) private var studio
    @Environment(SavedLookStore.self) private var savedLooks
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var showProfile = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                GeometryReader { viewport in
                    let width = max(0, min(viewport.size.width - 32, 580))
                    // The avatar is the hero, sized so the ways to start still show beneath it.
                    let reserved: CGFloat = typeSize.isAccessibilitySize ? 340 : 304
                    let portraitHeight = min(width * 1.3, max(280, viewport.size.height - reserved))

                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            greeting
                            statusBanner
                            if store.profile.avatar != nil {
                                HomePortrait(portrait: store.avatarImage, openProfile: { showProfile = true }) { outfitButton }
                                    .frame(height: portraitHeight)
                            } else {
                                HomeAvatarInvite(setupStarted: store.profile.setupStarted) { router.flow = store.resumeStep }
                            }
                            starters
                            if hasRecents { recents } else { howItWorks }
                        }
                        .frame(width: width)
                        .padding(.top, 18)
                        .padding(.bottom, 28)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .background(Color.fmCanvas.ignoresSafeArea())
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
            Button { showProfile = true } label: {
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
            .accessibilityLabel("Profile")
            .accessibilityIdentifier("accountButton")
        }
    }

    /// "Good evening, Wadih" above the page title, so Home opens on the person rather than on a label.
    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greetingLine.uppercased())
                .font(.fmEyebrow)
                .tracking(1.1)
                .foregroundStyle(Color.fmCobaltDeep)
            Text("Fitting Room")
                .font(.fmDisplay(34, relativeTo: .largeTitle))
                .foregroundStyle(Color.fmInk)
                .accessibilityAddTraits(.isHeader)
        }
        .accessibilityElement(children: .combine)
    }

    private var greetingLine: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let time = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return auth.user?.firstName.map { "\(time), \($0)" } ?? time
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

    /// The one main action. It sits on the avatar, at the bottom of the card, within easy reach of a thumb.
    private var outfitButton: some View {
        Button { router.showOutfit = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "hanger")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.16), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(auth.user?.firstName.map { "Dress \($0)" } ?? "Build a Look").font(.headline)
                    Text("Try on clothes from your wardrobe").font(.footnote).foregroundStyle(.white.opacity(0.88))
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.right").font(.body.weight(.semibold)).accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.fmPrimaryGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Color.fmCobaltDeep.opacity(0.28), radius: 12, y: 6)
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feature-outfit")
    }

    // MARK: Ways to start

    private var starters: some View {
        VStack(alignment: .leading, spacing: 2) {
            FMSectionHeader(title: "Start something")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                     count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                starter("Scan Outfit", caption: "Find what someone is wearing", icon: "camera.viewfinder",
                        id: "scan", action: router.openCamera)
                starter("Add Clothing", caption: "Photograph your own pieces", icon: "plus",
                        id: "add-clothing", action: router.openAddClothing)
            }
        }
    }

    private func starter(_ title: String, caption: String, icon: String, id: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.fmCobaltDeep)
                    .frame(width: 40, height: 40)
                    .background(Color.fmCobalt.opacity(0.10), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.fmInk)
                    Text(caption).font(.footnote).foregroundStyle(Color.fmSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.fmHairline))
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feature-\(id)")
    }

    // MARK: Jump back in

    private var hasRecents: Bool { studio.scan != nil || !savedLooks.looks.isEmpty }

    /// What the user did last, one tap away: the outfit still open in Studio, and their saved looks.
    private var recents: some View {
        VStack(alignment: .leading, spacing: 2) {
            FMSectionHeader(title: "Jump back in")
            VStack(spacing: 10) {
                if let scan = studio.scan {
                    let count = studio.look?.pieces.count ?? scan.garments.count
                    recent("Your last scan", detail: count == 1 ? "1 garment · Open in Studio" : "\(count) garments · Open in Studio",
                           id: "last-scan", action: { router.tab = .studio }) {
                        Image(uiImage: scan.image).resizable().scaledToFill()
                    }
                }
                if let latest = savedLooks.looks.first {
                    let count = savedLooks.looks.count
                    recent("Saved looks", detail: count == 1 ? "1 look saved" : "\(count) looks saved",
                           id: "saved-looks", action: { router.tab = .saved }) {
                        AsyncImage(url: savedLooks.imageURL(for: latest, thumbnail: true)) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Image(systemName: "bookmark").foregroundStyle(Color.fmSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func recent<Thumbnail: View>(_ title: String, detail: String, id: String, action: @escaping () -> Void,
                                         @ViewBuilder thumbnail: () -> Thumbnail) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                thumbnail()
                    .frame(width: 56, height: 64)
                    .background(Color.fmStudio)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.fmInk)
                    Text(detail).font(.footnote).foregroundStyle(Color.fmSecondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.fmOutline)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.fmHairline))
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recent-\(id)")
    }

    /// For someone with nothing to go back to yet: what FitMix does, in three steps.
    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 2) {
            FMSectionHeader(title: "How FitMix works")
            VStack(alignment: .leading, spacing: 14) {
                step(1, "Scan an outfit", "Point the camera at someone and tap a garment.")
                step(2, "See where to buy it", "FitMix searches the web for matching pieces.")
                step(3, "Try it on your avatar", "See the piece on you before you buy.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.fmHairline))
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.fmCobaltDeep)
                .frame(width: 26, height: 26)
                .background(Color.fmCobalt.opacity(0.10), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.fmInk)
                Text(detail).font(.footnote).foregroundStyle(Color.fmSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The avatar, with the screen's main action on it. Tapping the picture opens the avatar's profile.
private struct HomePortrait<Action: View>: View {
    let portrait: UIImage?
    let openProfile: () -> Void
    @ViewBuilder var action: Action
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            Button(action: openProfile) { panel }
                .buttonStyle(PressableCardStyle())
                .accessibilityLabel("My Avatar")
                .accessibilityHint("Opens your avatar profile")
            action.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.fmInk.opacity(0.08)).allowsHitTesting(false))
        .accessibilityIdentifier("home-avatar")
    }

    private var panel: some View {
        ZStack {
            HomeBackdrop()
            if let portrait {
                Image(uiImage: portrait)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Leaves room for the action that sits over the bottom of the card.
                    .padding(.bottom, 62)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            } else {
                ProgressView()
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: portrait == nil)
    }
}

/// Shown until there is an avatar. Short, so the ways to start and the explanation stay on the first screen.
private struct HomeAvatarInvite: View {
    let setupStarted: Bool
    let createAvatar: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.rectangle")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Color.fmCobaltDeep)
                .frame(width: 64, height: 64)
                .background(.white.opacity(0.75), in: Circle())
                .accessibilityHidden(true)
            Text(setupStarted ? "Your avatar is in progress" : "Create your avatar")
                .font(.fmDisplay(24, relativeTo: .title2))
                .foregroundStyle(Color.fmInk)
            Text(setupStarted ? "Pick up where you left off." : "One full-body photo is all it takes to try clothes on yourself.")
                .font(.subheadline)
                .foregroundStyle(Color.fmSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(setupStarted ? "Continue Setup" : "Create My Avatar", action: createAvatar)
                .buttonStyle(FMFilledButtonStyle())
                .frame(maxWidth: 260)
                .padding(.top, 2)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 22)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .background { HomeBackdrop() }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.fmInk.opacity(0.08)))
        .accessibilityIdentifier("home-avatar")
    }
}

private struct HomeBackdrop: View {
    var body: some View {
        RadialGradient(colors: [Color(hex: 0xF1ECE4), Color(hex: 0xE4DBD0)],
                       center: .topLeading, startRadius: 5, endRadius: 560)
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
