import SwiftUI
import UIKit

/// FitMix's home: the user's avatar on the left, the features they can open on the right.
/// Managing the avatar, the original photo and the measurements happens in Profile (`AvatarProfileView`).
/// Both screens read the same `AvatarStore`, so an accepted avatar shows up here straight away.
struct HomeView: View {
    @Environment(AvatarStore.self) private var store
    @Environment(StudioStore.self) private var studio
    @Environment(AuthSession.self) private var auth
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var showProfile = false
    /// The step the avatar flow is open at, or `nil` when it is closed.
    @State private var flow: SetupStep?
    @State private var showMetricsEditor = false
    @State private var placeholder: PlaceholderScreen?
    /// True when Camera was opened from Studio, so closing Camera goes back there.
    @State private var cameraReturnsToStudio = false
    @State private var showCart = false
    @State private var authPreview: AuthView.Mode?
    /// Set when sign-in or sign-up finishes and there is no avatar yet; opens the avatar flow once Account closes.
    @State private var setupAfterAuth = false
    /// Width available to the hub, measured so the two columns can be sized from it.
    @State private var contentWidth: CGFloat = 361

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    statusBanner
                    hub
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(Color.fmBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showProfile) {
                AvatarProfileView(changeAvatar: { flow = $0 }, editMetrics: { showMetricsEditor = true },
                                  openAccount: { authPreview = .signIn })
            }
        }
        .tint(Color.fmInk)
        .fullScreenCover(item: $flow) { SetupFlowView(startAt: $0) }
        .fullScreenCover(item: $placeholder) { screen in
            switch screen {
            case .studio:
                StudioView(openCamera: {
                    cameraReturnsToStudio = true
                    placeholder = .scanFits
                })
            case .scanFits:
                CameraView(close: {
                    // Back to where Camera was opened from; Studio keeps its previous look.
                    placeholder = cameraReturnsToStudio ? .studio : nil
                }, capture: { capture in
                    // Camera → Outfit Review, which finds the garments. Studio's current look
                    // stays until Try Full Look.
                    studio.review(capture)
                    placeholder = .review
                }, confirm: { scan in
                    studio.review(scan)
                    placeholder = .review
                })
            case .review:
                if let scan = studio.pendingScan {
                    OutfitReviewView(scan: scan, retake: {
                        studio.discardReview()
                        placeholder = .scanFits
                    }, close: {
                        studio.discardReview()
                        placeholder = cameraReturnsToStudio ? .studio : nil
                    }, openStudio: {
                        placeholder = .studio
                    })
                    // A finished analysis replaces the scan; start its selection fresh.
                    .id(scan.id)
                }
            }
        }
        .fullScreenCover(item: $authPreview, onDismiss: {
            if setupAfterAuth {
                setupAfterAuth = false
                flow = store.resumeStep
            }
        }) { mode in
            AccountFlowView(mode: mode) { _ in
                setupAfterAuth = store.profile.avatar == nil && store.profile.candidate == nil
                authPreview = nil
            }
        }
        .sheet(isPresented: $showMetricsEditor) { MetricsEditorSheet() }
        .sheet(isPresented: $showCart) { ShoppingReviewView() }
        .alert("Couldn't save", isPresented: Binding(get: { store.storageErrorMessage != nil && flow == nil },
                                                    set: { if !$0 { store.storageErrorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.storageErrorMessage ?? "")
        }
        .onChange(of: auth.recovery != nil) { _, active in
            if active { showRecovery() }
        }
        .onAppear {
            if auth.recovery != nil { showRecovery() }
            switch Self.debugScreen {
            case "setup": flow = store.resumeStep
            case "generate": flow = .generate
            case "avatar-profile": showProfile = true
            case "metrics": showMetricsEditor = true
            case "auth": authPreview = .signIn
            case "auth-create": authPreview = .createAccount
            case "studio": placeholder = .studio
            case "camera": placeholder = .scanFits
            case "cart": showCart = true
            default: break
            }
        }
    }

    /// A reset link was opened: show "Set a new password" in the Account cover. Anything else
    /// presented here closes first (the avatar flow saves as it goes), since only one can show at a time.
    private func showRecovery() {
        guard authPreview == nil else { return }
        let otherOpen = flow != nil || showMetricsEditor || placeholder != nil || showCart
        flow = nil
        showMetricsEditor = false
        placeholder = nil
        showCart = false
        setupAfterAuth = false
        Task {
            if otherOpen { try? await Task.sleep(for: .milliseconds(650)) }
            authPreview = .signIn
        }
    }

    /// Debug builds can open straight into a screen with
    /// FM_DEBUG_SCREEN=setup | generate | avatar-profile | metrics | auth | auth-create | studio | camera | cart.
    private static var debugScreen: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["FM_DEBUG_SCREEN"]
        #else
        nil
        #endif
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("FitMix")
                    .font(.fmSerif(38))
                    .foregroundStyle(Color.fmInk)
                    .accessibilityAddTraits(.isHeader)
                Text("Your virtual fitting room.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.fmSecondary)
            }
            Spacer(minLength: 12)
            Button { showProfile = true } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.fmInk)
                    .frame(width: 44, height: 44)
                    .background(Color.fmCard, in: Circle())
                    .overlay(Circle().strokeBorder(Color.fmHairline))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile")
            .accessibilityIdentifier("profileButton")
        }
    }

    /// Shown only while something about the avatar needs attention. Everything else stays reachable meanwhile.
    @ViewBuilder
    private var statusBanner: some View {
        switch store.homeState {
        case .generating:
            HomeStatusBanner(text: "Creating your new avatar…", working: true, action: "View") { flow = .generate }
        case .reviewPending:
            HomeStatusBanner(text: "Your new avatar is ready to review.", action: "Review") { flow = .review }
        case .error:
            HomeStatusBanner(text: "Your avatar couldn't be created.", caution: true, action: "Try Again") { flow = .generate }
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
                HomeAvatarPanel(imageWidth: min(contentWidth, 300), openProfile: { showProfile = true }, create: { flow = store.resumeStep })
                    .frame(maxWidth: .infinity)
                VStack(spacing: 10) {
                    ForEach(features) { HomeFeatureCard(feature: $0, compact: false) }
                }
            }
        } else {
            let spacing: CGFloat = 12
            let avatarWidth = ((contentWidth - spacing) * 0.62).rounded(.down)
            HStack(alignment: .top, spacing: spacing) {
                HomeAvatarPanel(imageWidth: avatarWidth, openProfile: { showProfile = true }, create: { flow = store.resumeStep })
                VStack(spacing: 10) {
                    ForEach(features) { HomeFeatureCard(feature: $0, compact: true).frame(maxHeight: .infinity) }
                }
                .frame(height: HomeAvatarPanel.height(imageWidth: avatarWidth))
            }
        }
    }

    /// What can be opened from Home, in order. Each one leads to a screen that exists today, under the name
    /// that screen already uses. My Wardrobe is not built yet, so it is shown first but cannot be opened.
    private var features: [HomeFeature] {
        var list = [
            HomeFeature(id: "wardrobe", title: "My Wardrobe", detail: "Coming soon", icon: "hanger", isAvailable: false) {},
            HomeFeature(id: "studio", title: "Studio", detail: "Swap pieces and style a look", icon: "paintpalette") { placeholder = .studio },
            HomeFeature(id: "scan", title: "Scan Fits", detail: "Capture an outfit with the camera", icon: "camera.viewfinder") {
                cameraReturnsToStudio = false
                placeholder = .scanFits
            },
            HomeFeature(id: "shop", title: "Shop This Look", detail: "Review the pieces in your look", icon: "bag") { showCart = true },
        ]
        // Try-on is offered only once something can actually render it.
        if TryOnRenderers.current?.producesTryOn == true {
            list.insert(HomeFeature(id: "tryon", title: "Try-On", detail: "See the look on you", icon: "tshirt") { placeholder = .studio }, at: 1)
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
                ProgressView()
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
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .background(Color.fmCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.fmHairline))
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

    private static let footerHeight: CGFloat = 44
    /// Portraits are 2:3, so the image area is too; the figure fills it without cropping.
    static func height(imageWidth: CGFloat) -> CGFloat { (imageWidth * 1.5).rounded() + footerHeight }

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
        .background(Color.fmCard)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.fmHairline))
    }

    private var portrait: some View {
        VStack(spacing: 0) {
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
            HStack(spacing: 6) {
                Text("My Avatar").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.fmInk)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.fmSecondary)
            }
            .padding(.horizontal, 14)
            .frame(height: Self.footerHeight)
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
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color.fmCobalt, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .background(Color.fmCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.fmHairline))
        .opacity(feature.isAvailable ? 1 : 0.62)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var icon: some View {
        Image(systemName: feature.icon)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(feature.isAvailable ? Color.fmCobalt : Color.fmSecondary)
            .frame(width: 30, height: 30)
            .background(Color.fmTile, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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

// MARK: Full-screen destinations

/// Camera and Studio, presented full screen from My Avatar. (Named before Camera existed.)
enum PlaceholderScreen: String, Identifiable {
    case scanFits, review, studio
    var id: String { rawValue }
}
