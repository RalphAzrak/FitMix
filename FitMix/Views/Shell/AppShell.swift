import SwiftUI

/// Where the app is: the selected tab and whatever is presented over it. Screens change these
/// instead of presenting covers themselves, so only one full-screen flow shows at a time.
@Observable final class AppRouter {
    enum Tab: String, CaseIterable, Identifiable {
        case home, studio, closet, saved
        var id: String { rawValue }
    }

    /// The Camera flow: capture, then Outfit Review.
    enum Capture: String, Identifiable {
        case camera, review
        var id: String { rawValue }
    }

    var tab: Tab = .home
    var capture: Capture?
    /// The step the avatar flow is open at, or `nil` when it is closed.
    var flow: SetupStep?
    var authPreview: AuthView.Mode?
    var showCart = false
    var showMetricsEditor = false
    /// Set when sign-in or sign-up finishes and there is no avatar yet; opens the avatar flow once Account closes.
    var setupAfterAuth = false

    func openCamera() { capture = .camera }
    func openAccount() { authPreview = .signIn }
}

extension StudioStore {
    /// Pieces in the current look that can be shopped; the bag badge shows this.
    var bagCount: Int { look?.pieces.filter { $0.product != nil }.count ?? 0 }
}

/// The app's root: one screen per tab, the tab bar underneath, and the app-wide covers and sheets.
struct AppShell: View {
    @Environment(AvatarStore.self) private var store
    @Environment(StudioStore.self) private var studio
    @Environment(AuthSession.self) private var auth
    @State private var router = AppRouter()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Home and Studio stay alive in the background so switching tabs keeps their place.
                layer(.home) { HomeView() }
                layer(.studio) { StudioView(openCamera: router.openCamera) }
                if router.tab == .closet { ClosetView() }
                if router.tab == .saved { SavedView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            FMTabBar(selection: $router.tab, openCamera: router.openCamera)
        }
        .background(Color.fmBackground.ignoresSafeArea())
        .ignoresSafeArea(.keyboard)
        .environment(router)
        .tint(Color.fmCobalt)
        .fullScreenCover(item: $router.flow) { SetupFlowView(startAt: $0) }
        .fullScreenCover(item: $router.capture) { route in
            switch route {
            case .camera:
                CameraView(close: {
                    // Back to the tab Camera was opened from; Studio keeps its previous look.
                    router.capture = nil
                }, select: { selection in
                    studio.openLive(selection, tryOnSource: nil)
                    router.tab = .studio
                    router.capture = nil
                }, confirm: { scan in
                    studio.review(scan)
                    router.capture = .review
                })
            case .review:
                if let scan = studio.pendingScan {
                    OutfitReviewView(scan: scan, retake: {
                        studio.discardReview()
                        router.capture = .camera
                    }, close: {
                        studio.discardReview()
                        router.capture = nil
                    }, openStudio: {
                        router.tab = .studio
                        router.capture = nil
                    })
                    // A finished analysis replaces the scan; start its selection fresh.
                    .id(scan.id)
                }
            }
        }
        .fullScreenCover(item: $router.authPreview, onDismiss: {
            // Cleared after the cover closes so it doesn't flash Profile on the way out.
            auth.finishConfirmation()
            if router.setupAfterAuth {
                router.setupAfterAuth = false
                router.flow = store.resumeStep
            }
        }) { mode in
            AccountFlowView(mode: mode) { _ in
                router.setupAfterAuth = store.profile.avatar == nil && store.profile.candidate == nil
                router.authPreview = nil
            }
        }
        .sheet(isPresented: $router.showMetricsEditor) { MetricsEditorSheet() }
        .sheet(isPresented: $router.showCart) { ShoppingReviewView() }
        .alert("Couldn't save", isPresented: Binding(get: { store.storageErrorMessage != nil && router.flow == nil },
                                                    set: { if !$0 { store.storageErrorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.storageErrorMessage ?? "")
        }
        .onChange(of: auth.hasOpenAuthLink) { _, active in
            if active { showAuthLink() }
        }
        .onAppear {
            if auth.hasOpenAuthLink { showAuthLink() }
            switch Self.debugScreen {
            case "setup": router.flow = store.resumeStep
            case "generate": router.flow = .generate
            case "metrics": router.showMetricsEditor = true
            case "auth", "profile": router.authPreview = .signIn
            case "auth-create": router.authPreview = .createAccount
            case "cart": router.showCart = true
            case "studio": router.tab = .studio
            #if DEBUG
            case "studio-sample":
                // Studio on the code-drawn sample look, without going through Camera.
                studio.open(SampleScans.scanA(), tryOnSource: store.bodyPhoto)
                router.tab = .studio
            case let screen? where screen.hasPrefix("live-sample-"):
                if let category = GarmentCategory(rawValue: String(screen.dropFirst("live-sample-".count))),
                   let selection = SampleScans.liveSelection(category) {
                    studio.openLive(selection, tryOnSource: nil)
                    router.tab = .studio
                    if let next = ProcessInfo.processInfo.environment["FM_DEBUG_THEN_SELECT"].flatMap(GarmentCategory.init(rawValue:)) {
                        Task {
                            try? await Task.sleep(for: .seconds(1))
                            if let piece = studio.look?.pieces.first(where: { $0.detected.category == next }) {
                                studio.select(piece.id)
                            }
                        }
                    }
                }
            #endif
            case "closet": router.tab = .closet
            case "saved": router.tab = .saved
            case "camera": router.capture = .camera
            default: break
            }
        }
    }

    private func layer<Content: View>(_ tab: AppRouter.Tab, @ViewBuilder content: () -> Content) -> some View {
        let visible = router.tab == tab
        return content()
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }

    /// A reset or sign-up confirmation link was opened: show it in the Account cover. Anything else
    /// presented here closes first (the avatar flow saves as it goes), since only one can show at a time.
    private func showAuthLink() {
        guard router.authPreview == nil else { return }
        let otherOpen = router.flow != nil || router.showMetricsEditor || router.capture != nil || router.showCart
        router.flow = nil
        router.showMetricsEditor = false
        router.capture = nil
        router.showCart = false
        router.setupAfterAuth = false
        Task {
            if otherOpen { try? await Task.sleep(for: .milliseconds(650)) }
            router.authPreview = .signIn
        }
    }

    /// Debug builds can open straight into a screen with FM_DEBUG_SCREEN=setup | generate | avatar-profile |
    /// metrics | auth | auth-create | profile | studio | studio-sample | closet | saved | camera | cart.
    static var debugScreen: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["FM_DEBUG_SCREEN"]
        #else
        nil
        #endif
    }
}

// MARK: - Tab bar

/// Home · Studio · Camera · Closet · Saved. Camera is a raised cobalt button that opens the capture
/// flow over the current tab; the others switch tabs.
struct FMTabBar: View {
    @Binding var selection: AppRouter.Tab
    var openCamera: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            item(.home, title: "Home", icon: "house", selectedIcon: "house.fill")
            item(.studio, title: "Studio", icon: "tshirt", selectedIcon: "tshirt.fill")
            // Center slot, so the raised button sits in the middle of the bar.
            cameraButton
            item(.closet, title: "Closet", icon: "square.grid.2x2", selectedIcon: "square.grid.2x2.fill")
            item(.saved, title: "Saved", icon: "bookmark", selectedIcon: "bookmark.fill")
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background {
            Color.fmBackground
                .overlay(alignment: .top) { Rectangle().fill(Color.fmHairline).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func item(_ tab: AppRouter.Tab, title: String, icon: String, selectedIcon: String) -> some View {
        let selected = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: selected ? selectedIcon : icon)
                    .font(.system(size: 21, weight: .medium))
                    .frame(height: 26)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Color.fmCobalt : Color.fmSecondary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("tab-\(tab.rawValue)")
    }

    private var cameraButton: some View {
        Button(action: openCamera) {
            VStack(spacing: 4) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(.fmPrimaryGradient, in: Circle())
                    .overlay(Circle().strokeBorder(.white, lineWidth: 4))
                    .shadow(color: Color.fmCobalt.opacity(0.35), radius: 10, y: 4)
                    .padding(.top, -30)
                    .frame(height: 26, alignment: .bottom)
                Text("Camera")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.fmSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Camera")
        .accessibilityHint("Scan an outfit")
        .accessibilityIdentifier("tab-camera")
    }
}

// MARK: - Closet and Saved

/// Closet: the user's own clothes. Not built yet, so it says so and points to what works today.
struct ClosetView: View {
    var body: some View {
        TabPlaceholder(title: "Closet", caption: "Your wardrobe", icon: "square.grid.2x2",
                       heading: "Your closet is coming soon",
                       message: "Soon you'll keep the pieces you own here and mix them into looks in Studio. For now, scan an outfit you like with the Camera.",
                       actionTitle: "Scan an Outfit", actionIcon: "camera") { $0.openCamera() }
    }
}

/// Saved: looks the user keeps. Saving isn't built yet, so it says so.
struct SavedView: View {
    var body: some View {
        TabPlaceholder(title: "Saved", caption: "Looks", icon: "bookmark",
                       heading: "Saved looks are coming soon",
                       message: "You'll be able to save looks from Studio and come back to them here. Your current look stays in Studio until you scan a new one.",
                       actionTitle: "Open Studio", actionIcon: "tshirt") { $0.tab = .studio }
    }
}

private struct TabPlaceholder: View {
    var title: String
    var caption: String
    var icon: String
    var heading: String
    var message: String
    var actionTitle: String
    var actionIcon: String
    var action: (AppRouter) -> Void

    @Environment(AppRouter.self) private var router
    @Environment(StudioStore.self) private var studio

    var body: some View {
        VStack(spacing: 0) {
            FMTopBar { FMBagButton(count: studio.bagCount) { router.showCart = true } }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    FMTitleLine(title: title, caption: caption)
                    VStack(spacing: 14) {
                        Image(systemName: icon)
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(Color.fmCobalt)
                            .frame(width: 72, height: 72)
                            .background(.white, in: Circle())
                            .fmFloatingShadow()
                            .accessibilityHidden(true)
                        Text(heading)
                            .font(.fmDisplay(24, relativeTo: .title2))
                            .foregroundStyle(Color.fmInk)
                            .multilineTextAlignment(.center)
                        Text(message)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.fmSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { action(router) } label: { Label(actionTitle, systemImage: actionIcon) }
                            .buttonStyle(FMFilledButtonStyle())
                            .padding(.top, 6)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity)
                    .fmHeroFrame()
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
        }
        .background(Color.fmBackground)
    }
}
